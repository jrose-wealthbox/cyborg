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
