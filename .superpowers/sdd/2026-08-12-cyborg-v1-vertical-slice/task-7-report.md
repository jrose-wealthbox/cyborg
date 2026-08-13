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
