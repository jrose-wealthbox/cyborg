---
id: ADR-20260813-progressive-memory-candidate-hooks
type: decision
status: active
title: Keep progressive memory extraction provisional and off the hook hot path
summary: Session-end adapters only normalize and enqueue bounded work; a detached provider-neutral worker may create non-authoritative candidate entries for explicit review.
created_at: '2026-08-13T00:46:09Z'
updated_at: '2026-08-13T00:46:09Z'
last_verified_at: '2026-08-13T00:46:09Z'
tags: [memory, hooks, candidates, security]
components: [motherbrain/adapters, motherbrain/bin/extract-memory-candidates, motherbrain/lib/motherbrain/candidates, docs/memory]
supersedes: []
superseded_by:
---
# Keep progressive memory extraction provisional and off the hook hot path

## Decision

Claude Code and Codex `SessionEnd` adapters only normalize a bounded provider payload, enqueue an idempotent job, detach a worker, and return. The provider-neutral worker may write real tracked entries under `docs/memory/candidates/`, but those entries remain non-authoritative until an explicit verification and promotion action.

Candidate extraction is optional and fail-open. It never automatically edits accepted memories or promotes, supersedes, retires, commits, or deletes memory entries.

## Context

Both harnesses expose session provenance and a transcript path, but their session-end hooks are advisory and have short execution budgets. Transcript content is also an untrusted input that may contain credentials, personal data, tool output, or prompt-injection text. Durable memory needs useful end-of-session capture without making conversation teardown, model availability, or automatic inference part of the correctness boundary.

## Alternatives considered

- Analyze the transcript synchronously in each hook: rejected because it couples extraction latency and provider availability to short teardown budgets.
- Let each harness own its extraction format and memory files: rejected because it forks the project protocol and makes equivalent Claude/Codex sessions produce incompatible state.
- Automatically promote high-confidence output: rejected because confidence is not verification and an inferred claim must not outrank accepted project evidence.
- Keep only the manual workflow: retained as the no-hook baseline, but optional candidates reduce the chance that genuinely durable discoveries are forgotten at handoff.

## Consequences

- The same normalized event and claim converge on content-derived queue and candidate IDs, making repeated hook delivery safe.
- Candidate files and the index may appear shortly after a session ends and may remain as uncommitted changes.
- Missing hooks, transcripts, backends, or successful extraction results do not affect ordinary conversations or manual memory maintenance.
- Reviewers must distinguish accepted active entries from candidates and independently verify candidates before promotion.
- The external analysis backend remains explicitly configured; the repository does not silently invoke a provider CLI or spend tokens.

## Evidence

- [`motherbrain/docs/HOOKS.md`](../../../motherbrain/docs/HOOKS.md): documents the normalized contract, provider adapters, backend schema, limits, and fail-open operation.
- [`motherbrain/test/motherbrain/candidates`](../../../motherbrain/test/motherbrain/candidates): verifies normalization, bounded transcript reading, redaction, idempotence, detached execution, indexing, promotion, dismissal, and failure modes.
- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks#sessionend-input): documents SessionEnd payloads, lack of decision control, and the default 1.5-second budget; accessed 2026-08-12.
- [Codex app-server lifecycle](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#example-unsubscribe-from-a-loaded-thread): documents advisory root-thread SessionEnd hooks and their timeout limits; accessed 2026-08-12.

## Revisit when

Revisit the queue boundary if both providers offer a durable native background-job API that survives session teardown. Revisit candidate authority only if the project adopts a separately reviewed, evidence-backed automatic promotion policy with an equivalent or stronger trust boundary.
