# Motherbrain

Motherbrain is a provider-neutral, project-local memory system for agent-assisted software work. It extracts reviewable ADR and learning candidates from optional Claude Code or Codex session-end hooks, while keeping accepted memory under explicit human or agent control.

This repository currently dogfoods Motherbrain inside CYBORG. The portable component is intentionally isolated so it can become an installable plugin or skill for other projects later.

## Boundary

```text
motherbrain/          reusable implementation, commands, adapters, tests, and protocol
docs/memory/          host-project data: CYBORG's accepted entries, candidates, and index
```

Motherbrain commands receive the host project root from the current working directory and write to that root's `docs/memory/`. They do not bundle or assume CYBORG-specific memory entries. Keep host application policy and project history outside this directory.

## Local commands

Run these from the CYBORG project root:

```sh
motherbrain/bin/extract-memory-candidates
motherbrain/bin/enqueue-memory-candidates claude_code
motherbrain/bin/manage-memory-candidate promote ADR-CAND-<digest>
motherbrain/bin/manage-memory-candidate dismiss LRN-CAND-<digest> "<reason>"
motherbrain/bin/rebuild-memory-index
```

The optional extraction backend is configured with `MOTHERBRAIN_CANDIDATE_BACKEND`. See [`docs/HOOKS.md`](docs/HOOKS.md) for the normalized JSON contract, harness setup, limits, and fail-open behavior. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) for candidate lifecycle and memory-authority rules.

## Tests

```sh
ruby -w -Imotherbrain/test -e 'Dir["motherbrain/test/**/*_test.rb"].sort.each { |file| require_relative file }'
```

Motherbrain remains an embedded directory-only package for now; no gemspec, publication, or separate repository is implied by this layout.
