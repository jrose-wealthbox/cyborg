# Task 5 report: run lifecycle, lease ownership, and abandonment

Completed 2026-08-13T05:27:58Z.

## RED

Added `test/integration/run_lease_test.rb` and
`test/integration/run_lifecycle_test.rb`, then ran:

```text
bundle exec ruby -Itest test/integration/run_lease_test.rb
```

The tests failed before assertions with `NameError: uninitialized constant
Cyborg::Runs`, proving the requested services were absent.

## GREEN

Implemented `lib/cyborg/runs/lease_manager.rb` and
`lib/cyborg/runs/lifecycle.rb`, loaded from `lib/cyborg.rb`.

- Persisted singleton lease acquisition uses an immediate transaction and a
  short OS lock; competing SQLite connections allow one owner.
- Lease tokens are 32 random bytes in mode `0600` files; only SHA-256
  fingerprints are stored in SQLite.
- Verification, renewal, release, expiry reclamation, and protected token-file
  deletion are implemented. Expiry fails the old run with
  `run.lease_expired` before a new lease can be acquired.
- Lifecycle start persists the running run and lease. Abandonment records
  `run.abandoned`, marks the run failed, releases the lease, removes the token
  file, and does not publish or activate cursors.
- Abandonment verifies and mutates under one lease-held OS lock to avoid a
  verify-then-reacquire race.

Focused tests:

```text
bundle exec ruby -Itest test/integration/run_lease_test.rb && \
bundle exec ruby -Itest test/integration/run_lifecycle_test.rb
11 runs, 56 assertions, 0 failures, 0 errors
```

Full CYBORG suite:

```text
bundle exec rake test
101 runs, 292 assertions, 0 failures, 0 errors
```

Motherbrain suite:

```text
ruby -w -Imotherbrain/test -e 'Dir["motherbrain/test/**/*_test.rb"].sort.each { |file| require_relative file }'
31 runs, 124 assertions, 0 failures, 0 errors
```

## Commit

Commit: `90da2a5` (`feat: protect briefing runs with leases`)

## Concerns

The existing `run_leases` schema has no lease-file path or dedicated run error
code column. Lease paths are therefore held by the owning process and stable
failure codes are retained in `runs.usage_summary_json`, preserving the
existing schema boundary and avoiding plaintext tokens in durable state.

## Fix round 1 (2026-08-13T05:36:09Z)

### RED

Added two regression tests to `test/integration/run_lease_test.rb`:

- `test_existing_lease_file_rolls_back_db_row_without_deadlocking` created a
  stale `0600` lease file and bounded acquisition with `Timeout.timeout(2)`.
  Before the fix it timed out while rescue attempted to reacquire the already
  held OS flock; the inserted `run_leases` row could not be cleaned up.
- `test_fresh_manager_reclaims_expired_lease_file_and_reacquires_same_path`
  acquired with manager A, advanced the clock, then acquired from a fresh
  manager using the same DB, lock, and lease path. Before the fix it failed on
  the stale token file after marking the old run expired.

### GREEN

Rollback now deletes the matching lease row in a direct immediate transaction
under the current OS lock, with no nested flock. Expiry cleanup accepts the
deterministically supplied lease path and safely removes only a regular `0600`
file before inserting the replacement lease. The old run is still marked
`failed` with `run.lease_expired`, and the replacement token is newly generated.

Focused lease tests:

```text
bundle exec ruby -Itest test/integration/run_lease_test.rb
9 runs, 40 assertions, 0 failures, 0 errors
```

Fix commit: this report is included in the commit titled
`fix: recover expired lease files safely`.

## Fix round 2 (2026-08-13T05:41:58Z)

### RED

Added fresh-manager regressions for the public expiry API:

- `test_public_expiry_reclaims_file_from_fresh_manager_when_path_is_explicit`
  called `LeaseManager#fail_expired_lease!(lease_file: path)`, asserted the
  old run failed, the lease row and stale token file were removed, and then
  reacquired the same path.
- `test_public_expiry_forwards_explicit_lease_path` exercised the corresponding
  `RunLifecycle` caller.

Before the fix, the first test failed with `ArgumentError` because the public
method accepted no lease path; a fresh manager therefore had no safe way to
remove the old token file.

### GREEN

`LeaseManager#fail_expired_lease!` now accepts an optional explicit
`lease_file:` and passes only that validated path into expiry cleanup.
`RunLifecycle#fail_expired_lease!` defaults to and forwards its configured
lease path. Cleanup remains constrained to regular mode-`0600` files and never
infers or deletes a broad filesystem path.

Focused tests:

```text
bundle exec ruby -Itest test/integration/run_lease_test.rb && \
bundle exec ruby -Itest test/integration/run_lifecycle_test.rb
15 runs, 78 assertions, 0 failures, 0 errors
```
