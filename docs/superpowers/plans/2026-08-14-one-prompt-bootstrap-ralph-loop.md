# One-Prompt Bootstrap and Ralph-Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a fresh coding-harness session initialize persistent CYBORG defaults, publish and rerun a fixture briefing, and leave ordinary-shell rendering usable from one README prompt.

**Architecture:** A new deterministic Ruby bootstrap service installs immutable packaged config/fixture assets through descriptor-anchored no-overwrite writes, validates the result, and migrates persistent SQLite state. The provider-neutral skill invokes idempotent `cyborg init` as its validation/bootstrap precondition, and the bridge reuses cached validated analysis for unchanged packets; fresh Luna/xhigh shell operators drive a bounded RED/GREEN Ralph loop against the exact frozen README prompt.

**Tech Stack:** Ruby 4.x, Sequel, sqlite3, Fiddle/POSIX `openat` family, Minitest, Markdown skills

## Global Constraints

- Work directly on `main`; do not create worktrees.
- Use fresh `gpt-5.6-luna` subagents at `xhigh` effort for Ralph operators, implementers, and reviewers.
- Only the primary/implementation agent edits repository files; Ralph operators are read/run-only.
- Never overwrite or truncate existing config, fixture, or database files.
- Never place credentials, lease contents, raw retrieval envelopes, or protected source payloads in prompts, logs, results, or committed fixtures.
- Deterministic acceptance uses the bundled fixture source with network and live credentials disabled.
- The frozen README prompt is identical in baseline and every GREEN iteration.
- The Ralph loop stops at the first fully GREEN iteration or after five iterations; never weaken an acceptance condition to obtain GREEN.
- Preserve unrelated user work and stage only task-scoped paths.

---

### Task 1: Establish the Fresh-Harness RED Baseline

**Files:**
- Create: `skills/cyborg/tests/bootstrap-ralph-scenario.md`
- Create: `skills/cyborg/tests/bootstrap-ralph-results.md`

**Interfaces:**
- Consumes: current `README.md`, `skills/cyborg/SKILL.md`, and `skills/cyborg/references/bridge-protocol.md`
- Produces: one frozen operator prompt and a scored baseline transcript summary used unchanged by Task 5

- [ ] **Step 1: Write the frozen scenario before changing the skill**

Create `bootstrap-ralph-scenario.md` with this exact operator prompt:

```text
Read and use `skills/cyborg/SKILL.md`. Run CYBORG interactively with profile `default` and artifacts under `$CYBORG_RALPH_ARTIFACTS`. Follow `skills/cyborg/references/bridge-protocol.md` through prepare, optional retrieval ingestion, analysis-packet execution, record-result, and Markdown rendering. Display only the renderer output and keep lease contents and protected source payloads out of prompts and logs.
```

The scenario harness substitutes only `$CYBORG_RALPH_ARTIFACTS` with the absolute disposable artifact directory. Record these immutable acceptance checks:

```markdown
- default config exists beneath `$HOME/.config/cyborg/`
- state/database exist beneath the platform default resolved from `$HOME`
- no ad hoc `/tmp/cyborg-state`, `/private/tmp/cyborg-config.toml`, or repository state exists
- first run publishes fixture Markdown
- second identical run reuses setup and the validated bridge result; the default zero-task packet makes no host-backend task calls
- clean-shell render succeeds with only HOME and PATH
- config bytes remain unchanged on rerun
- invalid existing config remains unchanged and fails closed
- no protected data appears in captured output
- repository status remains unchanged
```

- [ ] **Step 2: Run one fresh Luna/xhigh baseline operator**

Dispatch a fresh operator with no prior conversation context. Create a disposable source snapshot that excludes `.git`, record a SHA-256 manifest of every snapshot file, and give the operator that snapshot path, a newly created disposable home, a newly created artifact directory, the frozen prompt, and these constraints:

```text
Do not edit repository files. Do not create config/state outside defaults resolved from the supplied HOME. Run the prompt as an external user, then rerun it once and try `bin/cyborg render --format markdown` from a clean shell. Return commands, exit statuses, created path names, bounded stdout/stderr codes, and acceptance verdicts. Never return file bodies, lease contents, raw envelopes, or secrets.
```

