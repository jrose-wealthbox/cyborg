# Task 2 Report: Packaged Safe Bootstrap Services

## Implementation

- Added immutable runtime config and fixture assets plus gem packaging.
- Added descriptor-anchored `Cyborg::Bootstrap::SafeFilesystem` installation and directory validation.
- Added the idempotent bootstrap initializer and result contract.
- Pre-created/validated SQLite databases privately, added the pre/post-open identity handshake, and preserved private WAL/SHM modes.
- Replaced normal CLI state `mkdir_p` behavior with the shared safe directory service.
- Added focused asset, filesystem, initializer, database, and CLI coverage.

## TDD evidence

The original implementer did not persist its promised report before stalling, so only observed evidence is recorded here; no unobserved RED output is invented.

Observed RED during recovery:

```text
bundle exec ruby -Itest test/unit/bootstrap/safe_filesystem_test.rb
3 runs, 10 assertions, 2 failures
- install expected "first" bytes but produced an empty file
- ensure_directory expected :created but returned :existing
```

After the original agent was resumed, the same focused suite was observed GREEN:

```text
3 runs, 14 assertions, 0 failures, 0 errors, 0 skips
```

The takeover added the remaining initializer/database/container work. Its intermediate RED transcript was not persisted before it stalled; this is a process-evidence concern, not a claim that those tests were observed RED by the controller.

## Final focused verification

```text
assets_test:          1 run,  2 assertions, 0 failures
safe_filesystem_test: 4 runs, 18 assertions, 0 failures
initializer_test:     8 runs, 35 assertions, 0 failures
database_test:       11 runs, 35 assertions, 0 failures
cli_test:             3 runs, 10 assertions, 0 failures
git diff --check: clean
```

## Packaging and full verification

```text
gem build cyborg.gemspec --output /private/tmp/cyborg-bootstrap-verification.gem
Successfully built cyborg 0.1.0

gem specification ... files
lib/cyborg/assets/config.example.toml
lib/cyborg/assets/fixture-records.json

bundle exec rake test
338 runs, 1454 assertions, 0 failures, 0 errors, 0 skips
```

No network or live credentials were used.

## Files

- `cyborg.gemspec`
- `lib/cyborg.rb`
- `lib/cyborg/cli.rb`
- `lib/cyborg/database.rb`
- `lib/cyborg/assets/config.example.toml`
- `lib/cyborg/assets/fixture-records.json`
- `lib/cyborg/bootstrap/assets.rb`
- `lib/cyborg/bootstrap/safe_filesystem.rb`
- `lib/cyborg/bootstrap/initializer.rb`
- `test/unit/bootstrap/assets_test.rb`
- `test/unit/bootstrap/safe_filesystem_test.rb`
- `test/unit/bootstrap/initializer_test.rb`
- `test/integration/database_test.rb`
- `test/unit/cli_test.rb`

## Self-review and concerns

All focused and full tests pass, packaged assets are present, and the diff is whitespace-clean. The implementation must still pass an independent task-scoped spec/quality review. Process concern: two Luna/xhigh agents stalled without yielding or writing reports, so complete RED transcripts for initializer and database tests were lost; the preserved code and final behavior remain reviewable.

## Review fix round 1

RED regressions were added before implementation changes:

```text
bundle exec ruby -Itest test/unit/cli_test.rb
4 runs, 11 assertions, 1 failures, 0 errors, 0 skips
Failure: existing_group_readable_state_directory expected Cyborg::InvalidConfiguration, but nothing was raised.

bundle exec ruby -Itest test/unit/bootstrap/safe_filesystem_test.rb
5 runs, 19 assertions, 1 failures, 0 errors, 0 skips
Failure: install_surfaces_temp_cleanup_failure expected Cyborg::InvalidConfiguration, but nothing was raised.
```

GREEN after the fixes:

```text
bundle exec ruby -Itest test/unit/cli_test.rb
4 runs, 11 assertions, 0 failures, 0 errors, 0 skips

bundle exec ruby -Itest test/unit/bootstrap/safe_filesystem_test.rb
5 runs, 20 assertions, 0 failures, 0 errors, 0 skips
```

Task 2 focused tests and gem verification remained green (assets 1/2, safe filesystem 5/20, initializer 8/35, database 11/35, CLI 4/11; gem contained both packaged assets). The full suite was rerun once:

```text
bundle exec rake test
340 runs, 1388 assertions, 6 failures, 0 errors, 0 skips
```

The six failures are existing action/support CLI tests whose setup creates explicit state directories with `FileUtils.mkdir_p` (0755); strict `SafeFilesystem#ensure_directory(mode: 0700)` now correctly rejects those leaves. The review requirement and new regression require this fail-closed behavior, so changing it to make those legacy fixtures pass would weaken the mandated policy. `git diff --check` is clean.

## Review fix round 1 completion

The two legacy system-test fixtures were updated to create their explicit state
leaves with mode 0700; production policy remains strict and unchanged.

```text
bundle exec ruby -Itest test/system/action_cli_test.rb
4 runs, 55 assertions, 0 failures, 0 errors, 0 skips

bundle exec ruby -Itest test/system/support_cli_test.rb
5 runs, 36 assertions, 0 failures, 0 errors, 0 skips

bundle exec rake test
340 runs, 1457 assertions, 0 failures, 0 errors, 0 skips

git diff --check
clean
```

The full run emits one test-only Ruby warning from the Fiddle method override
used to inject `unlinkat` failure; it does not affect test results.
