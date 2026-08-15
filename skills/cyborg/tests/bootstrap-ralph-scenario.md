# Bootstrap Ralph Scenario

## Frozen operator prompt

```text
Read and use `skills/cyborg/SKILL.md`. Run CYBORG interactively with profile `default` and artifacts under `$CYBORG_RALPH_ARTIFACTS`. Follow `skills/cyborg/references/bridge-protocol.md` through prepare, optional retrieval ingestion, analysis-packet execution, record-result, and Markdown rendering. Display only the renderer output and keep lease contents and protected source payloads out of prompts and logs.
```

The scenario harness substitutes only `$CYBORG_RALPH_ARTIFACTS` with the
absolute disposable artifact directory.

## Immutable acceptance checks

- default config exists beneath `$HOME/.config/cyborg/`
- state/database exist beneath the platform default resolved from `$HOME`
- no ad hoc `/tmp/cyborg-state`, `/private/tmp/cyborg-config.toml`, or repository state exists
- first run publishes fixture Markdown
- second identical run reuses setup and expensive analysis
- clean-shell render succeeds with only HOME and PATH
- config bytes remain unchanged on rerun
- invalid existing config remains unchanged and fails closed
- no protected data appears in captured output
- repository status remains unchanged
