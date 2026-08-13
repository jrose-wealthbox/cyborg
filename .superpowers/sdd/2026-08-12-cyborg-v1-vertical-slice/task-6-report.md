# Task 6 report: source contracts, snapshot ingestion, and source caching

Completed 2026-08-13T12:21:26Z. Recovered from the uncommitted Task 6 state at
base commit `5e3ec76`.

## Original RED evidence

The existing Task 6 implementation was present but did not satisfy its focused
contracts. The initial verification showed:

```text
bundle exec ruby -Itest test/integration/source_ingestor_test.rb
4 runs, 11 assertions, 1 failure, 1 error
```

The fresh snapshot reported `hold` instead of `advance`, while the failed and
cached loop attempted two snapshots for the same run/source/account and hit
the schema's deliberate unique constraint. The cache suite showed:

```text
bundle exec ruby -Itest test/integration/cache_policy_test.rb
3 runs, 7 assertions, 0 failures, 1 error
```

`CachePolicy#expires_at` attempted `Integer#iso8601`. The full suite reported
`120 runs, 374 assertions, 1 failure, 2 errors`, plus repeated
`Data#new` redefinition warnings from `sources/contracts.rb`.

## Recovery RED/GREEN evidence

### Snapshot disposition and one-snapshot invariant

The disposition predicate itself evaluated to `advance`. Tracing the call
showed that `SourceIngestor` passed explicit snapshot attributes plus a
separate `cursor_disposition` keyword, and `SourceRepository` ignored that
keyword on the explicit-attributes path. The original brief's `result:` path
preserves the disposition. The failed/cached test, rather than the ingestor,
violated the one-snapshot-per-run contract by reusing one run; it now creates a
distinct run for each mode.

After isolating runs, the focused suite remained RED with only the fresh
`advance` failure. After switching the ingestor to the transactional
`create_snapshot(run:, registration:, result:, cursor_disposition:)` path, the
next RED exposed a second boundary mismatch: `SourceRepository` used
`Hash#dig` on the immutable `RetrievalError` Data value. A regression assertion
for persisted error provenance was added, and extraction now uses the value's
accessors.

The final focused result is:

```text
bundle exec ruby -Itest test/integration/source_ingestor_test.rb
4 runs, 21 assertions, 0 failures, 0 errors
```

### Cache policy and contract warnings

The TTL expression bound `.then` to the integer TTL before addition. It now
parenthesizes the timestamp addition before formatting the result.

The value-contract constructor now prepends a constructor module to each
`Data.define` class, preserving keyword defaults, validation, and deep
immutability without redefining `Data#new`. A subprocess regression under
`ruby -w` verifies that loading contracts emits no stderr.

### Host request bounds

A regression showed that an empty context filter hash discarded configured
registration filters. Host requests now merge registration filters with
context filters, with context values taking precedence, while retaining
allowlisted operations and the tighter of registration/context bounds.

## Implemented scope

- Immutable retrieval, request, response, normalized-record, evidence,
  health, error, and registration contracts with status/cache validation.
- Explicit source registry metadata and enabled-source filtering.
- Bounded fixture retrieval and normalization with deterministic fingerprints.
- Host request construction with operation allowlists, filters, cursors, and
  bounded pages/records/bytes.
- Transactional source snapshot, record/version/evidence persistence,
  rollback, exact deduplication, timestamp fallback, and cursor disposition.
- Snapshot-independent deterministic cache keys and ordinary/expensive TTL
  policy with invalidation metadata.
- Self-contained source error dependencies and regression coverage for the
  recovered defects.

## Verification

Focused Task 6 command:

```text
bundle exec ruby -Itest test/unit/sources/contracts_test.rb && \
  bundle exec ruby -Itest test/integration/source_ingestor_test.rb && \
  bundle exec ruby -Itest test/integration/cache_policy_test.rb
4 runs/29 assertions; 4 runs/21 assertions; 3 runs/9 assertions;
0 failures, 0 errors
```

Additional source suites:

```text
fixture adapter: 3 runs, 10 assertions, 0 failures, 0 errors
host request builder: 2 runs, 8 assertions, 0 failures, 0 errors
```

