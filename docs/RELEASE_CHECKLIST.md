# Release checklist

## v0.2.0

Development status: **paused after v0.2.0**. The list below closes the version;
nothing further is scheduled.

### Regression

- [x] every suite in `tests/` re-run from the final code, not from earlier results
- [x] repository validation passes
- [x] install, reinstall and both uninstall modes pass in a disposable HOME
- [x] hook handler matching contract passes, with mutation controls
- [x] normalized event boundary holds and the message snapshot still matches
- [x] duration, concurrency and orphan cleanup pass
- [x] detail level passes at both levels in both locales
- [x] project label resolution passes across every topology
- [x] privacy and leak suites pass
- [x] desktop and ntfy payload contracts pass
- [x] English and Brazilian Portuguese render every state
- [x] mutation controls kill a deliberately broken copy of the code

### Local installation

- [x] local installation synced to the released code
- [x] locale, detail level, elapsed-time preference, mobile state, ntfy server, topic and privacy flags preserved
- [x] unrelated Claude settings preserved
- [x] Claude settings backed up before rewriting
- [x] four hooks registered exactly once each
- [x] `./agentchime.ps1 doctor` returns `PASS`
- [x] live desktop and ntfy delivery of all three states

### Version and documentation

- [x] `VERSION` reads `0.2.0`
- [x] installer, CLI and example configuration state the same version
- [x] README release badge points at the tag
- [x] changelog carries a dated `0.2.0` section and an empty `Unreleased`
- [x] roadmap marks 0.1 and 0.2 shipped and the remainder as future work
- [x] roadmap records the development pause
- [x] release notes written and free of claims the release does not deliver
- [x] no file carries a private ntfy topic

### Release artifacts

- [x] archive rebuilt from the released code, not reused from v0.1
- [x] SHA-256 recomputed rather than read back from the checksum file
- [x] archive carries no repository, build, editor or local configuration file
- [x] archive's own `VERSION` matches the label

### GitHub release

The items above are what this commit records. Publication happens after it, in
this order, and its record is the release itself rather than a box ticked here
in advance:

1. push the release commit to `main`;
2. wait for remote CI to conclude success on that exact commit;
3. create the annotated `v0.2.0` tag on it and push the tag;
4. publish a public release — not a draft, not a prerelease — with the archive
   and the checksum attached;
5. re-download the published archive and confirm its digest matches the one
   audited locally.

`scripts/publish-github.ps1` performs steps 3 to 4. It refuses a dirty tree, a
branch other than `main`, and a release tag that already exists.

---

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
