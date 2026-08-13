---
id: ADR-20260813-risk-proportionate-concurrency
type: decision
status: active
title: Scale concurrency safeguards to concrete product risk
summary: Treat CYBORG as an informational dashboard and spend concurrency-engineering effort in proportion to plausible harm; eliminate races that threaten durable integrity, security, lifecycle correctness, or substantial unwanted token spend, while documented rare cosmetic anomalies may be accepted.
created_at: 2026-08-13T20:29:30Z
updated_at: 2026-08-13T20:29:30Z
last_verified_at: 2026-08-13T20:29:30Z
tags: [architecture, concurrency, reliability, product-scope]
components: [docs/cyborg-architecture-design-v2-sol-medium.md, lib/cyborg, test]
supersedes: []
superseded_by: null
---

# Scale concurrency safeguards to concrete product risk

## Decision

CYBORG is a personal informational dashboard, not a mission-critical transaction-processing system. Concurrency controls must be chosen according to the plausible failure mode and its impact, rather than by attempting to eliminate every theoretical race.

Eliminate or strongly contain a race when it could plausibly cause:

- corruption or loss of durable database state;
- violation of a core run, lease, publication, or action-state invariant;
- duplicate or otherwise substantial unwanted model/token spend;
- disclosure of credentials, lease tokens, or other protected data; or
- repeated failures that prevent the dashboard from producing a trustworthy result.

A rare race may be accepted when its effects are bounded and cosmetic, such as temporarily stale presentation, slightly misordered informational items, or another anomaly corrected by the next refresh. When accepting such a race, leave a nearby code comment that identifies the interleaving, its bounded consequence, and why stronger synchronization is not currently justified.

For ambiguous cases, assess expected harm using severity, likelihood, recoverability, cost, and implementation complexity. Tests and reviews should target the harmful outcome, not demand transaction-level atomicity merely because concurrent execution is possible.

## Context

The approved v2 architecture includes concurrent runs, persisted leases, atomic artifact writes, and atomic final publication. Those mechanisms protect important boundaries, but applying equivalent synchronization to every read, ordering decision, or presentation update would add complexity that is disproportionate to CYBORG's product role.

This decision calibrates future implementation and review work. It does not waive explicit architecture invariants or justify silent data corruption. It requires reviewers to state the concrete failure mode before treating a possible race as blocking.

## Alternatives considered

- **Eliminate every identified race:** rejected because it would optimize for transaction-system guarantees, increasing locking, complexity, and maintenance burden without corresponding user benefit.
- **Ignore concurrency because CYBORG is personal software:** rejected because some races can still damage durable state, expose secrets, or trigger expensive duplicate analysis.
- **Use risk-proportionate safeguards:** chosen because it protects consequential outcomes while keeping the v1 implementation appropriately simple.

## Consequences

- Review findings about concurrency must describe a plausible interleaving and concrete impact.
- High-impact races remain blocking even when unlikely.
- Rare cosmetic races may remain when explicitly documented near the affected code.
- A tolerated race should be revisited if telemetry, tests, or user reports show greater frequency or impact than expected.

## Evidence

- [Approved CYBORG v2 architecture](../../cyborg-architecture-design-v2-sol-medium.md): establishes CYBORG as a personal information dashboard and defines the concurrency, lease, artifact, and publication boundaries this decision calibrates.
- [Architecture approval memory](ADR-20260813-cyborg-v2-architecture-approved.md): records the approved v1 scope and modular-monolith constraints.

## Revisit when

Revisit this decision if CYBORG becomes multi-user or externally hosted, controls consequential external actions, processes regulated or business-critical data, incurs materially larger automated model spend, or observed concurrency failures cease to be rare and bounded.
