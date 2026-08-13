# CYBORG

CYBORG is a provider-neutral, local briefing system. It retrieves bounded
source data, persists immutable evidence and action state, validates host
analysis, publishes one canonical view, and renders that view as Markdown or
JSON.

## Install and configure

CYBORG requires Ruby 4.x and SQLite. Install the bundled dependencies, copy
the safe example configuration, and point `CYBORG_CONFIG` at the copy:

```sh
bundle install
mkdir -p ~/.config/cyborg
cp config/example.toml ~/.config/cyborg/config.toml
cp test/fixtures/sources/fixture-records.json ~/.config/cyborg/fixture-records.json
export CYBORG_CONFIG="$HOME/.config/cyborg/config.toml"
bin/cyborg config path
```

The configuration contains policy and identifiers only. Never put credentials,
tokens, passwords, private keys, or source bodies in it. The CLI creates and
migrates the SQLite database in the configured state directory.

## Interactive host workflow

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
not compose a substitute briefing. Lease tokens and protected source payloads
stay out of prompts, arguments, logs, and displayed output.

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