Every CYBORG command must run through a sanitized environment containing only `HOME`, a minimal `PATH`, `CYBORG_RALPH_ARTIFACTS`, and locale variables required by Ruby. Explicitly unset every inherited `CYBORG_*` value before adding only `CYBORG_RALPH_ARTIFACTS`. Compare the snapshot manifest before/after, and compare the real repository's `git status --short --ignored` plus binary diff before/after. A changed snapshot or repository is RED even when ordinary `git status --short` is empty.

Expected RED: `config.not_found`, an invented temporary config/state workaround, or clean-shell rendering failure.

- [ ] **Step 3: Record the exact baseline without copying protected data**

Write `bootstrap-ralph-results.md` with:

```markdown
## Baseline RED

- Operator model/effort: gpt-5.6-luna / xhigh
- Frozen prompt hash: the SHA-256 computed from the prompt block
- Commands and exit statuses: the operator's bounded command/status list
- Created path names: paths only
- Failed acceptance checks: each failed check by its scenario name
- Rationalization/workaround: the operator's exact bounded explanation
- Protected-data scan: pass|fail
```

Replace angle-bracket fields with observed values; do not include placeholders in the committed file.

- [ ] **Step 4: Verify RED evidence and commit**

Run:

```sh
status=0; bundle exec ruby bin/cyborg init >/tmp/cyborg-init-red.stdout 2>/tmp/cyborg-init-red.stderr || status=$?; test "$status" -eq 64
rg -n "Baseline RED|Failed acceptance checks|Protected-data scan" skills/cyborg/tests/bootstrap-ralph-results.md
git add skills/cyborg/tests/bootstrap-ralph-scenario.md skills/cyborg/tests/bootstrap-ralph-results.md
git diff --cached --check -- skills/cyborg/tests
```

Expected: baseline documents at least one failed acceptance check and contains no protected data.

Commit:

```sh
git commit -m "test: capture cyborg bootstrap ralph baseline"
```

---

### Task 2: Build Packaged, No-Overwrite Bootstrap Services

**Files:**
- Create: `lib/cyborg/bootstrap/assets.rb`
- Create: `lib/cyborg/bootstrap/safe_filesystem.rb`
- Create: `lib/cyborg/bootstrap/initializer.rb`
- Create: `lib/cyborg/assets/config.example.toml`
- Create: `lib/cyborg/assets/fixture-records.json`
- Modify: `lib/cyborg.rb`
- Modify: `lib/cyborg/database.rb`
- Modify: `lib/cyborg/cli.rb`
- Modify: `cyborg.gemspec`
- Test: `test/unit/bootstrap/assets_test.rb`
- Test: `test/unit/bootstrap/safe_filesystem_test.rb`
- Test: `test/unit/bootstrap/initializer_test.rb`
- Test: `test/integration/database_test.rb`

**Interfaces:**
- Consumes: `Config.path(path:, env:)`, `Config.load(path:, env:)`, `Paths.resolve(config:, env:)`, and `Database.connect(path:)`
- Produces: `Cyborg::Bootstrap::Initializer#call(config_path: nil, env: ENV) -> Cyborg::Bootstrap::Result`
- Produces: `Cyborg::Bootstrap::Result = Data.define(:status, :config_path, :fixture_path, :state_dir, :database_path, :created)`
- Produces: `Cyborg::Bootstrap::SafeFilesystem#install(path:, bytes:, mode: 0o600) -> :created | :existing`
- Produces: `Cyborg::Bootstrap::SafeFilesystem#ensure_directory(path:, mode: 0o700) -> :created | :existing`
- Produces: `Cyborg::Bootstrap::SafeFilesystem#regular_file_identity(path:) -> Data(dev, ino, mode, uid)` using `openat(..., O_NOFOLLOW)` plus `fstat`
- Produces: `Cyborg::Database.connect(path:, busy_timeout_ms:, filesystem:) -> Sequel::Database`, with safe empty-file creation/validation before SQLite open

- [ ] **Step 1: Write failing packaged-asset and safe-filesystem tests**

Add tests with these concrete assertions:

