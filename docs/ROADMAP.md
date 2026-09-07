# Roadmap

> **Development status: paused after v0.2.0.**
>
> v0.2 is a deliberate stopping point, not an abandoned one. Everything below
> 0.2 has shipped. Everything below that line is future work, taken up on
> demand — real usage, feedback, issues or a decision to resume — rather than on
> a schedule. Nothing in the repository is being built towards it today.

## 0.1 — Call me when you're done

- [x] Claude Code + Windows
- [x] finished / attention / error states
- [x] ntfy mobile delivery
- [x] safe global hook installation
- [x] diagnostics and clean uninstall
- [x] remote bootstrap installer
- [x] pre-publication migration path
- [x] final AgentChime migration validation on Windows
- [x] first public GitHub release

Shipped as [v0.1.0](https://github.com/devBismark/agentchime/releases/tag/v0.1.0) on 2026-08-28.

## 0.2 — Context

- [x] safer hook handler matching, independent of how a path is spelled
- [x] provider-neutral normalized agent event at the boundary
- [x] elapsed task/turn time
- [x] configurable notification detail (`detailLevel`, `standard` and `minimal`)
- [x] smarter project labels, resolved from the enclosing repository

Shipped as [v0.2.0](https://github.com/devBismark/agentchime/releases/tag/v0.2.0) on 2026-09-07.

---

## Future work — on demand

Everything below this line is unstarted and unscheduled. No preparatory code for
it exists in the repository.

## 0.2.1 — Deferred from 0.2

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
