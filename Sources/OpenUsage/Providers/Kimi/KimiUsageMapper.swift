import Foundation

/// Builds metric lines from the Kimi Code `/coding/v1/usages` payload:
/// - the top-level `usage` object is the overall (weekly) pool,
/// - each entry in `limits` is one rolling rate window; the shortest one is the session meter,
/// - `user.membership.level` carries the plan name.
///
/// Kimi reports request counts (and encodes them as strings), so both meters are `.count` progress
/// rows rather than percentages. The endpoint is undocumented, so every field is read permissively:
/// a body that parses but carries no usable meter yields the shared "No usage data" badge instead of
/// zeros presented as truth.
enum KimiUsageMapper {
    /// `(plan, lines)` from one `/usages` body. Throws only when the body is not a JSON object.
    static func map(_ body: Data) throws -> (plan: String?, lines: [MetricLine]) {
        guard let root = ProviderParse.jsonObject(body) else {
            throw KimiUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let session = sessionLine(from: root) {
            lines.append(session)
        }
        if let usage = root["usage"] as? [String: Any],
           let weekly = quotaLine(label: "Weekly", from: usage, periodDurationMs: nil) {
            lines.append(weekly)
        }
        MetricLine.appendNoDataIfNeeded(&lines)

        return (plan(from: root), lines)
    }

    /// The shortest rate window in `limits` — the rolling session pool. Entries whose window can't be
    /// read sort last, so a payload with one unlabeled window still produces a meter.
    private static func sessionLine(from root: [String: Any]) -> MetricLine? {
        guard let limits = root["limits"] as? [[String: Any]] else { return nil }
        let windows = limits.compactMap { entry -> (periodMs: Int?, detail: [String: Any])? in
            guard let detail = entry["detail"] as? [String: Any] else { return nil }
            return (periodDurationMs(entry["window"] as? [String: Any]), detail)
        }
        let shortest = windows.min { ($0.periodMs ?? .max) < ($1.periodMs ?? .max) }
        guard let shortest else { return nil }
        return quotaLine(label: "Session", from: shortest.detail, periodDurationMs: shortest.periodMs)
    }

    /// One `{limit, used, remaining, resetTime}` object as a bounded count meter. `used` is absent from
    /// some payloads, so it falls back to `limit - remaining`; without either the meter is skipped.
    private static func quotaLine(
        label: String,
        from detail: [String: Any],
        periodDurationMs: Int?
    ) -> MetricLine? {
        guard let limit = ProviderParse.number(detail["limit"]), limit > 0 else { return nil }
        let remaining = ProviderParse.number(detail["remaining"])
        guard let used = ProviderParse.number(detail["used"]) ?? remaining.map({ limit - $0 }),
              used >= 0
        else {
            return nil
        }
        let resetsAt = (detail["resetTime"] as? String).flatMap(OpenUsageISO8601.date(from:))
        return .progress(
            label: label,
            used: min(used, limit),
            limit: limit,
            format: .count(suffix: "requests"),
            resetsAt: resetsAt,
            periodDurationMs: periodDurationMs
        )
    }

    /// `{"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}` → milliseconds. An unrecognized unit gives
    /// `nil`, which just drops the cadence from the meter's subtitle.
    private static func periodDurationMs(_ window: [String: Any]?) -> Int? {
        guard let window,
              let duration = ProviderParse.number(window["duration"]), duration > 0,
              let unit = window["timeUnit"] as? String
        else {
            return nil
        }
        let msPerUnit: Double
        switch unit.uppercased() {
        case "TIME_UNIT_SECOND": msPerUnit = 1_000
        case "TIME_UNIT_MINUTE": msPerUnit = 60_000
        case "TIME_UNIT_HOUR": msPerUnit = 3_600_000
        case "TIME_UNIT_DAY": msPerUnit = 86_400_000
        case "TIME_UNIT_WEEK": msPerUnit = 604_800_000
        default: return nil
        }
        return Int(duration * msPerUnit)
    }

    /// `LEVEL_INTERMEDIATE` → `Intermediate`. The `LEVEL_` prefix is Kimi's enum noise, not a plan name.
    private static func plan(from root: [String: Any]) -> String? {
        guard let user = root["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = (membership["level"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !level.isEmpty
        else {
            return nil
        }
        let name = level
            .replacingOccurrences(of: "LEVEL_", with: "")
            .titleCased(separator: { $0 == "_" }, lowercasingTail: true)
        return name.isEmpty ? nil : name
    }
}