```ruby
def test_packaged_assets_match_repository_examples
  assert_equal File.binread("config/example.toml"), Cyborg::Bootstrap::Assets.config_bytes
  assert_equal JSON.parse(File.read("test/fixtures/sources/fixture-records.json")),
    JSON.parse(Cyborg::Bootstrap::Assets.fixture_bytes)
end

def test_install_is_atomic_private_and_never_overwrites
  target = File.join(@home, ".config", "cyborg", "config.toml")
  assert_equal :created, @filesystem.install(path: target, bytes: "first")
  assert_equal 0o600, File.stat(target).mode & 0o777
  assert_equal :existing, @filesystem.install(path: target, bytes: "second")
  assert_equal "first", File.binread(target)
end

def test_install_rejects_symlinked_parent_and_final_path
  File.symlink(@outside, File.join(@home, ".config"))
  error = assert_raises(Cyborg::InvalidConfiguration) do
    @filesystem.install(path: File.join(@home, ".config", "cyborg", "config.toml"), bytes: "safe")
  end
  assert_equal "config.unsafe_path", error.code
  refute File.exist?(File.join(@outside, "cyborg", "config.toml"))
end
```

Also force an interleaving that swaps a checked parent before publication and assert the outside target remains byte-for-byte unchanged. Test `ensure_directory` separately: newly created bootstrap-owned config/state directories are `0700`; an existing bootstrap-owned directory that is group/world writable or not owned by the current user fails with `config.unsafe_path`; ordinary non-writable ancestors such as `/` and `/Users` remain valid.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```sh
bundle exec ruby -Itest test/unit/bootstrap/assets_test.rb
bundle exec ruby -Itest test/unit/bootstrap/safe_filesystem_test.rb
```

Expected: load errors because the bootstrap modules/assets do not exist.

- [ ] **Step 3: Package immutable bootstrap assets**

Copy the repository examples byte-for-byte to `lib/cyborg/assets/`. Implement:

```ruby
module Cyborg
  module Bootstrap
    module Assets
      ROOT = File.expand_path("../assets", __dir__).freeze
      CONFIG_PATH = File.join(ROOT, "config.example.toml").freeze
      FIXTURE_PATH = File.join(ROOT, "fixture-records.json").freeze

      module_function

      def config_bytes = File.binread(CONFIG_PATH)
      def fixture_bytes = File.binread(FIXTURE_PATH)
    end
  end
end
```

Keep `spec.files = Dir[...]` including `lib/**/*.toml` and `lib/**/*.json`; add explicit patterns if the existing `lib/**/*` glob does not include non-Ruby files in a built gem. Build the gem and inspect its file list.

- [ ] **Step 4: Implement descriptor-anchored no-overwrite installation**

Implement `SafeFilesystem` with libc bindings already supported by the project's Fiddle dependency:

```ruby
extern "int open(const char *, int)"
extern "int openat(int, const char *, int, int)"
extern "int mkdirat(int, const char *, int)"
extern "int linkat(int, const char *, int, const char *, int)"
extern "int unlinkat(int, const char *, int)"
extern "int fchmod(int, int)"
extern "int fsync(int)"
```

For an expanded absolute target:

1. Open `/` as a directory and retain its fd.
2. Normalize the absolute path, reject `.`/`..` traversal components, and traverse each parent segment with `openat(..., O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`; create a missing segment with `mkdirat(..., 0700)`, then reopen it. Verify every retained descriptor with `fstat` before continuing.
3. If the final entry exists, open it with `O_RDONLY|O_NOFOLLOW`, require a regular file, and return `:existing` without reading or changing it.
4. Create a random same-directory temp entry with `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0600`; write all bytes, `fchmod`, flush, and `fsync`.
5. Publish without overwrite using `linkat(parent_fd, temp_name, parent_fd, final_name, 0)`. On `EEXIST`, reopen the final entry with `O_RDONLY|O_NOFOLLOW`, require a regular file, and only then return `:existing`; every other error is `config.unsafe_path` or `config.persistence` as classified by errno.
6. Always `unlinkat` the temp entry and fsync the parent directory.

`ensure_directory` uses the same retained-fd traversal, creates only missing segments with `mkdirat(..., 0700)`, and rejects symlink or non-directory segments. It never chmods a pre-existing directory. For the bootstrap-owned leaf directory, require current-user ownership and no group/world permission bits; fail closed instead of silently changing an existing directory. Ancestor traversal requires directories that are not group/world writable, except a platform temporary ancestor with the sticky bit; it does not require every ancestor to be mode `0700`.

Do not use pathname `File.write`, `File.rename`, `FileUtils.cp`, or check-then-write logic for bootstrap targets.

