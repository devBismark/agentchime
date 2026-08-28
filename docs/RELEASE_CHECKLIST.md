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

- [ ] install with `-MigrateTaskChime` on the validated Windows machine
- [ ] existing ntfy server/topic is preserved exactly
- [ ] old TaskChime hook handlers are removed
- [ ] AgentChime `Stop`, `StopFailure`, and `Notification` handlers exist exactly once
- [ ] `./agentchime.ps1 doctor` returns `PASS`
- [ ] direct `finished`, `attention`, and `error` tests reach Windows + phone
- [ ] one real Claude completion produces exactly one notification
- [ ] old `~/.taskchime` folder remains untouched as fallback

## Additional hardening

- [ ] test `attention` from a real Claude interaction
- [ ] test/simulate `StopFailure` end-to-end
- [ ] uninstall and confirm unrelated Claude hooks remain
- [ ] fresh-machine bootstrap test passes

## Repository validation

- [ ] Windows CI parses all `.ps1` files
- [ ] repository validation script passes on `windows-latest`
- [ ] README hero/demo asset added
- [ ] repository description and topics configured

## GitHub release

- [ ] public repository created
- [ ] `v0.1.0` tag created
- [ ] release ZIP generated
- [ ] SHA-256 published
- [ ] release notes published
- [ ] bootstrap pinned-install example tested against tag
- [ ] launch post links to tagged release
