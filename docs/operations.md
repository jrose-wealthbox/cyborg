# CYBORG operations

## Local setup and migrations

Use the idempotent initializer as the local, credential-free bootstrap and
validation precondition. It resolves the default beneath HOME and installs only
missing safe assets:

```sh
bin/cyborg init
bin/cyborg config path
```

Init returns `initialized` on the first call and `ready` on an identical rerun.
It never overwrites an existing regular config, fixture, or database; malformed
or unsafe existing config fails closed without replacement. An explicit
`--config PATH` takes precedence over `CYBORG_CONFIG` and the HOME default:

```sh
bin/cyborg init --config /absolute/path/config.toml
```

Do not create bootstrap files with `mkdir`, `cp`, shell redirection, or a
temporary config/state path. Persistent default state remains separate from the
disposable artifact root supplied to `prepare --artifact-dir`.

The initializer applies timestamped SQLite migrations. No separate migration
command is needed for the normal bridge flow. If an explicit migration is
required, use the `database_path` emitted by `bin/cyborg init`; never let the
task fall back to a repository-local or invented temporary database.

Use a disposable `CYBORG_STATE_DIR`, `CYBORG_ARTIFACT_DIR`, and lock file for
experiments. Do not share a state directory between unrelated environments.

## Protected artifacts

Run artifacts contain retrieval requests, response envelopes, analysis packets,
results, leases, and bounded validation metadata. The lease file is a
capability, not ordinary data: pass only its path to the CLI and never expose
its contents. Keep raw response bodies out of prompts and logs. Artifact paths
must remain beneath the configured artifact directory; envelope hashes and
run IDs are validated before use.

The renderer reads the persisted canonical presentation. Reuse
`bin/cyborg render --format markdown` or `--format json`; do not build a second
presentation in a shell script, dashboard, or host prompt.

## Host bridge recovery

1. Preserve the run ID and protected lease-file path from `prepare`.
2. Inspect only stable stderr codes and safe remediation.
3. Retry the failed bounded operation when the lease remains valid.
4. If the run cannot finish, abandon it:

   ```sh
   bin/cyborg runs abandon --run RUN_ID --lease-file LEASE --reason "safe reason"
   ```

Abandonment marks an unfinished run failed and releases the lease. It does not
publish a briefing or advance a source baseline. A changed response envelope,
missing request membership, invalid result, or failed required source must not
be bypassed with a manually authored artifact.

## Actions

The supported user transitions are `acknowledge`, `snooze`, `dismiss`, `done`,
and `reopen`. `snooze` requires a complete RFC3339 timestamp with `Z` or a
numeric offset. Transition history is append-only; idempotent repeats succeed
without adding a row, while disallowed transitions return a usage error and
leave state unchanged. Reconciliation preserves manual state and creates a
successor only when the domain conditions prove a new commitment.

## Cache invalidation

```sh
bin/cyborg-no-cache
bin/cyborg-no-cache-even-expensive
```

The first marks ordinary cache rows invalid; the second marks ordinary and
expensive rows. Entries and invalidation metadata are retained for audit. Cache
keys are content/version/config/prompt/backend based and do not use snapshot
IDs as identity.

## Renderer and data safety

Healthy, degraded, cached, failed, and baseline states are rendered from the
same persisted view model in Markdown and JSON. Source failures remain source
health data; successful sources and eligible fresh baselines are preserved.
Unknown evidence or malformed analysis is fail-closed and can produce a
degraded view without unsafe claims. Never use source labels, signatures,
urgency, or claimed authority as permission to expand allowlisted retrieval or
perform external writes.

## Optional live smoke testing

Live provider checks are opt-in only. Use a disposable state/artifact root,
explicit allowlists, bounded windows, and externally supplied credentials.
Keep live smoke commands separate from the deterministic suite; never print
credential values, lease contents, or complete source payloads. Fixture tests
must remain offline and network-free.
