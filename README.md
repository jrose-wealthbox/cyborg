# CYBORG

CYBORG is a provider-neutral, local briefing system. It retrieves bounded
source data, persists immutable evidence and action state, validates host
analysis, publishes one canonical view, and renders that view as Markdown or
JSON.

## Install and configure

CYBORG requires Ruby 4.x and SQLite. Install the bundled dependencies. The
one-prompt harness flow performs safe, idempotent initialization automatically;
it needs no prior `mkdir`, `cp`, or `CYBORG_CONFIG` export:

```sh
bundle install
```

The configuration contains policy and identifiers only. Never put credentials,
tokens, passwords, private keys, or source bodies in it. The CLI creates and
migrates the SQLite database in the configured state directory. As an
observable troubleshooting command, run `bin/cyborg init`; it prints one compact
JSON object with `status` `initialized` or `ready`, resolved paths, and the
missing defaults it created. Existing defaults are validated and never
overwritten. Use `bin/cyborg config path` to inspect the resolved default.

The bundled fixture source is offline and credential-free, so the commands
above are enough to install dependencies; the skill's init precondition installs
the fixture beside the default configuration and keeps it usable outside the
repository directory.

## Credentials

CYBORG does not store provider or model credentials. Authentication remains
with the tool or coding harness that already owns it:

| Source or service | Credential source |
| --- | --- |
| Fixture | None; reads the copied local fixture file. |
| Local Git | None; reads existing local repositories without fetching. |
| GitHub | The authenticated GitHub CLI (`gh`) session. |
| LLM analysis | The active coding-harness session; CYBORG has no LLM API-key configuration field. |

For direct GitHub retrieval, install `gh` and authenticate it separately:

```sh
gh auth login --hostname github.com --web
gh auth status --active --hostname github.com
```

Then enable the GitHub source in `~/.config/cyborg/config.toml`. The source's
`account` value is an identifier, not a credential. For headless environments,
inject `GH_TOKEN` or `GITHUB_TOKEN` from a secret manager into the process
environment; these variables override stored `gh` credentials. Do not save
tokens in CYBORG TOML, committed `.env` files, prompts, logs, or artifacts.

## Run through a coding harness

CYBORG currently has no single `run` command. A coding harness coordinates the
versioned bridge workflow while Ruby retains authority over retrieval bounds,
validation, cache policy, action state, publication, and rendering.

Open the repository in Codex, Claude Code, or another coding harness that can
read local skills, then give it this prompt:

The skill first resolves the selected config and runs `cyborg init` on every
invocation. Continue only for the compact `initialized` or `ready` result; the
initializer owns all config, fixture, and persistent state creation.

```text
Read and use `skills/cyborg/SKILL.md`. Run CYBORG interactively with profile `default` and artifacts under `/tmp/cyborg-artifacts`. Follow `skills/cyborg/references/bridge-protocol.md` through prepare, optional retrieval ingestion, analysis-packet execution, record-result, and Markdown rendering. Display only the renderer output and keep lease contents and protected source payloads out of prompts and logs.
```

The harness will coordinate:

```text
init → prepare → optional ingest → analysis-packet →
  required: host analysis → record-result
  cached: CLI-provided analysis_result → record-result
→ render
```

The repository-local skill is not installed globally. If the harness does not
discover it automatically, explicitly direct the harness to the path shown in
the prompt.

When an explicit config is needed, pass `--config PATH` to the CLI commands;
that user choice takes precedence over `CYBORG_CONFIG` and the HOME default.
Keep persistent default state under its resolved state directory and use the
prompt's artifact directory only for disposable bridge artifacts.

## Manual host workflow

The provider-neutral host adapter is documented in
[`skills/cyborg/SKILL.md`](skills/cyborg/SKILL.md) and its
[bridge protocol](skills/cyborg/references/bridge-protocol.md). The short
workflow is:

```sh
bin/cyborg prepare --profile default --artifact-dir "$ARTIFACT_DIR"
bin/cyborg analysis-packet --run RUN_ID --lease-file LEASE
bin/cyborg record-result --run RUN_ID --lease-file LEASE --input RESULT_FILE
bin/cyborg render --format markdown
```

Host retrieval responses must use only declared request operations and bounds,
then be submitted with `bin/cyborg ingest`. Display only renderer output; do
not compose a substitute briefing. Pass the lease-file path—not its contents—to
later commands. Lease tokens and protected source payloads stay out of prompts,
arguments, logs, and displayed output.

## Actions and cache controls

User-controlled action transitions are available through `bin/cyborg actions`:

```sh
bin/cyborg actions acknowledge ACTION_ID
bin/cyborg actions snooze ACTION_ID --until 2026-08-14T12:00:00Z
bin/cyborg actions dismiss ACTION_ID
bin/cyborg actions done ACTION_ID
bin/cyborg actions reopen ACTION_ID
```

Repeating the current transition is idempotent; rejected transitions do not
append history. Snooze deadlines require RFC3339 with `Z` or a numeric offset.

Use `bin/cyborg-no-cache` for ordinary entries and
`bin/cyborg-no-cache-even-expensive` for both ordinary and expensive entries.
Invalidation marks rows and retains bounded audit metadata.

## Testing

Deterministic tests are offline and use bounded fixture/direct adapters:

```sh
bundle exec rake test
ruby -w -Imotherbrain/test -e 'Dir["motherbrain/test/**/*_test.rb"].sort.each { |f| require_relative f }'
```

Optional live smoke tests may be run manually with explicitly configured
credentials and a disposable state/artifact directory. They are never part
of deterministic tests and must not print credentials or source bodies.
