---
id: ADR-20260813-cyborg-v2-architecture-approved
type: decision
status: active
title: Implement CYBORG v1 as the approved Ruby modular-monolith vertical slice
summary: CYBORG v2 is approved as implementation authority: v1 is a Ruby 4.x modular monolith with SQLite, direct GitHub and local-Git adapters, a protected host-analysis bridge, stable actions, and persisted Markdown/JSON views.
created_at: '2026-08-13T02:58:45Z'
updated_at: '2026-08-13T22:31:26Z'
last_verified_at: '2026-08-13T22:31:26Z'
tags: [architecture, cyborg, v1, bridge, persistence]
components: [docs/cyborg-architecture-design-v2-sol-medium.md, docs/superpowers/plans/2026-08-12-cyborg-v1-vertical-slice.md, lib/cyborg/analysis/orchestrator.rb, lib/cyborg/runs/publisher.rb, db/migrations, skills/cyborg, test/system]
supersedes: []
superseded_by:
---
# Implement CYBORG v1 as the approved Ruby modular-monolith vertical slice

## Decision

Use `docs/cyborg-architecture-design-v2-sol-medium.md` as the implementation authority for CYBORG. Build v1 as a headless Ruby 4.x modular monolith backed by one SQLite database, with deterministic domain policy in Ruby, direct read-only GitHub and local-Git sources, host-mediated probabilistic analysis through protected versioned JSON artifacts, stable user-controlled actions, and persisted Markdown/JSON presentation views.

The broader product brief remains product intent, while the v2 document's deferred list bounds v1. The original architecture design is historical context rather than the implementation authority.

## Context

The repository had an approved earlier architecture and a later v2 proposal that sharpened the host bridge, source baselines, action successors, lease model, budget semantics, artifact safety, first vertical slice, and acceptance criteria. Explicit approval makes those v2 boundaries stable enough to drive a file-level implementation plan.

## Alternatives considered

- Keep v2 proposed while implementing the earlier architecture: rejected because it would leave the sharper safety and persistence contracts advisory.
- Implement the entire product brief in v1: rejected by the approved v2 scope so source breadth does not hide defects in permanent core contracts.
- Put orchestration and policy in the host skill: rejected because cache, identity, validation, persistence, and rendering guarantees must be deterministic and auditable.

## Consequences

- V1 work follows the ordered plan under `docs/superpowers/plans/` and proves a narrow end-to-end slice before adding more providers or surfaces.
- Analysis execution is composed by the Ruby `Cyborg::Analysis::Orchestrator`, not by the host skill. It owns dependency-ready launches, validated backend outcomes, cross-run cache reuse, budget gating, provider-spend reconciliation, reservation release, hierarchical usage, and transactional cleanup after partial failure.
- Publication reconciliation preserves a concurrent manual action transition at the read/reconcile boundary; acceptance tests force that interleaving and require the manual state to win.
- `motherbrain/` stays separate from CYBORG application code.
- Direct provider backends, scheduling, additional remote sources, and additional renderers remain post-v1 work.
- Architecture deviations require explicit review and, when durable, a superseding memory decision.

## Evidence

- [`docs/cyborg-architecture-design-v2-sol-medium.md`](../../cyborg-architecture-design-v2-sol-medium.md): approved architecture, v1 scope, verification strategy, and acceptance criteria.
- [`docs/superpowers/plans/2026-08-12-cyborg-v1-vertical-slice.md`](../../superpowers/plans/2026-08-12-cyborg-v1-vertical-slice.md): file-level TDD implementation sequence derived from the approved design.
- [`lib/cyborg/analysis/orchestrator.rb`](../../../lib/cyborg/analysis/orchestrator.rb): implements the deterministic analysis execution, cache, budget, usage, and cleanup boundary.
- [`test/system/v1_acceptance_test.rb`](../../../test/system/v1_acceptance_test.rb): verifies backend reuse, budget exhaustion, provider-spend reconciliation, partial-failure rollback, concurrent manual transitions, and renderer equivalence.
- [`test/system/repeated_run_test.rb`](../../../test/system/repeated_run_test.rb): verifies one backend analysis execution across one hundred identical runs.

## Revisit when

Revisit the modular-monolith deployment boundary if measured concurrency or startup latency justifies a persistent service. Revisit the v1 boundary only through a deliberate scope decision that preserves the normalized records, actions, repositories, bridge validation, and presentation contracts.
