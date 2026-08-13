# Task 7 report: Direct GitHub Adapter

Completed 2026-08-13. Task 7 was finalized from the existing uncommitted
adapter state; `.serena/` was preserved and is not part of this task.

## Implementation

- Added `ProcessRunner#capture(argv:, timeout:, max_bytes:, env:)` with direct
  argv execution, no shell interpolation, wall-clock termination, combined
  stdout/stderr byte bounds, and a structured `ProcessResult`.
- Added read-only `GithubAdapter#health_check(context)` and `#fetch(context)`
  using bounded `gh auth status` and paginated GET-only `gh api` calls.
- Added stable failure codes: `github.binary_missing`,
  `github.unauthenticated`, `github.api_unavailable`, and
  `github.invalid_response`; raw command output is not persisted.
- Added `GithubNormalizer` for CI-only filtering, actionable notification
  reasons, repository/organization allowlists, bounded source text, trusted
  configured-host links, reply timestamps, and stable targets composed from
  hostname plus repository and issue/PR node IDs.
- Added fixture-backed contract/unit coverage for read-only calls, pagination,
  cursor holding, limits, failure modes, allowlists, review requests,
  comments/replies, mentions, assignments, trusted links, and process bounds.

## RED evidence

The available initial recovery evidence recorded two failures in the retained
Task 7 state:

- the review-and-CI notification was not retained alongside its CI reason;
- the summary fixture did not match the expected normalized summary.

Recovery added/fixed the fixture-backed assertions and normalization behavior,
then expanded the contract coverage. During this final audit, the new tests
also produced the following intentional RED results before the corresponding
production fixes:

```text
github_adapter_test: record-limit test expected prior cursor page:1, got nil
github_normalizer_test: 3 failures covering PR target identity for mentions/comments
  and accidental inclusion of an unrelated notification reason
```

These failures were corrected by preserving the prior cursor in the test case,
recognizing pull-request subject URLs as PR targets, including metadata for
comment/review notifications, deriving reply timestamps from actionable reason
arrays, and restricting inclusion to known actionable reasons. The focused
tests then passed.

## Verification

```text
bundle exec ruby -Itest test/contract/sources/github_adapter_test.rb && \
  bundle exec ruby -Itest test/unit/sources/github_normalizer_test.rb && \
  bundle exec ruby -Itest test/unit/process_runner_test.rb
12 runs, 31 assertions, 0 failures, 0 errors, 0 skips
9 runs, 38 assertions, 0 failures, 0 errors, 0 skips
3 runs, 11 assertions, 0 failures, 0 errors, 0 skips

bundle exec rake test
159 runs, 545 assertions, 0 failures, 0 errors, 0 skips

ruby -w -Imotherbrain/test -Imotherbrain/lib \
  -e 'Dir["motherbrain/test/**/*_test.rb"].sort.each { |file| require_relative file }'
31 runs, 124 assertions, 0 failures, 0 errors, 0 skips
```

Ruby syntax checks and `git diff --check` are clean. No real `gh` executable
or network request is used by the tests.

## Files

Created:

- `lib/cyborg/process_runner.rb`
- `lib/cyborg/sources/github_adapter.rb`
- `lib/cyborg/sources/github_normalizer.rb`
- `test/contract/sources/github_adapter_test.rb`
- `test/unit/process_runner_test.rb`
- `test/unit/sources/github_normalizer_test.rb`
- `test/fixtures/github/authenticated.json`
- `test/fixtures/github/notifications-page-1.json`
- `test/fixtures/github/notifications-page-2.json`
- `test/fixtures/github/pull-request.json`
- `test/fixtures/github/malformed.json`

## Concerns

- GitHub authentication remains delegated to the user’s existing `gh`
  configuration; no token discovery or storage is implemented.
- The adapter treats a page/record bound reached before proving completion as a
  degraded result and holds the incoming cursor for safe retry.
- `.serena/` remains unrelated untracked workspace state and was intentionally
  not staged.

## Fix round 1: review findings

### RED

Added regression tests for issue mentions/assignments, missing issue node IDs,
configured/context allowlist narrowing, metadata-call suppression, and hard
registration ceilings. Before the fixes, the focused adapter suite reported:

