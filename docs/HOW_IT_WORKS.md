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

## Why AgentChime lives in ~/.agentchime

Claude Code is only one integration. Keeping the notifier/configuration outside `~/.claude` makes the core reusable for future Codex and other agent adapters.
