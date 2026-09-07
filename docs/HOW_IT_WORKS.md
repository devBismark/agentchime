# How AgentChime works

AgentChime v0.1 is deliberately small.

## Event flow

```text
Claude Code hook event
        |
        v
powershell.exe -File ~/.agentchime/notify.ps1 <state>
        |
        +----> ntfy HTTP POST (optional)
        |
        +----> Windows NotifyIcon + system sound
```

Claude Code passes hook context as JSON on stdin. AgentChime reads only the minimum useful fields, currently `cwd` for the project folder name and `error` for the `StopFailure` error type.

## Hook mapping

- `UserPromptSubmit` -> `turn-start`
- `Stop` -> `finished`
- `StopFailure` -> `error`
- selected `Notification` types -> `attention`

The attention matcher currently includes:

- `permission_prompt`
- `agent_needs_input`
- `elicitation_dialog`

`idle_prompt` is deliberately excluded to prevent a second alert after a normal `Stop` alert.

## Why hooks are async

The hook handlers are registered with `"async": true`, so AgentChime does not make Claude wait for the mobile HTTP request or the Windows balloon notification lifecycle.

Claude Code reference: https://code.claude.com/docs/en/hooks

## Elapsed turn time

`UserPromptSubmit` is the only hook that marks the beginning of a turn, so it is
where the clock starts. Its handler sends no notification: it records a start
under `~/.agentchime/turns/` and exits.

Every hook payload carries a `session_id`, and a `prompt_id` that stays the same
from one submitted prompt until the next. `Stop` and `StopFailure` therefore
arrive with the same pair the start was recorded under, which is what lets two
sessions run at once without confusing their timings. Both ids are hashed before
they reach the store, so the record on disk cannot be read back to either one.

The measurement uses the performance counter rather than the wall clock, so
changing the system time or an NTP correction cannot alter a reported figure.
Each record also stores the instant that counter would have read zero; when two
records disagree there the machine rebooted between them, and AgentChime falls
back to wall time. A result that is negative, longer than 24 hours, or built
from a record it cannot parse is discarded rather than rendered, and the
notification is then exactly the v0.1 one.

`Notification` arrives while the turn is still running, so an attention alert
never reports or consumes a start.

## Notification detail level

The notifier renders exactly three pieces of variable context: the project
label, the API error type and the elapsed time. That bound is what fixes the
detail model at two levels rather than an arbitrary number. `standard` shows all
three, each still subject to the privacy preference that governs it. `minimal`
shows none of them. A third level would have nothing left to add without
collecting something new, so there is not one.

Detail level lives in the rendering layer alone. It reads the normalized
AgentEvent and decides what to print; it never reaches the Claude Code adapter,
the turn store, the hooks or either delivery provider, and it adds no field to
the event. Turning it down therefore changes the message and nothing else.

Privacy outranks it in both directions. A field a privacy preference suppressed
is already absent from the event, so no level can reach back for it, and the
minimal level suppresses all three whatever the preferences allow. Both rules
subtract, so the notification carries the intersection of what the two allow.

## Why AgentChime lives in ~/.agentchime

Claude Code is only one integration. Keeping the notifier/configuration outside `~/.claude` makes the core reusable for future Codex and other agent adapters.
