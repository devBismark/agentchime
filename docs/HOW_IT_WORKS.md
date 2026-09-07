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

Claude Code passes hook context as JSON on stdin. AgentChime reads only the minimum useful fields, currently `cwd` for the project name and `error` for the `StopFailure` error type.

## How the project name is chosen

The adapter hands the working directory to a provider-neutral resolver, which returns one short name and never a path. The resolver walks upwards from the working directory looking for the first `.git` marker, and reports the name of the directory that carries it. Failing that, it reports the name of the working directory itself, and failing that, nothing, in which case the notification says `Claude Code`.

That single rule covers the cases that matter:

| Working directory | Reported |
| --- | --- |
| the root of a checkout | the checkout's name, exactly as before |
| `apps/web` inside a monorepo | the repository, not `web` |
| a repository checked out inside another one | the nearer of the two |
| a linked worktree | the worktree's own name |
| a folder outside any repository | the folder's name, exactly as before |
| a folder under a repository rooted at your account directory | the folder's name, never the account |

The walk stops at your account directory. A repository rooted there spans everything you own rather than one project, and the folder carrying it is usually named after your account, so it is never claimed as a project name.

The walk is a bounded sequence of existence checks. It starts no process, so git does not have to be installed; it opens no file, so the marker a worktree uses to point at its main checkout is never read; and it touches no network. Nothing else is consulted: not a remote, not an owner, not a package manifest, and not the contents of the checkout. Resolution is best effort, and a failure costs the name and nothing else.

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