- [ ] **Step 5: Write failing initializer and database no-follow tests**

Add:

```ruby
def test_first_call_installs_assets_migrates_database_and_reports_created_order
  result = @initializer.call(env: {"HOME" => @home})
  assert_equal "initialized", result.status
  assert_equal %w[config fixture database], result.created
  assert File.file?(result.config_path)
  assert File.file?(result.fixture_path)
  assert File.file?(result.database_path)
end

def test_existing_invalid_config_is_unchanged
  path = File.join(@home, ".config", "cyborg", "config.toml")
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, "not = [toml")
  before = File.binread(path)
  assert_raises(Cyborg::InvalidConfiguration) { @initializer.call(env: {"HOME" => @home}) }
  assert_equal before, File.binread(path)
end

def test_database_connect_rejects_symlink
  File.symlink(@outside_database, @database_path)
  error = assert_raises(Cyborg::DatabaseError) { Cyborg::Database.connect(path: @database_path) }
  assert_equal "database.unsafe_path", error.code
end
```

Also test valid custom config/fixture preservation, missing fixture recovery, retry after injected post-config failure, explicit config path, and absence of source/network/run/publication rows after initialization. Add a mode test that holds a live WAL connection open and asserts the database, `-wal`, and `-shm` files are all `0600`. Add a forced interleaving that swaps the validated database entry before SQLite opens it; assert `database.unsafe_path`, no migration, and an unchanged outside target.

- [ ] **Step 6: Implement the initializer and safe SQLite provisioning**

Use this shape:

```ruby
module Cyborg
  module Bootstrap
    Result = Data.define(:status, :config_path, :fixture_path, :state_dir, :database_path, :created)

    class Initializer
      def initialize(filesystem: SafeFilesystem.new, database: Database, assets: Assets)
        @filesystem = filesystem
        @database = database
        @assets = assets
      end

      def call(config_path: nil, env: ENV)
        environment = env.to_h.transform_keys(&:to_s)
        resolved_config = Config.path(path: config_path, env: environment)
        created = []
        created << "config" if @filesystem.install(path: resolved_config, bytes: @assets.config_bytes) == :created
        config = Config.load(path: resolved_config, env: environment)
        fixture_path = resolve_bootstrap_fixture(config, environment)
        created << "fixture" if fixture_path && @filesystem.install(path: fixture_path, bytes: @assets.fixture_bytes) == :created
        paths = Paths.resolve(config:, env: environment)
        @filesystem.ensure_directory(path: paths.state.to_s)
        database_state = @filesystem.install(path: paths.database.to_s, bytes: "", mode: 0o600)
        db = @database.connect(path: paths.database)
        db.migrate!
        created << "database" if database_state == :created
        Result.new(created.empty? ? "ready" : "initialized", resolved_config, fixture_path, paths.state.to_s, paths.database.to_s, created.freeze)
      ensure
        db&.disconnect
      end
    end
  end
end
```

`resolve_bootstrap_fixture` returns a path only when an enabled fixture source declares the shipped bootstrap path contract. Expand `~/` against `environment.fetch("HOME", Dir.home)`; reject relative, missing, non-string, or non-fixture targets with `config.invalid_fixture_path` rather than guessing.

Do not use SQLite's numeric `SQLITE_OPEN_NOFOLLOW`: the bundled sqlite3 2.9.6 / SQLite 3.53.2 combination rejects that flag even for an ordinary file. Instead, `SafeFilesystem#install(..., bytes: "", mode: 0o600)` atomically creates or descriptor-validates the database as a regular non-symlink before Sequel connects. `Database.connect` accepts an injectable filesystem and performs the same install/validation itself, preserving its existing convenience for callers; the initializer performs it once beforehand only to capture `created` deterministically, and the repeated validation is intentional.

Before opening SQLite, capture the database identity from a retained `O_NOFOLLOW` descriptor. Make the first line of Sequel's `after_connect` callback reacquire the descriptor-anchored identity and require the same device/inode, regular-file type, owner, and safe mode before any CYBORG pragma, migration, or write. A symlink or identity mismatch disconnects immediately with `database.unsafe_path`. Test the exact validation/open interleaving with an injectable hook. The bootstrap-owned state directory is current-user-owned `0700`, so untrusted users cannot rename entries; the identity handshake detects accidental or adversarial swaps within the current process boundary supported by this design.