```text
15 runs, 34 assertions, 2 failures, 1 error
```

The failures showed issue notifications did not fetch `/issues/:number`
metadata (leaving a nil stable target), context filters could broaden a
configured allowlist and trigger metadata retrieval for excluded repositories,
and the adapter had no `limits:` registration ceiling.

### GREEN

- Issue and pull-request metadata is fetched only after notification and
  repository/org allowlist checks; issue and assignment records now use the
  repository node ID plus issue node ID for stable targets.
- Missing node IDs produce `github.invalid_response` with no partial records or
  invented identity.
- Context repository/org filters intersect configured allowlists; an empty
  intersection matches nothing and cannot broaden access.
- Registration `max_pages` and `max_records` are hard ceilings over context
  values, and bound-reached retrievals hold the prior cursor as degraded.

Focused fix-round verification:

```text
bundle exec ruby -Itest test/contract/sources/github_adapter_test.rb && \
  bundle exec ruby -Itest test/unit/sources/github_normalizer_test.rb && \
  bundle exec ruby -Itest test/unit/process_runner_test.rb
17 runs, 48 assertions, 0 failures, 0 errors, 0 skips
10 runs, 39 assertions, 0 failures, 0 errors, 0 skips
3 runs, 11 assertions, 0 failures, 0 errors, 0 skips
```

## Fix round 3: node-ID type and whitespace validation

### RED

Added direct-normalizer and adapter regressions for whitespace repository and
issue node IDs, including cursor preservation. Before the fix:

```text
github_adapter_test: 19 runs, 53 assertions, 1 failure
github_normalizer_test: 13 runs, 44 assertions, 1 failure
```

The adapter returned healthy data for a whitespace repository node ID, and the
normalizer emitted a target such as `github.example:  :issue-node`.

### GREEN

- Node IDs are accepted only when they are actual `String` values whose
  `strip` is nonempty; original values are never silently rewritten.
- `GithubNormalizer` rejects actionable records with invalid repository or
  issue/PR node IDs before constructing a `NormalizedRecord`.
- `GithubAdapter` treats the explicit invalid normalization result as a
  bounded degraded retrieval, excludes the unsafe record, and holds the prior
  cursor with `github.invalid_response`.

Fix-round focused verification:

```text
bundle exec ruby -Itest test/contract/sources/github_adapter_test.rb && \
  bundle exec ruby -Itest test/unit/sources/github_normalizer_test.rb && \
  bundle exec ruby -Itest test/unit/process_runner_test.rb
19 runs, 57 assertions, 0 failures, 0 errors, 0 skips
13 runs, 45 assertions, 0 failures, 0 errors, 0 skips
3 runs, 11 assertions, 0 failures, 0 errors, 0 skips
```

## Fix round 2: stable identity and malformed subjects

### RED

Added regressions for numeric REST IDs, missing/hostile subject URLs, and
adapter degradation. The focused suites initially showed:

```text
github_adapter_test: 18 runs, 49 assertions, 1 failure
github_normalizer_test: 12 runs, 41 assertions, 2 failures
```

The failures demonstrated that `metadata["id"]` was used as a stable target,
hostile or missing subject URLs could still produce healthy records, and a
missing identity was not consistently surfaced at the adapter boundary.

### GREEN

- Stable targets now require nonblank repository and issue/PR node IDs; numeric
  REST IDs are never used as identity.
- Included actionable notifications require a valid HTTPS subject URL on the
  configured host or its API host, with a valid issue/PR number.
- Invalid identity is excluded by the normalizer and causes the adapter to
  return a degraded result with `github.invalid_response`, no unsafe record,
  and the incoming cursor held.
- Existing trusted-link tests now distinguish a valid subject URL from an
  untrusted display/deep link.

Fix-round focused verification:

```text
bundle exec ruby -Itest test/contract/sources/github_adapter_test.rb && \
  bundle exec ruby -Itest test/unit/sources/github_normalizer_test.rb && \
  bundle exec ruby -Itest test/unit/process_runner_test.rb
18 runs, 52 assertions, 0 failures, 0 errors, 0 skips
12 runs, 43 assertions, 0 failures, 0 errors, 0 skips
3 runs, 11 assertions, 0 failures, 0 errors, 0 skips
```
