# Changelog

## Unreleased

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

### Notes

- timings come from the performance counter, so moving the system clock cannot
  change a reported figure
- turn state lives in `~/.agentchime/turns/`, holds no prompt, output,
  transcript, absolute path or readable identifier, and is removed by uninstall
  including with `-KeepConfig`
- `doctor` now also expects the `UserPromptSubmit` hook; rerun `install.ps1`
  after upgrading

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