Full CYBORG suite:

```text
bundle exec rake test
121 runs, 391 assertions, 0 failures, 0 errors, 0 skips
```

Motherbrain preservation suite:

```text
ruby -w -Imotherbrain/test -e 'Dir["motherbrain/test/**/*_test.rb"].sort.each { |file| require_relative file }'
31 runs, 124 assertions, 0 failures, 0 errors, 0 skips
```

The redirected full CYBORG run produced `0` stderr bytes; `git diff --check`
and Ruby syntax checks are clean.

## Commit

`feat: add source ingestion and caching contracts` (the final commit is
reported by the handoff alongside this report).

## Concerns

The database intentionally permits one source snapshot per source/account per
run. Retrying an already committed snapshot for the same run remains a
database uniqueness violation; callers should retry before commit or start a
new run. Record/version ingestion itself is idempotent for exact normalized
duplicates, and all snapshot/record/evidence writes remain transactionally
rolled back together.

## Fix round 1/5: cross-contract hardening

Completed 2026-08-13T12:50:00Z from commit `1b85725`.

### RED

Added adversarial tests before the production changes. The focused runs showed
the expected gaps:

```text
contracts: 7 runs, 45 assertions, 3 failures
ingestor: 7 runs, 27 assertions, 2 failures
cache policy: 5 runs, 5 assertions, 2 errors
```

The failures covered contradictory retrieval status/cache combinations,
invalid retrieval limits, unchecked SourceHealth statuses, blank cursors that
advanced, source fields leaking into versions/evidence, and the old
single-key cache invalidation API.

### GREEN

RetrievalResult now enforces the approved truth table:

| status | data status | cache reason | error | cursor |
| --- | --- | --- | --- | --- |
| healthy | fresh | none | none | eligible to advance when non-empty |
| healthy | cached | policy_hit | none | hold |
| degraded | fresh (partial) | none | required | hold |
| degraded | cached | failure_fallback | required | hold |
| failed | none | none | required | hold |

Other combinations are rejected. The ingestor advances only a healthy,
complete fresh result with a non-empty string cursor; partial, cached, failed,
and blank-cursor results hold.

RetrievalContext validates all configured limits as integers, rejects negative
values, and requires positive values for pages, records, bytes, and seconds.
SourceHealth accepts only healthy/degraded/failed/disabled; non-healthy values
require an error code, healthy values cannot carry one, and checked timestamps
are canonicalized.

CachePolicy now requires a class selection and supports `ordinary`,
`expensive`, explicit class sets, and `full`. CacheRepository filters real
entries by class while retaining invalidation audit metadata. Ordinary
invalidation leaves expensive entries valid; full invalidation marks both.

Registration.allowed_fields is enforced at the ingestion boundary. Core
identity/timestamp/fingerprint fields remain contract-owned, while source
content and nested structured fields are whitelisted and optional evidence
excerpt/field-path content is removed unless explicitly allowed. Forbidden
source keys do not appear in record versions or evidence.

Focused GREEN runs:

```text
bundle exec ruby -Itest test/unit/sources/contracts_test.rb
7 runs, 55 assertions, 0 failures, 0 errors

bundle exec ruby -Itest test/integration/source_ingestor_test.rb
7 runs, 34 assertions, 0 failures, 0 errors

bundle exec ruby -Itest test/integration/cache_policy_test.rb
5 runs, 16 assertions, 0 failures, 0 errors
```

Full CYBORG:

```text
bundle exec rake test
129 runs, 437 assertions, 0 failures, 0 errors, 0 skips
```

Motherbrain:

```text
ruby -w -Imotherbrain/test -e 'Dir["motherbrain/test/**/*_test.rb"].sort.each { |file| require_relative file }'
31 runs, 124 assertions, 0 failures, 0 errors, 0 skips
```

The redirected full CYBORG run produced `0` stderr bytes. The truth-table
choice is deliberate: the architecture explicitly permits degraded fresh
partial data, but it must carry an error and never advance the cursor.
