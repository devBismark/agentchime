# Changelog

## 0.1.0 - 2026-08-29

First public release candidate.

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

The underlying notifier flow has been validated on a real Windows + Claude Code + ntfy workflow. The renamed AgentChime migration build must pass the final local migration test before the public GitHub release is tagged.