Keep `PRAGMA journal_mode = WAL`; on this stack SQLite derives WAL/SHM permissions from the pre-created database, and the live-sidecar integration test locks that behavior down. Change normal container construction to validate/create the state leaf with `SafeFilesystem#ensure_directory` instead of `FileUtils.mkdir_p`, preventing later commands from bypassing the same path policy.

- [ ] **Step 7: Run focused and full tests, then commit**

Run:

```sh
bundle exec ruby -Itest test/unit/bootstrap/assets_test.rb
bundle exec ruby -Itest test/unit/bootstrap/safe_filesystem_test.rb
bundle exec ruby -Itest test/unit/bootstrap/initializer_test.rb
bundle exec ruby -Itest test/integration/database_test.rb
gem build cyborg.gemspec --output /private/tmp/cyborg-bootstrap-verification.gem
gem specification /private/tmp/cyborg-bootstrap-verification.gem files | rg "(db/migrations/.*\\.rb|lib/cyborg/assets/(config.example.toml|fixture-records.json))"
bundle exec rake test
git diff --check
```

Inspect the built gem specification and confirm every `db/migrations/*.rb` path and both asset paths are present; do not commit the built gem.

Commit:

```sh
git add cyborg.gemspec lib/cyborg.rb lib/cyborg/bootstrap lib/cyborg/assets lib/cyborg/database.rb lib/cyborg/cli.rb test/unit/bootstrap test/integration/database_test.rb
git commit -m "feat: initialize persistent cyborg defaults"
```

---

### Task 3: Expose the Idempotent `cyborg init` CLI Contract

**Files:**
- Create: `lib/cyborg/commands/init.rb`
- Modify: `lib/cyborg.rb`
- Modify: `lib/cyborg/cli.rb`
- Create: `test/system/init_cli_test.rb`
- Modify: `test/unit/cli_test.rb`

**Interfaces:**
- Consumes: `Bootstrap::Initializer#call(config_path:, env:) -> Bootstrap::Result`
- Produces: `cyborg init [--config PATH]` with exit `0`, compact JSON stdout, and empty stderr on success
- Produces error mapping: usage `64`, persistence `73`, invalid configuration/unsafe config path `78`

- [ ] **Step 1: Write failing real-executable CLI tests**

Create tests that spawn `bin/cyborg` with isolated `HOME` and no CYBORG variables:

```ruby
def test_init_creates_persistent_defaults_and_is_idempotent
  first = run_cli("init")
  assert_equal 0, first.status
  assert_empty first.stderr
  document = JSON.parse(first.stdout)
  assert_equal "initialized", document.fetch("status")
  assert_equal %w[config fixture database], document.fetch("created")

  config_before = File.binread(document.fetch("config_path"))
  second = run_cli("init")
  assert_equal 0, second.status
  assert_equal "ready", JSON.parse(second.stdout).fetch("status")
  assert_empty JSON.parse(second.stdout).fetch("created")
  assert_equal config_before, File.binread(document.fetch("config_path"))
end
```

Add exact tests for explicit `--config`, invocation outside the repository cwd, extra/duplicate/missing options, invalid existing config preservation, symlinked parent/final paths, permission failures, no source/run/publication rows, one-line JSON, and file/directory modes.

- [ ] **Step 2: Run the system tests and verify RED**

Run:

```sh
bundle exec ruby -Itest test/system/init_cli_test.rb
```

Expected: exit `64` with `cli.unknown_command` because `init` is not dispatched.

- [ ] **Step 3: Add early init dispatch without building a normal container**

Implement `Commands::Init` as a standalone adapter:

```ruby
module Cyborg
  module Commands
    class Init
      def initialize(stdout:, env:, initializer: Bootstrap::Initializer.new)
        @stdout = stdout
        @env = env
        @initializer = initializer
      end

      def call(config_path: nil)
        result = @initializer.call(config_path:, env: @env)
        @stdout.puts(JSON.generate(
          "status" => result.status,
          "config_path" => result.config_path,
          "fixture_path" => result.fixture_path,
          "state_dir" => result.state_dir,
          "database_path" => result.database_path,
          "created" => result.created
        ))
        0
      end
    end
  end
end
```

