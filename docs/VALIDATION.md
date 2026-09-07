# Validation status

AgentChime v0.1.0 is based on a notifier that was validated through a real Claude Code workflow on Windows before the public rename.

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

## Still required before calling 1.0 stable

- wider real-world attention-event coverage
- end-to-end `StopFailure` coverage for multiple error categories
- fresh-machine bootstrap validation
- uninstall preservation test with unrelated third-party hooks
- signed/reproducible release artifacts
- broader Windows/PowerShell compatibility matrix

This document separates exercised behavior from structurally supported behavior.
