# GitHub publication

Suggested repository name:

```text
agentchime
```

Suggested description:

> Stop watching your terminal. Windows + mobile notifications when Claude Code finishes, needs attention, or fails.

Suggested topics:

```text
claude-code
anthropic
ai-agents
coding-agents
powershell
windows
developer-tools
notifications
ntfy
open-source
```

## 1. Validate on Windows

Before publishing, require:

```powershell
.\agentchime.ps1 doctor
.\agentchime.ps1 test finished
.\agentchime.ps1 test attention
.\agentchime.ps1 test error
```

Then confirm one real Claude Code completion produces exactly one alert.

## 2. Initialize the public Git history

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\init-repo.ps1
```

This creates a clean `main` history using the Git identity already configured on the machine.

## 3. Authenticate GitHub CLI

If needed:

```powershell
gh auth login
```

## 4. Publish repository + v0.1.0 release

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish-github.ps1
```

The script:

1. validates the repository;
2. requires a clean `main` branch;
3. packages `agentchime-v0.1.0.zip` + SHA-256;
4. detects the authenticated GitHub username;
5. creates the public `agentchime` repository if needed;
6. pushes `main`;
7. configures repository topics;
8. creates/pushes tag `v0.1.0`;
9. publishes the release with the ZIP and checksum.

To publish under an organization or another explicit owner:

```powershell
.\scripts\publish-github.ps1 -Owner "your-org"
```

To create a draft release first:

```powershell
.\scripts\publish-github.ps1 -DraftRelease
```

## Release title

```text
AgentChime v0.1.0 - Stop watching your terminal
```

## Assets

```text
agentchime-v0.1.0.zip
agentchime-v0.1.0.sha256
```