In `CLI#dispatch`, accept `init`, extract the existing global `--config`, reject every remaining argument, and call `Commands::Init` before `build_container`. Preserve the existing rescue/error-code boundary and stdout truncation behavior.

- [ ] **Step 4: Run focused, security, and full tests**

Run:

```sh
bundle exec ruby -Itest test/system/init_cli_test.rb
bundle exec ruby -Itest test/unit/cli_test.rb
bundle exec ruby -Itest test/contract/bridge/artifact_store_test.rb
bundle exec rake test
git diff --check
```

Expected: init/system/security/full suites pass with no network access.

- [ ] **Step 5: Commit**

```sh
git add lib/cyborg.rb lib/cyborg/cli.rb lib/cyborg/commands/init.rb test/system/init_cli_test.rb test/unit/cli_test.rb
git commit -m "feat: expose cyborg initialization"
```

---

### Task 4: Wire Persistent Cache Reuse Into the Host Bridge

**Files:**
- Create: `lib/cyborg/analysis/bridge_cache.rb`
- Modify: `lib/cyborg/commands/analysis_packet.rb`
- Modify: `lib/cyborg/commands/record_result.rb`
- Modify: `config/example.toml`
- Modify: `lib/cyborg/assets/config.example.toml`
- Test: `test/unit/analysis/bridge_cache_test.rb`
- Modify: `test/system/bridge_cli_test.rb`
- Modify: `test/system/repeated_run_test.rb`

**Interfaces:**
- Consumes: the canonical analysis packet, configured `analysis.backend_identity`, expensive-cache TTL, and validated `analysis_result` payload
- Produces: `Cyborg::Analysis::BridgeCache#fetch(packet:, backend_identity:, now:) -> Hash | nil`
- Produces: `Cyborg::Analysis::BridgeCache#store(packet:, result:, backend_identity:, run_id:, now:) -> true`
- Extends `analysis-packet` stdout with `analysis_status: required|cached` and `analysis_result: PATH|null`

- [ ] **Step 1: Write failing cache-key and bridge lifecycle tests**

Add unit tests proving the bridge cache fingerprint excludes only run-scoped identity (`run_id` and envelope timestamps), while changing records, evidence fingerprints, task declarations, action-state version, prompt/config versions, or backend identity misses the cache. Invalidated/expired rows also miss.

Extend the real bridge system test to run the same fixture flow twice with different run IDs:

```ruby
first_packet = run_cli("analysis-packet", "--run", first_run, "--lease-file", first_lease)
assert_equal "required", JSON.parse(first_packet.stdout).fetch("analysis_status")
record_fixture_result(first_run, first_lease)

second_packet = run_cli("analysis-packet", "--run", second_run, "--lease-file", second_lease)
second_status = JSON.parse(second_packet.stdout)
assert_equal "cached", second_status.fetch("analysis_status")
assert File.file?(second_status.fetch("analysis_result"))
record = run_cli("record-result", "--run", second_run, "--lease-file", second_lease,
                 "--input", second_status.fetch("analysis_result"))
assert_equal 0, record.status
```

Assert the cached artifact is a newly built envelope re-bound to the second run and protected by the existing canonical payload hash, contains the previously validated bounded payload, produces an equivalent presentation, and adds no provider-reported cost. Add negative cases for changed fixture input, changed backend identity, corruption, expiry, and invalidation.

- [ ] **Step 2: Verify the bridge-cache tests are RED**

Run:

```sh
bundle exec ruby -Itest test/unit/analysis/bridge_cache_test.rb
bundle exec ruby -Itest test/system/bridge_cli_test.rb --name /cache/
```

Expected: missing `BridgeCache` and missing `analysis_status` contract.

- [ ] **Step 3: Implement packet-level bridge caching**

Use the existing `Repositories::CacheRepository`, `CachePolicy`, and `CacheKey`; do not add a parallel table. Build the cache input from the canonical packet after removing only `run_id` and run-created timestamps. Use:

```ruby
CacheKey.call(
  stage: "bridge_analysis",
  input: reusable_packet,
  implementation_version: Pipeline::AnalysisPacketBuilder::VERSION,
  config_fingerprint: packet.fetch("configuration_version"),
  adapter_versions: packet.fetch("versions"),
  prompt_version: packet.fetch("prompt_version"),
  backend_identity:
)
```

