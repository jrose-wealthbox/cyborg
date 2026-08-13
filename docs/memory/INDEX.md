# Project memory index

This is a compact retrieval catalog. Read the linked entry before using it for a consequential change.

## Accepted active memories

| ID | Type | Status | Updated | Last verified | Topic/components | Summary | Entry |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ADR-20260813-risk-proportionate-concurrency | decision | active | 2026-08-13T20:29:30Z | 2026-08-13T20:29:30Z | architecture, concurrency, reliability, product scope; docs/cyborg-architecture-design-v2-sol-medium.md, lib/cyborg, test | Treat CYBORG as an informational dashboard and spend concurrency-engineering effort in proportion to plausible harm; eliminate races that threaten durable integrity, security, lifecycle correctness, or substantial unwanted token spend, while documented rare cosmetic anomalies may be accepted. | [entry](decisions/ADR-20260813-risk-proportionate-concurrency.md) |
| ADR-20260813-cyborg-v2-architecture-approved | decision | active | 2026-08-13T22:31:26Z | 2026-08-13T22:31:26Z | architecture, cyborg v1, bridge, analysis orchestration, budgets, persistence; docs/cyborg-architecture-design-v2-sol-medium.md, lib/cyborg/analysis/orchestrator.rb, lib/cyborg/runs/publisher.rb, db/migrations, skills/cyborg, test/system | CYBORG v2 is approved as implementation authority: v1 is a Ruby 4.x modular monolith with SQLite, direct GitHub and local-Git adapters, a protected host-analysis bridge, stable actions, and persisted Markdown/JSON views. | [entry](decisions/ADR-20260813-cyborg-v2-architecture-approved.md) |
| ADR-20260813-progressive-memory-candidate-hooks | decision | active | 2026-08-13T00:46:09Z | 2026-08-13T00:46:09Z | motherbrain/adapters, motherbrain/bin/extract-memory-candidates, motherbrain/lib/motherbrain/candidates, docs/memory | Session-end adapters only normalize and enqueue bounded work; a detached provider-neutral worker may create non-authoritative candidate entries for explicit review. | [entry](decisions/ADR-20260813-progressive-memory-candidate-hooks.md) |

## Candidates

Candidates are searchable evidence with lower authority than accepted memories. Review and promote them explicitly before treating them as project truth.

| ID | Type | Status | Updated | Last verified | Topic/components | Summary | Entry |
| --- | --- | --- | --- | --- | --- | --- | --- |

## Historical and dismissed memories

| ID | Type | Status | Updated | Last verified | Topic/components | Summary | Entry |
| --- | --- | --- | --- | --- | --- | --- | --- |
