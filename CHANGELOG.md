# Changelog

## Unreleased

Nothing. Active development is paused after 0.2.0. See
[docs/ROADMAP.md](docs/ROADMAP.md) for what remains as future work.

## 0.2.0 - 2026-09-07

Published as
[v0.2.0](https://github.com/devBismark/agentchime/releases/tag/v0.2.0).

### Changed

- an agent event is normalized once, at the boundary, before anything renders
  or delivers it. Claude Code's payload is parsed in one adapter; the renderer
  and both delivery paths read a provider-neutral event instead of the vendor
  payload. Messages are unchanged, which the 72-case snapshot in
  `tests/fixtures/baseline-messages.json` pins

### Fixed

- hook handlers are matched on a normalized path key, so the same notifier
  spelled with forward slashes, with a trailing separator, in quotes or in a
  different case is recognised as one handler by the installer, the uninstaller
  and `doctor`. A handler that names a second script as well is reported as
  ambiguous rather than counted as healthy, and a reinstall replaces it
- `notify.ps1.bak`, and any longer name ending in the notifier's, are no longer
  claimed as AgentChime's

### Added

- elapsed turn time in the notification body, for example `(18m 42s)` in English
  and `(18min 42s)` in Brazilian Portuguese
- Claude Code `UserPromptSubmit` -> turn start marker, which sends no
  notification and only records when a turn began
- `privacy.sendDuration` configuration key, with `-EnableDuration` and
  `-DisableDuration` install switches; with it off, notifications are identical
  to v0.1
- `durationMs` on the normalized AgentEvent: optional, vendor neutral, and
  absent whenever no trustworthy measurement exists
- `detailLevel` configuration key with two levels, `standard` and `minimal`,
  plus a `-DetailLevel` install switch. `standard` is the default and renders
  exactly the message it rendered before the key existed; `minimal` drops the
  project label, the API error type and the elapsed time, and keeps the title,
  priority and tags so the state is still legible
- project names resolved from the nearest enclosing repository root rather than
  from the working directory alone, so `apps/web` inside a monorepo now reports
  the repository. A working directory that is already a repository root, or that
  is outside any repository, reports exactly what it reported before

### Notes

- project name resolution is provider neutral: it is handed a working directory
  and returns one short name, so a future adapter reuses it unchanged
- resolution walks for a `.git` marker and reads nothing else. No remote, owner,
  account, path, package manifest or checkout content is consulted, the marker
  file a worktree uses to name its main checkout is never opened, and no process
  or network request is involved, so git need not be installed
- a repository checked out inside another one reports the nearer of the two, and
  a linked worktree reports its own name
- the search stops at the account directory, so a repository rooted there never
  puts an account name in a notification
- `privacy.sendProjectName` set to `false` short-circuits resolution entirely:
  nothing is walked, derived or read
- project context is best effort, so a resolution failure costs the label and
  never the notification
- timings come from the performance counter, so moving the system clock cannot
  change a reported figure
- turn state lives in `~/.agentchime/turns/`, holds no prompt, output,
  transcript, absolute path or readable identifier, and is removed by uninstall
  including with `-KeepConfig`
- `doctor` now also expects the `UserPromptSubmit` hook; rerun `install.ps1`
  after upgrading
- privacy overrides detail: a detail level chooses only among context the
  privacy preferences already allow, so `sendProjectName` and `sendDuration`
  still suppress their fields at every level
- a config with no `detailLevel` key, or an unrecognised one, renders standard
  notifications; a reinstall preserves a recognised level and repairs an
  unrecognised one

## 0.1.0 - 2026-08-29

First public release. Published as
[v0.1.0](https://github.com/devBismark/agentchime/releases/tag/v0.1.0).

### Added

- Claude Code `Stop` -> finished notification
- Claude Code `StopFailure` -> error notification
- selected Claude Code `Notification` events -> attention notification
- native Windows notification + system sound
- optional ntfy mobile push
- English and Brazilian Portuguese messages
- safe backup before editing Claude settings
- idempotent hook registration
- `status`, `doctor`, `mobile`, and test commands
- clean uninstall that preserves unrelated Claude hooks
- remote bootstrap installer for one-command setup after GitHub publication
- automatic migration from the pre-publication notifier configuration

### Hardened through real use

- fixed a doctor false negative caused by JSON-escaped Windows paths
- hook/path matching is case-insensitive on Windows
- reinstall preserves locale, mobile state, ntfy server, topic, and project-name privacy preference
- duplicate AgentChime handlers are detected
- unknown/non-standard hook groups are preserved during install and uninstall
- attention matcher uses current Claude Code notification types: `permission_prompt`, `agent_needs_input`, and `elicitation_dialog`
- mobile delivery runs before the desktop balloon lifetime, so phone alerts are not artificially delayed
- mobile delivery errors are logged instead of silently disappearing

### Validation status

The notifier flow was validated on a real Windows + Claude Code + ntfy workflow before packaging, and the renamed AgentChime build passed its migration test on Windows ahead of tagging.

A post-release audit re-exercised the shipped scripts against throwaway home directories: install, reinstall, hook idempotency, preservation of unrelated Claude hooks, settings backups, both uninstall modes, `doctor`, live ntfy delivery in both locales, and remote bootstrap from the published tag. See [docs/VALIDATION.md](docs/VALIDATION.md) for what is exercised versus what is only structurally supported.