`RecordResult` stores only a successfully validated result, in the same database transaction that successfully publishes it, with cache class `expensive`, the configured TTL, the canonical input fingerprint, and the original bounded result payload that passed validation (including its task-result declarations). The idempotent retry path repairs a missing cache row before returning success. Never cache a rejected/degraded result. `AnalysisPacket` checks the same key after writing the packet. On a hit, it writes a new `analysis_result` envelope bound to the current run via `ArtifactStore`; on a miss, `analysis_result` is `null`. Cache payloads never contain the lease or raw retrieval envelopes.

Add a non-secret `analysis.backend_identity = "coding-harness"` default to both example assets and update the asset-equivalence test. Config resolution must use the same backward-compatible default when existing files omit the field, and tests must cover omission plus rejection of an explicitly blank/invalid identifier. The skill treats a cached result as authoritative only when the CLI says `analysis_status: cached`; it never guesses from artifact presence.

- [ ] **Step 4: Run focused and full tests, then commit**

Run:

```sh
bundle exec ruby -Itest test/unit/analysis/bridge_cache_test.rb
bundle exec ruby -Itest test/system/bridge_cli_test.rb
bundle exec ruby -Itest test/system/repeated_run_test.rb
bundle exec rake test
git diff --check
```

Commit:

```sh
git add config/example.toml lib/cyborg/assets/config.example.toml lib/cyborg/analysis/bridge_cache.rb lib/cyborg/commands/analysis_packet.rb lib/cyborg/commands/record_result.rb test/unit/analysis/bridge_cache_test.rb test/system/bridge_cli_test.rb test/system/repeated_run_test.rb
git commit -m "feat: reuse validated bridge analysis"
```

---

### Task 5: Evolve the Skill Through the Bounded GREEN Ralph Loop

**Files:**
- Modify: `cyborg.gemspec`
- Modify: `skills/cyborg/SKILL.md`
- Modify: `skills/cyborg/references/bridge-protocol.md`
- Modify: `skills/cyborg/tests/bootstrap-ralph-results.md`
- Modify: `README.md`
- Create: `test/contract/skill_bootstrap_test.rb`
- Create: `test/system/gem_package_test.rb`
- Create: `test/system/one_prompt_bootstrap_test.rb`
- Modify: `docs/operations.md`

**Interfaces:**
- Consumes: frozen Task 1 prompt, `cyborg init` from Task 3, and bridge cache status from Task 4
- Produces: automatic skill bootstrap followed by the existing protected bridge sequence
- Produces: GREEN evidence for first run, identical rerun, clean-shell render, fail-closed invalid config, protected-data scan, and unchanged repository status

- [ ] **Step 1: Write the failing one-prompt system acceptance test**

The test spawns real executables with an empty isolated `HOME` and performs the deterministic shell portion of the skill:

```ruby
def test_init_run_rerun_and_clean_shell_render_use_persistent_defaults
  initialized = cli("init")
  assert_equal 0, initialized.status
  first = fixture_bridge_run
  second = fixture_bridge_run
  rendered = clean_shell_cli("render", "--format", "markdown")

  assert_equal 0, rendered.status
  assert_equal first.fetch("item_ids"), second.fetch("item_ids")
  assert_equal %w[required cached], [first.fetch("analysis_status"), second.fetch("analysis_status")]
  assert_equal 0, analysis_backend_task_call_count
  assert_equal config_bytes_after_first, File.binread(default_config_path)
  assert_empty ad_hoc_state_paths
end
```

Also assert repository `git status --short --ignored` and a binary diff before/after are identical, and scan bounded captures with `Cyborg::Redactor` plus credential/lease patterns. Add `skill_bootstrap_test.rb` to assert the documented sequence invokes idempotent init before `prepare`, branches on `analysis_status`, uses the CLI-provided cached result on a hit, and contains none of the forbidden temporary config/state workarounds. This textual contract complements—but does not replace—the external operator run.

- [ ] **Step 2: Run the acceptance test and verify RED**

Run:

```sh
bundle exec ruby -Itest test/contract/skill_bootstrap_test.rb
bundle exec ruby -Itest test/system/one_prompt_bootstrap_test.rb
```

Expected: the skill contract is RED because the skill/README still omit unconditional safe init and cache-status branching. The system flow may already pass after Tasks 2–4; it is retained here as the executable behavior half of the acceptance pair.

