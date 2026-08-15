# One-Prompt Bootstrap and Ralph-Loop Design

## Goal

A user in a fresh CYBORG clone can paste the README's coding-harness prompt once. The harness initializes durable local configuration and state, publishes a fixture briefing, reruns without setup changes, and leaves `bin/cyborg render --format markdown` usable from a separate ordinary shell.

The loop evolves repository behavior and guidance, not model weights. Fresh subagents act as external operators and report observed friction; only the primary implementation agent edits the repository.

## User experience

The existing provider-neutral prompt remains the entry point. The CYBORG skill performs this sequence:

```text
cyborg config path
cyborg init
cyborg prepare
optional cyborg ingest
cyborg analysis-packet
host analysis
cyborg record-result
cyborg render --format markdown
```

The first fixture-backed run creates durable defaults beneath the user's normal locations:

```text
~/.config/cyborg/config.toml
~/.config/cyborg/fixture-records.json
~/Library/Application Support/CYBORG/cyborg.sqlite3
```

Platform path resolution remains owned by the existing `Config` and `Paths` abstractions. The paths above describe the current macOS defaults, not hard-coded cross-platform behavior.

Later harness runs reuse the same configuration, database, caches, actions, and latest-renderable pointer. A separate shell needs no inherited environment variables and can run:

```sh
bin/cyborg render --format markdown
```

## Initialization command

Add an idempotent `cyborg init` command implemented by Ruby. The command accepts the CLI's existing global `--config PATH` option and otherwise uses `Config.path`.

It produces one compact JSON object on stdout:

```json
{
  "status": "initialized",
  "config_path": "/absolute/path/config.toml",
  "fixture_path": "/absolute/path/fixture-records.json",
  "state_dir": "/absolute/path/state",
  "database_path": "/absolute/path/state/cyborg.sqlite3",
  "created": ["config", "fixture", "database"]
}
```

`status` is `initialized` when at least one resource was created and `ready` when all resources already existed and validated. `created` contains only resources created by this invocation, in the stable order `config`, `fixture`, `database`.

Initialization behavior:

1. Resolve the config path without loading it.
2. Open or create the config parent directory without following symlinks and enforce user-only directory permissions where supported.
3. If the config is absent, atomically copy the repository's safe `config/example.toml` content to the resolved location with mode `0600`.
4. Load and validate the config. An existing invalid config fails closed and is never replaced.
5. For the bundled fixture source, resolve its configured fixture path. If absent and the source matches the shipped fixture bootstrap contract, atomically copy `test/fixtures/sources/fixture-records.json` with mode `0600`. Never replace an existing fixture.
6. Resolve state paths through `Paths`, create the state directory safely, connect to SQLite, and apply migrations.
7. Emit the compact JSON result only after every step succeeds.

The command must not write credentials, invoke a network source, start a run, perform analysis, or publish a briefing.

## Repository asset boundary

The initializer needs shipped bootstrap assets after gem installation. Move or copy the safe example configuration and fixture payload into a runtime-owned package location under `lib/cyborg/assets/`, include those files in the gem specification, and treat them as immutable input templates. Repository-facing `config/example.toml` and test fixtures may remain for documentation and tests, but production initialization must not depend on the current working directory or the source checkout layout.

Tests verify that packaged assets and repository examples remain semantically equivalent. Asset content contains no secrets or machine-specific absolute paths.

## Safety and recovery

- Existing config, fixture, and database files are never overwritten or truncated.
- Every newly written regular file uses same-directory atomic creation and mode `0600`.
- Parent directories and final paths are checked without following symlinks. Unsafe path components fail with a stable configuration or persistence error.
- If config creation succeeds but a later step fails, retry reuses the valid config and continues. Initialization is convergent rather than transactionally deleting earlier safe work.
- Existing invalid configuration fails with exit `78` and `config.*` stderr; the command does not repair user-authored content.
- Unsafe artifacts or packaged asset corruption fail closed and emit no partial success JSON.
- Logs and output contain paths and bounded status metadata only—never file bodies, credentials, lease material, or raw database errors.

## Skill behavior

