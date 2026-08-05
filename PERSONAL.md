# Personal fork

This branch (`personal`) holds local changes to OpenUsage that stay out of upstream.
`main` stays a clean mirror of `origin/main` (robinebers/openusage) for contribution work.

## How to change the app

1. Stay on `personal`. Edit the source.
2. Commit with the motivation in the message body — the commit log is the only record of why a
   local change exists.
3. Run `openusage-sync install` to rebuild and replace `/Applications/OpenUsage.app`.

Do not open upstream PRs from `personal`. Branch off `main` for those.

## Nightly sync

`~/.local/bin/openusage-sync` runs at 04:30 from
`~/Library/LaunchAgents/dev.ricardo.openusage-sync.plist`. Each run:

1. Skips if the checkout is dirty or not on `personal`.
2. Fetches upstream and rebases `personal` on `origin/main`.
3. Builds in release mode. A build failure stops the run and leaves the installed app alone.
4. Stages the bundle in `dist/`, copies it over `/Applications/OpenUsage.app`, and relaunches it.
5. Pushes `personal` to the `fork` remote with `--force-with-lease`.

The installed app carries the dev bundle id (`com.robinebers.openusage.dev`) and no Sparkle feed, so
it never self-updates — the nightly sync is the updater. It is ad-hoc signed, because no Apple
Development identity exists on this machine. Effect: providers that read another app's Keychain item
can ask for permission again after a rebuild. To stop that, create a self-signed code-signing
certificate once and export `CODESIGN_IDENTITY` for the build.

Every step that fails sends a macOS notification. The log is
`~/Library/Logs/openusage-sync.log`.

## Recovery

- Bad rebase: `git reset --hard personal-prerebase` (the script writes that ref before each rebase).
- Conflict: the script aborts the rebase and leaves `personal` untouched. Resolve by hand with
  `git rebase origin/main`.
- Stop the timer: `launchctl bootout gui/$(id -u)/dev.ricardo.openusage-sync`.

## Local changes on this branch

| Change | Why |
| ------ | --- |
| `PERSONAL.md` | Documents this setup. |
| Kimi Code provider (`Sources/OpenUsage/Providers/Kimi/`) | Kimi Code runs daily here; upstream has no card for it. API key only. |