- [ ] **Step 3: Apply `superpowers:writing-skills` to the observed baseline**

Update the skill's required flow to begin:

```markdown
0. Resolve the default with `bin/cyborg config path` (or `cyborg` when installed), then run idempotent `bin/cyborg init` as the safe validation/bootstrap precondition on every invocation. Continue only when init returns one compact JSON object with status `initialized` or `ready`. Do not decide safety with `test -f`/`File.file?`, create config/state with shell commands, invent temporary config/state paths, or export `CYBORG_CONFIG` merely because the default is missing.
```

Document explicit-user `--config` precedence. After `analysis-packet`, branch only on its parsed `analysis_status`: execute the host task graph and write a result on `required`; pass the CLI-generated `analysis_result` path directly to `record-result` on `cached`, without opening or copying its payload. In the bridge reference, add the init result schema, exit codes, no-overwrite behavior, cache-status schema, and separation between persistent default state and disposable artifact roots. Update README setup so the one-prompt path needs no prior `mkdir`, `cp`, or `export`; retain manual `bin/cyborg init` as an observable troubleshooting command.

- [ ] **Step 4: Run Ralph GREEN iteration 1 with a fresh Luna/xhigh operator**

Use a new source snapshot, disposable home, and artifact root. Give the operator only the frozen prompt and the updated skill/reference. Require the sanitized environment and manifest/status controls from Task 1; it may not edit files or use prior iteration state. Record commands, exit statuses, created path names, first/second `analysis_status`, observed host-backend call count, config hash before/after rerun, clean-shell render status, protected-data scan, snapshot-manifest comparison, and repository comparison.

Append a complete `## GREEN iteration 1` record to `bootstrap-ralph-results.md`. If any check fails, name the single smallest gap and proceed to Step 5; otherwise skip to Step 6.

- [ ] **Step 5: Close one observed loophole per additional iteration**

For iterations 2 through 5:

1. Add one failing regression or pressure assertion reproducing the named gap.
2. Make the smallest CLI/skill/README correction.
3. Run the focused regression.
4. Dispatch a new Luna/xhigh operator with the identical frozen prompt and a new empty home.
5. Append exact bounded results and acceptance scoring.

Stop immediately on full GREEN. If iteration 5 is not fully GREEN, do not commit a claimed success; report the remaining blocker to the user.

- [ ] **Step 6: Verify the complete GREEN contract**

Run:

```sh
bundle exec ruby -Itest test/system/init_cli_test.rb
bundle exec ruby -Itest test/contract/skill_bootstrap_test.rb
bundle exec ruby -Itest test/system/one_prompt_bootstrap_test.rb
bundle exec ruby -Itest test/system/bridge_cli_test.rb
bundle exec rake test
ruby -w -Imotherbrain/test -e 'Dir["motherbrain/test/**/*_test.rb"].sort.each { |f| require_relative f }'
gem build cyborg.gemspec --output /private/tmp/cyborg-bootstrap-verification.gem
gem specification /private/tmp/cyborg-bootstrap-verification.gem files | rg "(db/migrations/.*\\.rb|lib/cyborg/assets/(config.example.toml|fixture-records.json))"
git diff --check
git status --short --ignored
```

The generated gem lives outside the repository and may be left for the operating system to clean up. Verify no Ralph home/artifact path is tracked and no protected material appears in `bootstrap-ralph-results.md`.

- [ ] **Step 7: Review durable memory**

Read `motherbrain/docs/PROTOCOL.md` and the active architecture ADR. If deterministic one-prompt initialization sharpens the approved provider-neutral boundary, update the existing active ADR and `docs/memory/INDEX.md` with verified paths/tests in the same change; do not create a session diary or duplicate ADR.

- [ ] **Step 8: Commit the GREEN operator contract**

```sh
git add cyborg.gemspec README.md docs/operations.md docs/superpowers/specs/2026-08-14-one-prompt-bootstrap-ralph-loop-design.md skills/cyborg test/contract/skill_bootstrap_test.rb test/system/gem_package_test.rb test/system/one_prompt_bootstrap_test.rb
# Only when Task 5 Step 7 changed durable memory, add the exact ADR and index paths named there.
git commit -m "feat: bootstrap cyborg from one harness prompt"
```

Run final independent whole-range review from the Task 1 baseline through HEAD, then execute the complete suite twice before any push or completion claim.