Add a bootstrap precondition to `skills/cyborg/SKILL.md`:

1. Run `cyborg config path`.
2. On every invocation, run `cyborg init` to validate existing defaults or create
   missing safe defaults.
3. Continue only after `cyborg init` exits `0` and reports `initialized` or `ready`.
4. Use the default config and persistent state for every subsequent bridge command.

The skill must not recreate initialization with shell `mkdir`/`cp` commands, invent temporary config/state paths, or set `CYBORG_CONFIG` merely because the default file is missing. An explicit user-supplied `--config` remains authoritative.

## Bounded Ralph loop

The acceptance loop uses fresh Luna/xhigh subagents as external coding-harness operators. Each subagent receives an isolated temporary `HOME`, a clean disposable artifact directory, the repository path, and the exact frozen README prompt. It may run shell commands and read the CYBORG skill/protocol but may not edit repository files.

### Baseline

Before implementing `cyborg init` or changing the skill, run a fresh subagent with the current prompt. Record its commands, exit statuses, created paths, final renderer output, and rationalization for any workaround. The current observed failure—creating `/private/tmp/cyborg-config.toml` and `/tmp/cyborg-state`, leaving an ordinary shell unable to render—is useful evidence but does not replace this controlled baseline.

### Iteration

For each iteration:

1. Run one fresh subagent from an empty temporary home.
2. Score the acceptance conditions below.
3. Record the smallest observed contract gap.
4. Add a failing automated regression or pressure scenario for that gap.
5. Make the minimal CLI, skill, or README change.
6. Run a new fresh subagent with the identical frozen prompt.

Only the primary agent edits and commits. Subagent state is disposable and never copied into project memory.

### Acceptance conditions

A GREEN iteration must prove all of the following:

- First prompt initializes config, fixture, database, and a completed fixture-backed briefing without asking the user for paths.
- Config, state, and database are created only beneath the platform defaults resolved from `HOME`. The loop's isolated `HOME` may itself be disposable, but the operator must not invent sibling paths such as `/tmp/cyborg-state`, `/private/tmp/cyborg-config.toml`, or paths inside the repository; only the explicitly requested artifact root may live outside the resolved home defaults.
- A second identical prompt performs idempotent initialization validation, reuses durable configuration/state, and does not incur a second backend analysis call for unchanged inputs.
- A separate clean shell with only `HOME` and `PATH` can run `bin/cyborg render --format markdown` successfully.
- Existing valid configuration is not modified on rerun.
- Existing invalid configuration fails closed and remains byte-for-byte unchanged.
- No lease contents, credentials, raw source envelopes, or protected payloads appear in prompts, logs, stdout, stderr, or the subagent report.
- `git status --short` is unchanged by every operator run.

The loop stops at the first fully GREEN iteration or after five iterations. At five unsuccessful iterations, stop and report the remaining architectural blocker rather than broadening scope or weakening an acceptance condition.

## Automated verification

Add real-executable system tests for:

- first initialization;
- idempotent repeated initialization;
- explicit `--config` initialization;
- missing fixture recovery;
- existing invalid config preservation;
- existing custom config/fixture preservation;
- symlink and permission failures;
- compact JSON and stable exit/stdout/stderr contracts;
- initialization from outside the repository working directory;
- render from a separate process with only the persistent default environment.

Run the complete deterministic CYBORG and Motherbrain suites after the Ralph loop is GREEN. Live GitHub credentials, network access, and real provider billing remain outside this acceptance loop.

## Alternatives considered

- Teach each harness to copy files with shell commands: rejected because setup policy would be duplicated across providers and agents would continue inventing temporary paths.
- Require the user to run `cyborg init` manually: simpler, but rejected for the selected one-prompt experience.
- Add `cyborg run` that launches a coding-harness CLI: rejected because it couples CYBORG to provider-specific executables, authentication, billing, and nested-agent behavior.

## Revisit conditions

Revisit automatic fixture bootstrap when a non-fixture source becomes the default onboarding path. Revisit launching a harness from CYBORG only if a provider-neutral, locally auditable execution protocol exists and the security/billing boundary is explicitly approved.
