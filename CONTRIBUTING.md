# Contributing

AgentChime is intentionally small. Changes should preserve that property.

## Principles

- Prefer standard Windows/PowerShell capabilities over new dependencies.
- Do not send prompts, code, secrets, or transcripts to third parties by default.
- Installation must be reversible.
- Never overwrite unrelated Claude Code hooks.
- New agent integrations should be adapters, not forks of the notification core.

## Pull requests

Please explain:

1. the workflow friction being solved;
2. why it belongs in AgentChime;
3. how you tested install, reinstall, diagnostics, and uninstall on Windows.
