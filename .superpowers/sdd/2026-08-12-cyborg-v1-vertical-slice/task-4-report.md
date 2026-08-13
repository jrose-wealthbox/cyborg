# Task 4 report: Configuration, Paths, and Business Calendar

Date: 2026-08-13
Base commit: `a092051bbebbb55c65159f6c9791ff47aaf99c58`

## Implementation

- Added immutable `Cyborg::Config` loading from TOML with explicit path, `CYBORG_CONFIG`, and `~/.config/cyborg/config.toml` precedence.
- Added recursive secret-shaped-key rejection (`config.secret_forbidden`), unknown-section and enum validation, required repository-root checks, source limits, timeout consistency, and required reservation budget checks.
- Added typed immutable profile, source, budget, cache, and timeout values. The resolved non-secret configuration is canonicalized with `Bridge::CanonicalJSON` for a stable SHA-256 fingerprint.
- Added `Cyborg::Paths.resolve` with `CYBORG_STATE_DIR` and per-path environment overrides, configured paths, and the macOS default `~/Library/Application Support/CYBORG/` state layout.
- Added `Cyborg::BusinessCalendar` and immutable `TimeWindow` values. Windows use the configured TZInfo timezone, DST-safe local midnights, configurable weekends, US holiday profiles, observed fixed-date holidays, additions/removals, date overrides, and opt-in Easter/Good Friday handling.
- Added `config/example.toml` and deterministic configuration fixtures/tests. Calendar policy remains outside source adapters.

## TDD evidence

### RED

After adding the initial focused tests and before creating the Task 4 production files, the required command failed because the new configuration boundary was absent:

```text
$ bundle exec ruby -Itest test/unit/config_test.rb
LoadError: cannot load such file -- .../lib/cyborg/config
```

### GREEN

Focused tests:

```text
$ bundle exec ruby -Itest test/unit/config_test.rb
6 runs, 21 assertions, 0 failures, 0 errors, 0 skips

$ bundle exec ruby -Itest test/unit/paths_test.rb
2 runs, 7 assertions, 0 failures, 0 errors, 0 skips

$ bundle exec ruby -Itest test/unit/calendar_test.rb
4 runs, 8 assertions, 0 failures, 0 errors, 0 skips
```

Full CYBORG suite:

```text
$ bundle exec rake test
77 runs, 205 assertions, 0 failures, 0 errors, 0 skips
```

Motherbrain preservation suite:

```text
$ bundle exec ruby -I motherbrain/test -I motherbrain/lib \
    -e 'ARGV.each { |path| load path }' -- $(rg --files motherbrain/test -g '*_test.rb' | sort)
31 runs, 124 assertions, 0 failures, 0 errors, 0 skips
```

## Files

Created:

- `config/example.toml`
- `lib/cyborg/config.rb`
- `lib/cyborg/paths.rb`
- `lib/cyborg/calendar.rb`
- `test/unit/config_test.rb`
- `test/unit/paths_test.rb`
- `test/unit/calendar_test.rb`
- `test/fixtures/config/minimal.toml`
- `test/fixtures/config/invalid-secret.toml`
- `.superpowers/sdd/2026-08-12-cyborg-v1-vertical-slice/task-4-report.md`

Updated:

- `lib/cyborg.rb`
- `lib/cyborg/errors.rb`
- `test/test_helper.rb`

## Self-review

- Focused tests use temporary TOML paths and hand-derived UTC literals for normal, DST-transition, holiday, observed-date, override, and Easter cases.
- Config fingerprints exclude the source file path and secrets while including all resolved non-secret defaults and policy values; the returned hash and typed values are deeply frozen.
- State-directory overrides derive all default child paths from the overridden state root; explicit per-path environment values still win.
- Required repository roots are checked only when marked/treated as required, and disabled source discovery does not grant implicit access.
- `git diff --check` is clean.

## Concerns

- Easter is disabled by default in the profile fixture and enabled explicitly when desired; this follows the Task 4 “Easter opt-in” test requirement while keeping the policy configurable.
- This task defines configuration and calendar primitives only. Source retrieval, budget execution, and run orchestration consume these values in later tasks.

## Fix round 1/5

### Findings addressed

