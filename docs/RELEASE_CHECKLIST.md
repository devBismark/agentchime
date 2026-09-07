# Release checklist

## Underlying notifier validation

- [x] Windows desktop completion notification
- [x] ntfy phone completion notification
- [x] real Claude Code `Stop` event reaches Windows + phone
- [x] direct `finished`, `attention`, and `error` tests
- [x] repeated install preserves mobile configuration
- [x] repeated install avoids duplicate hook handlers
- [x] `doctor` reaches `PASS`

## AgentChime rename/migration validation

- [x] install with `-MigrateTaskChime` on the validated Windows machine
- [x] existing ntfy server/topic is preserved exactly
- [x] old TaskChime hook handlers are removed
- [x] direct `finished`, `attention`, and `error` tests reach Windows + phone
- [x] old `~/.taskchime` folder remains untouched as fallback
- [ ] AgentChime `Stop`, `StopFailure`, and `Notification` handlers exist exactly once
- [ ] `./agentchime.ps1 doctor` returns `PASS`
- [ ] one real Claude completion produces exactly one notification

The migration itself is confirmed: the AgentChime config carries the same ntfy
server, the same topic, and the same locale as the TaskChime config, no hook
handler points at the old TaskChime notifier, and `~/.taskchime` is intact.

The last three items are open because the maintainer's own profile still carries
a hand-merged hook from the earliest prototype. Its `Stop` handler points at
`~/.claude/hooks/notify.ps1` rather than at the installed AgentChime notifier,
so `doctor` correctly reports `Missing AgentChime hooks: Stop`. Re-running
`install.ps1 -MigratePrototype` repairs it. This is a state fault on one
machine, not a defect in the released scripts: a clean install registers all
three handlers exactly once.

## Additional hardening

- [x] uninstall and confirm unrelated Claude hooks remain
- [ ] test `attention` from a real Claude interaction
- [ ] test/simulate `StopFailure` end-to-end
- [ ] fresh-machine bootstrap test passes

Notes on the three open items. The `attention` and `StopFailure` paths have been
exercised from the notifier inwards, including the API error type reaching the
mobile payload, but not yet driven by a real Claude Code interaction. Bootstrap
has been validated against a clean profile pinned to the `v0.1.0` tag, which is
not the same as a genuinely fresh Windows machine.

## Repository validation

- [x] Windows CI parses all `.ps1` files
- [x] repository validation script passes on `windows-latest`
- [x] README hero/demo asset added
- [x] repository description and topics configured

## GitHub release

- [x] public repository created
- [x] `v0.1.0` tag created
- [x] release ZIP generated
- [x] SHA-256 published
- [x] release notes published
- [x] bootstrap pinned-install example tested against tag
- [x] launch post links to tagged release

Published on 2026-08-28 as
[v0.1.0](https://github.com/devBismark/agentchime/releases/tag/v0.1.0). Both
release assets are attached and the published ZIP digest matches the checksum
file. The launch post item is recorded from the maintainer's own report; every
other item in this section was confirmed against GitHub.
