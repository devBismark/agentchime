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

## Final release-candidate validation

Before tagging v0.1.0 publicly, validate the AgentChime migration build on the same Windows machine:

1. install AgentChime while the pre-publication configuration exists;
2. confirm the same ntfy topic is reused;
3. run `./agentchime.ps1 doctor` and require `PASS`;
4. test `finished`, `attention`, and `error`;
5. open a fresh Claude Code session and confirm one — and only one — completion alert arrives.

## Still required before calling 1.0 stable

- wider real-world attention-event coverage
- end-to-end `StopFailure` coverage for multiple error categories
- fresh-machine bootstrap validation
- uninstall preservation test with unrelated third-party hooks
- signed/reproducible release artifacts
- broader Windows/PowerShell compatibility matrix

This document separates exercised behavior from structurally supported behavior.
