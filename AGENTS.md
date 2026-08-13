# Agent instructions

## Purpose

This file contains the repository's always-on, agent-agnostic rules. Keep it short and limited to rules that apply to every task. Detailed memory procedures live in [`docs/memory/PROTOCOL.md`](docs/memory/PROTOCOL.md) and must be read when maintaining the memory system.

## Start every task

1. Inspect the repository structure, relevant code, tests, and recent history before relying on remembered context.
2. If `docs/memory/INDEX.md` exists, use it to find only the memory entries relevant to the task. Read accepted active entries first; candidate entries are searchable evidence with lower authority and must be verified before use.
3. Before adding, correcting, retiring, or removing a memory entry, read [`docs/memory/PROTOCOL.md`](docs/memory/PROTOCOL.md).
4. Before handoff, check whether the work created a durable learning, architecture decision, correction, or retirement. If so, update the entry and index in the same reviewable change.

## Durable memory rules

The tracked memory system is the source of truth for durable project knowledge, but it does not replace checking the current implementation. Use code, tests, configuration, and verified runtime behavior for what the system does today; use active architecture decisions for intended design and rationale.

- Store durable knowledge as plain Markdown under `docs/memory/`, with one canonical entry per file.
- Keep `docs/memory/INDEX.md` as a compact, searchable catalog; it must stay synchronized with entries.
- Timestamp entries in UTC and include evidence links to relevant commits, pull requests, review comments, issues, local paths, or external sources.
- When a claim changes, create an explicit supersession or update the existing entry only after verification. Prefer the newest active, verified entry when claims conflict.
- Retire or retract stale knowledge instead of silently leaving conflicting active entries.
- Never store secrets, credentials, private keys, personal data, or confidential conversation content.
- Do not record session diaries, generic programming advice, or unsupported speculation.
- Entries under `docs/memory/candidates/` are provisional evidence, not project truth. Never promote, supersede, retire, or delete an accepted memory merely because a candidate conflicts with it.

Candidate extraction hooks are optional and fail-open. The ordinary handoff checklist and manual memory workflow remain authoritative when no hook or extraction backend is installed.

## Agent interoperability

`AGENTS.md` is the canonical shared instruction file. `CLAUDE.md` imports it with `@AGENTS.md`; do not duplicate repository rules in `CLAUDE.md` or add vendor-specific instructions here. Other tools may use their own adapters, but adapters should point to this file rather than fork its policy.

## Scope and precedence

These rules apply repository-wide. A nested `AGENTS.md` may add narrower path-specific rules but must not silently contradict the memory protocol. Direct system, developer, and user instructions take precedence over this file. Current code and verified runtime behavior take precedence over stale documentation.
