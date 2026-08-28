# Roadmap

## 0.1 — Call me when you're done

- [x] Claude Code + Windows
- [x] finished / attention / error states
- [x] ntfy mobile delivery
- [x] safe global hook installation
- [x] diagnostics and clean uninstall
- [x] remote bootstrap installer
- [x] pre-publication migration path
- [ ] final AgentChime migration validation on Windows
- [ ] first public GitHub release

## 0.2 — Context

- elapsed task/turn time
- smarter project labels
- configurable notification detail
- notification history
- stronger mobile authentication options

## 0.3 — CLI

Desired UX:

```text
agentchime install
agentchime status
agentchime doctor
agentchime test
agentchime mobile
agentchime uninstall
```

## 0.4 — Agents

- Codex adapter
- agent/provider abstraction
- shared notification engine
- adapter test fixtures

## 1.0 — Stable

- signed/reproducible release artifacts
- pinned bootstrap/release channel
- automated Windows install/uninstall integration tests
- polished launch assets and demo
- documented compatibility matrix

## 1.x — Multi-agent

Expand to additional coding agents without coupling the notification engine to a single vendor.

The architectural rule is simple: **agent adapters produce AgentChime events; delivery providers decide where those events go.**
