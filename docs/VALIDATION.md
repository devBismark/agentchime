# Validation status

AgentChime v0.1.0 is based on a notifier that was validated through a real Claude Code workflow on Windows before the public rename. The v0.2.0 audit is recorded further down.

## Confirmed on the underlying notifier

- Windows desktop completion alert
- ntfy phone completion alert
- real Claude Code `Stop` hook -> notifier -> Windows + phone
- repeated installation preserves the same ntfy configuration
- repeated installation does not duplicate hook entries
- `doctor` checks `Stop`, `StopFailure`, and `Notification` handlers plus ntfy server health
- manual `finished`, `attention`, and `error` notification tests

## Release validation

The AgentChime migration build was validated on Windows before v0.1.0 was tagged, and v0.1.0 was published on 2026-08-28:

1. install AgentChime while the pre-publication configuration exists;
2. confirm the same ntfy topic is reused;
3. run `./agentchime.ps1 doctor` and require `PASS`;
4. test `finished`, `attention`, and `error`;
5. open a fresh Claude Code session and confirm one — and only one — completion alert arrives.

## Post-release audit

A later audit re-ran the shipped scripts on Windows PowerShell 5.1 against throwaway home directories, so the operator's own installation was never used as the fixture. Confirmed:

- first install writes the notifier, the config, and one handler per event;
- reinstall is idempotent and preserves locale, mobile state, ntfy server, topic, and the project-name privacy setting;
- unrelated third-party hooks, unrelated hook events, non-standard hook groups, and unrelated top-level settings survive both install and uninstall;
- Claude settings are backed up before every install and before uninstall;
- `doctor` reports `PASS` on a healthy install, and reports the specific fault on a missing handler, a duplicated handler, or an unreadable config;
- a deliberately duplicated handler is repaired by reinstalling;
- `uninstall` removes only AgentChime handlers, and `-KeepConfig` retains the config and backups;
- live ntfy delivery of `finished`, `attention`, and `error` in both `en` and `pt-BR`;
- the mobile payload carries only title, body, priority, and tags, with the API error type included for `error`;
- a hook payload seeded with a prompt, an API key, a transcript path, assistant output, a session id, and an absolute path delivered none of them to ntfy;
- `sendProjectName: false` replaces the folder name with a generic label;
- an unreachable ntfy server logs the failure to `agentchime.log` and exits non-zero without leaking payload contents;
- a malformed config falls back to safe defaults, and a missing hook payload is tolerated;
- Windows desktop notifications fire for all three states;
- remote bootstrap installs correctly from the published `v0.1.0` tag and from `main`, and the tagged notifier is byte-identical to the notifier on `main`.

## v0.2.0 release audit

Before v0.2.0 was tagged, every suite in `tests/` was re-run from the final code
on Windows PowerShell 5.1, rather than relying on the result recorded when each
change was made. Thirty-two suites passed, together asserting 1,347 behaviours,
alongside the repository validation script. Each suite prints a success-only
token and refuses to report a pass if it ran fewer assertions than it declares,
so a suite that silently stopped exercising its subject fails instead of looking
green.

Re-exercised from the final code:

- **v0.1 core** — repository validation; install, reinstall and uninstall in
  both modes; `doctor` on a healthy install and on a degraded one; the
  `finished`, `attention` and `error` states; desktop styling; the ntfy payload
  contract; English and Brazilian Portuguese; the privacy switches; the
  bootstrap script; hook idempotency across repeated installs; and preservation
  of third-party hooks, unrelated hook events, non-standard hook groups and
  unrelated top-level Claude settings.
- **Handler matching** — a new contract suite pins the decision each entry point
  makes about which handlers are AgentChime's: separator, quoting, trailing
  separator and case variants of one path resolve to one handler; a handler that
  also names a second script is reported as ambiguous and replaced on reinstall;
  `notify.ps1.bak` and longer names ending in the notifier's are never claimed;
  an empty path targets nothing, so a bad call cannot delete every hook; and the
  three copies of the shared helpers are asserted byte-identical to each other.
- **Normalized event boundary** — Claude Code vocabulary is confined to the
  adapter, and the 72-case message snapshot taken before the refactor still
  describes the rendered messages exactly.
- **Turn duration** — measurement, session correlation, concurrent sessions,
  orphan cleanup, rendering in both locales, and the privacy of the turn store.
- **Detail level** — both levels in both locales, the default for a config with
  no key or an unrecognised one, and privacy overriding detail at every level.
- **Project labels** — resolution from the enclosing repository, nested
  repositories, linked worktrees, non-repository fallback, the account-root
  boundary, the `sendProjectName` short-circuit, resilience to unreadable
  directories, and a leak suite that asserts no path, id or account name reaches
  a payload.

Mutation controls back the duration, detail, label and handler suites: a
deliberately broken copy of the code is written to a temporary directory and the
same probe must fail against it, so an oracle that could never fail is caught
rather than trusted.

Also confirmed on the maintainer's own Windows machine, against the code being
released:

- the installed notifier is byte-identical to `src/notify.ps1`;
- reinstalling preserved the locale, detail level, elapsed-time preference,
  mobile state, ntfy server, topic and every privacy flag, and left the
  unrelated Claude settings untouched;
- Claude settings were backed up before being rewritten;
- each of `UserPromptSubmit`, `Stop`, `StopFailure` and `Notification` carries
  exactly one AgentChime handler, counted independently of `doctor`;
- `doctor` reports `PASS`;
- live desktop and ntfy delivery of `finished`, `attention` and `error`
  succeeded, leaving no entry in `agentchime.log`.

Live delivery was exercised in the locale the machine is configured for. Both
locales are covered exhaustively by the rendering suites rather than by live
sends.

The release archive was rebuilt from the tagged code, its SHA-256 recomputed
rather than read back from the checksum file, and its contents checked to
confirm it carries the project and no repository, build, editor or local
configuration file.

## Still required before calling 1.0 stable

- wider real-world attention-event coverage
- end-to-end `StopFailure` coverage for multiple error categories
- fresh-machine bootstrap validation
- signed/reproducible release artifacts
- broader Windows/PowerShell compatibility matrix

This document separates exercised behavior from structurally supported behavior.