- Configuration fingerprints now include the complete non-secret TOML input plus every resolved/default policy value, including recognized `[llm]`, `[filters]`, `[database]`, `[tasks]`, and selected calendar profile values. Canonical JSON still sorts keys, and secret-shaped keys are rejected before resolution.
- Fingerprint strings are explicitly frozen and cannot be mutated by callers.
- Calendar profiles normalize and validate working-hour tables/intervals, requiring strict `HH:MM` ranges and ordered start/end values. Day-specific schedules are supported and must leave a possible working day.
- Profiles with all seven weekend days are rejected as `config.no_business_day`; the calendar also validates externally supplied profiles and caps business-day search at 3,660 days as a defensive bound.

### Fix-round RED evidence

After adding the regression tests and before the fix implementation:

```text
$ bundle exec ruby -Itest test/unit/config_test.rb
12 runs, 28 assertions, 4 failures, 0 errors, 0 skips
```

The failures were the expected omitted `[llm]` fingerprint input, mutable fingerprint, absent working-hours validation, and absent impossible-calendar validation.

### Fix-round GREEN evidence

Focused regression tests:

```text
$ bundle exec ruby -Itest test/unit/config_test.rb
12 runs, 38 assertions, 0 failures, 0 errors, 0 skips

$ bundle exec ruby -Itest test/unit/calendar_test.rb
5 runs, 10 assertions, 0 failures, 0 errors, 0 skips
```

Full CYBORG suite:

```text
$ bundle exec rake test
84 runs, 224 assertions, 0 failures, 0 errors, 0 skips
```

Motherbrain preservation suite:

```text
$ bundle exec ruby -I motherbrain/test -I motherbrain/lib \
    -e 'ARGV.each { |path| load path }' -- $(rg --files motherbrain/test -g '*_test.rb' | sort)
31 runs, 124 assertions, 0 failures, 0 errors, 0 skips
```

### Fix-round files

- Updated `lib/cyborg/config.rb` and `lib/cyborg/calendar.rb`.
- Updated `test/unit/config_test.rb` and `test/unit/calendar_test.rb`.
- `git diff --check` and Ruby syntax checks are clean.

## Fix round 2/5

### Findings addressed

- Profiles with day-specific working hours now require at least one valid interval on a non-weekend weekday; weekend-only schedules fail with `config.no_business_day`.
- Added the shared `Cyborg::Weekday` normalizer for numeric, full-name, and abbreviated weekday values. Config and externally supplied calendar profiles now use the same deterministic validation, including rejection of malformed values.
- `BusinessCalendar#business_day?` and window search now require a configured interval for the date's weekday, while retaining the global `start`/`end` working-hours form.

### Fix-round RED evidence

After adding the regression tests and before the production changes:

```text
$ bundle exec ruby -Itest test/unit/config_test.rb
15 runs, 42 assertions, 1 failures, 0 errors, 0 skips

$ bundle exec ruby -Itest test/unit/calendar_test.rb
8 runs, 13 assertions, 3 failures, 0 errors, 0 skips
```

The failures were the expected weekend-only profile acceptance, named/invalid external weekend handling, and closed weekday being treated as a business day.

### Fix-round GREEN evidence

Focused regression tests:

```text
$ bundle exec ruby -Itest test/unit/config_test.rb
15 runs, 43 assertions, 0 failures, 0 errors, 0 skips

$ bundle exec ruby -Itest test/unit/calendar_test.rb
8 runs, 17 assertions, 0 failures, 0 errors, 0 skips
```

Full CYBORG suite:

```text
$ bundle exec rake test
90 runs, 236 assertions, 0 failures, 0 errors, 0 skips
```

Motherbrain preservation suite:

```text
$ bundle exec ruby -I motherbrain/test -I motherbrain/lib \
    -e 'ARGV.each { |path| load path }' -- $(rg --files motherbrain/test -g '*_test.rb' | sort)
31 runs, 124 assertions, 0 failures, 0 errors, 0 skips
```

### Fix-round commands and files

- `ruby -c lib/cyborg/weekday.rb`, `ruby -c lib/cyborg/config.rb`, and `ruby -c lib/cyborg/calendar.rb` all report `Syntax OK`.
- `git diff --check` is clean.
- Added `lib/cyborg/weekday.rb`.
- Updated `lib/cyborg/config.rb`, `lib/cyborg/calendar.rb`, `test/unit/config_test.rb`, and `test/unit/calendar_test.rb`.
