# AgentChime v0.1.0 — Stop watching your terminal

AgentChime calls you back when Claude Code finishes, needs attention, or stops because of an error — on Windows and optionally on your phone through ntfy.

## Highlights

- Windows desktop notification + system sound
- optional mobile notifications through ntfy
- Claude Code `Stop`, `StopFailure`, and selected `Notification` events
- global installation across projects
- safe backup of Claude settings
- idempotent reinstall without duplicate AgentChime hooks
- automatic reuse of an existing pre-publication configuration when detected
- `doctor`, `status`, `mobile`, and test commands
- English and Brazilian Portuguese messages
- one-command bootstrap installation

## The problem

Long agentic coding runs can take minutes or hours. Checking the terminal every few minutes wastes attention. AgentChime lets the agent call you back instead.

```text
Claude Code
     |
     +-- finished --------> Windows + phone
     +-- needs attention -> Windows + phone
     +-- API failure ------> Windows + phone
```

## Privacy by default

Mobile payloads intentionally exclude prompts, source code, secrets, and Claude output. When project-name sharing is enabled, only the current folder name is included as lightweight context.

## Validation

The notification engine was hardened through a real Windows + Claude Code + ntfy workflow before packaging this public release candidate.

AgentChime is project 001 from **IDISTØPIC LABS** — small tools for real workflow friction.
