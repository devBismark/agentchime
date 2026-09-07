# AgentChime v0.2.0 — Context

AgentChime calls you back when Claude Code finishes, needs attention, or stops
because of an error — on Windows and optionally on your phone through ntfy.

v0.1 told you *that* the turn ended. v0.2 tells you *which project* it was and
*how long* it took, and lets you turn that context down or off.

## What changed since v0.1.0

**Safer hook handler matching.** The installer, the uninstaller and `doctor`
now compare handlers on a normalized path key. The same notifier spelled with
forward slashes, with a trailing separator, in quotes, or in a different case is
recognised as one handler rather than as a stranger. A handler that also names a
second script is reported as ambiguous instead of counted as healthy, because
the leftover one can still be what actually runs. `notify.ps1.bak`, and any
longer name ending in the notifier's, are no longer claimed as AgentChime's.

**A normalized agent event at the boundary.** A hook payload is parsed once, in
one adapter, into a provider-neutral event. The renderer and both delivery paths
read that event instead of the vendor payload. Messages are unchanged: a 72-case
snapshot taken before the refactor still describes them exactly.

**Elapsed turn duration.** Finished and error notifications report how long the
turn took, for example `my-project - Claude finished the task. (18m 42s)`. The
turn start is recorded by a `UserPromptSubmit` hook that notifies nobody.
Timings come from the performance counter, so moving the system clock cannot
change a reported figure. Concurrent sessions are kept apart and abandoned turn
records are reclaimed. It is on by default; `-DisableDuration`, or
`privacy.sendDuration`, turns it off.

**Configurable notification detail.** `detailLevel` has two levels. `standard`
is the default and renders exactly the message it rendered before the key
existed. `minimal` drops the project label, the API error type and the elapsed
time, and keeps the title, priority and tags, so the state is still legible.
Detail chooses only among context your privacy preferences already allow: it can
leave something out, never put something back.

**Smarter project labels.** A project name is now resolved from the nearest
enclosing repository root rather than from the working directory alone, so
`apps/web` inside a monorepo reports the repository. Resolution walks for a
`.git` marker and reads nothing else — no remote, owner, account, path, package
manifest or checkout content, and no process or network request, so git need not
be installed. A repository checked out inside another reports the nearer of the
two, and a linked worktree reports its own name. The walk stops at the account
directory, so a repository rooted there never puts an account name in a
notification. With `sendProjectName` off, resolution is short-circuited
entirely: nothing is walked, derived or read.

**Much wider regression coverage.** v0.2 ships behavioural contract suites for
handler matching, event normalization, message baselines, duration, detail
levels, project labels, privacy, and the full install / reinstall / uninstall
lifecycle, all of which run against throwaway home directories rather than a
real installation. Several suites carry mutation controls: a deliberately broken
copy of the code must make the expectation fail, so an oracle that could never
fail is caught rather than trusted.

## Upgrading from v0.1.0

Re-run the installer. It preserves your locale, mobile state, ntfy server,
topic, detail level and privacy preferences, backs up Claude settings first, and
replaces its own handlers rather than adding to them.

`doctor` now also expects the `UserPromptSubmit` hook, so run it after
upgrading:

```powershell
.\agentchime.ps1 doctor
```

## Privacy by default

Mobile payloads still exclude prompts, source code, secrets and Claude output.
The project name is one short name; no path, remote address, organisation or
account name is ever read or sent. Turn records hold no prompt, output,
transcript, absolute path or readable identifier, and uninstall removes them
even with `-KeepConfig`.

## Scope

Windows and Claude Code, as in v0.1. This release does not add support for other
agents.

## Development status

v0.2.0 is a deliberate stopping point. Active development is paused here. The
remaining roadmap items are future work, taken up on demand rather than on a
schedule.

AgentChime is project 001 from **IDISTØPIC LABS** — small tools for real
workflow friction.
