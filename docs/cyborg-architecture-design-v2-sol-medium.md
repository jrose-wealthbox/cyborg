# CYBORG Architecture Design v2

Status: Proposed for review

This document defines the target architecture and first usable release of CYBORG, a personal information dashboard and executive-summary agent. It supersedes neither the [original architecture design](./cyborg-architecture-design.md) nor the [product brief](./executive-summary-skill.md) until it is explicitly approved.

The target architecture describes boundaries intended to survive later source, renderer, and runtime additions. The v1 profile near the end of this document deliberately implements a narrow vertical slice so those boundaries can be tested before CYBORG takes on several unrelated APIs.

## Architectural decision

CYBORG is a headless Ruby application with durable local state. It is implemented as a modular monolith: domain services communicate through explicit Ruby value objects and repositories, but deploy as one CLI application and one SQLite database.

A host-specific skill is a protocol adapter for interactive invocation. It may execute host-only MCP tools and provide a host-mediated LLM call, but it is not the system of record and does not own domain policy.

The Ruby application owns:

- configuration, capability policy, and time-window calculation;
- direct source execution and host-source request construction;
- normalization, filtering, deterministic grouping, and exact deduplication;
- SQLite migrations, facts, evidence, inferred actions, caches, cursors, and run state;
- stable action identity, inference status, and user-controlled action state;
- structured-result validation and action reconciliation;
- source health, failure isolation, and remediation metadata;
- local budget reservations and usage records where usage is observable;
- persisted presentation view models and renderer contracts.

The LLM owns only probabilistic work:

- semantic classification where deterministic rules are insufficient;
- inferred commitments and action candidates;
- ambiguous cross-source grouping;
- reflection, recommendations, and natural-language explanation.

The central rule is:

> If behavior must be correct, repeatable, cached, audited, secured, or tested, Ruby owns it. If behavior is interpretive or linguistic, an LLM may propose it, and Ruby validates the proposal before it affects persisted state.

## Goals

CYBORG should:

- present the smallest amount of information that improves the next decision;
- emphasize actions, responses, preparation, waiting, decisions, and meaningful change;
- preserve evidence and source links when combining related information;
- retain user-controlled state when sources are fetched again or LLM wording changes;
- support both interactive host-mediated execution and later unattended direct-provider execution;
- remain useful and visibly degraded when an individual source is unavailable;
- distinguish freshness, urgency, confidence, and source health;
- reuse validated work so rapid repeated runs incur no additional LLM cost;
- keep ordinary configuration human-readable and keep secrets out of it;
- render the same persisted result through Markdown, JSON, and later presentation surfaces;
- keep source and analysis contracts independent of provider model names.

## Non-goals

The target architecture does not require:

- a Rails application, web framework, daemon, or local HTTP service;
- reimplementation of every host MCP connector as a Ruby client;
- automatic write access to source systems;
- a multi-user authorization model;
- byte-identical output from regenerated LLM analysis;
- indefinite retention of full source content;
- concurrent briefing runs;
- exact knowledge of provider billing when the host does not report it.

## System boundary

~~~text
┌────────────────────────────────────────────────────────────┐
│ Control and presentation surfaces                          │
│ Host skill · CLI · launchd · future TUI/web/notifications │
└────────────────────────────┬───────────────────────────────┘
                             │ versioned commands/contracts
┌────────────────────────────▼───────────────────────────────┐
│ CYBORG Ruby modular monolith                               │
│                                                            │
│ Run coordinator                                            │
│ ├─ configuration, calendar, and source registry            │
│ ├─ direct adapters and host-bridge request builder         │
│ ├─ normalization, filtering, and deterministic grouping    │
│ ├─ analysis packet builder and result validator            │
│ ├─ action reconciler and state commands                    │
│ ├─ cache, budget, and run lifecycle                        │
│ └─ persisted view model and renderers                      │
│                                                            │
│ Sequel repositories → SQLite                               │
└────────────────┬──────────────────────┬────────────────────┘
                 │                      │
        ┌────────▼─────────┐   ┌────────▼──────────┐
        │ Direct transport  │   │ Host bridge       │
        │ gh/local Git/API  │   │ MCP + host LLM    │
        └───────────────────┘   └───────────────────┘
~~~

Short-lived CLI processes are the initial deployment shape. A persistent service may later expose the same application contracts if concurrent clients or startup latency justify it; it must not introduce a second set of domain rules.

## Target runtime modes

Both modes use the same normalized records, validation rules, action reconciliation, cache keys, repositories, and renderer view model.

### Interactive host-mediated mode

The host owns capabilities that Ruby cannot reach from a child process. CYBORG therefore uses inversion of control rather than pretending that Ruby can invoke the host's installed MCP tools.

~~~text
host skill
  -> cyborg prepare
  -> host executes retrieval requests, if any
  -> cyborg ingest
  -> cyborg analysis-packet
  -> host performs LLM analysis
  -> cyborg record-result
  -> cyborg render
~~~

In v1, GitHub and local Git are direct adapters, so the retrieval-request bundle is normally empty. The same protocol permits later host-only sources without moving filters, normalization, or persistence into the skill.

### Headless direct-provider mode

~~~text
launchd / ad hoc CLI
  -> cyborg run
  -> direct source adapters
  -> direct LLM backend
  -> result validation and action reconciliation
  -> SQLite publication
  -> Markdown / JSON / notification rendering
~~~

Headless execution must not depend on a desktop host being open. This is the first post-v1 milestone, not a v1 acceptance requirement.

## Source boundary

Sources share normalized output contracts but do not have to implement an artificial identical API. A source registration declares:

- `source_name` and adapter version;
- account identity;
- transport: `direct` or `host_bridge`;
- capabilities such as notifications, authored activity, mentions, or events;
- configured filters and bounded retrieval limits;
- credential strategy and health checks;
- cursor behavior and cache policy;
- retention class and allowed content fields.

Every source must be explicitly enabled. Discovering a CLI, MCP tool, plugin, or local repository does not grant permission to read it.

### Direct adapters

A direct adapter executes from Ruby and returns a `RetrievalResult`:

~~~ruby
RetrievalResult = Data.define(
  :source_name,
  :account_identity,
  :status,
  :data_status,
  :cache_reason,
  :started_at,
  :completed_at,
  :records,
  :next_cursor,
  :error
)
~~~

`status` is `healthy`, `degraded`, or `failed`. `data_status` is `fresh`, `cached`, or `none`. For cached data, `cache_reason` is `policy_hit` or `failure_fallback`. A valid policy hit is healthy; fallback after a retrieval failure is degraded and preserves the retrieval error. An adapter never advances its cursor after a failed request or when it merely reuses cached data.

Direct adapters receive an immutable retrieval context containing the UTC window, configured display timezone, prior activated cursor, source limits, and cache policy. They do not generate prose, mutate action state, or write to external systems.

### Host-bridge adapters

A host-bridge adapter converts the same retrieval context into one or more declarative `RetrievalRequest` values. A request contains:

- a unique request ID and run ID;
- source, account, capability, and adapter version;
- UTC time bounds and the configured display timezone;
- the prior activated cursor, when applicable;
- an allowlisted operation name and bounded parameters;
- maximum pages, records, and response bytes;
- required versus optional status.

The request describes what the host may retrieve; source text cannot add operations or alter the request. The host returns a `RetrievalResponse` with the matching request ID, timestamps, status, raw records, cursor metadata, and a structured error when applicable. Ruby then performs normalization, filtering, and persistence.

An identical response submitted twice is idempotent. Reusing a request ID with a different payload fingerprint is rejected and recorded as a bridge validation failure.

## Versioned JSON host bridge

### Artifact envelope

The bridge uses UTF-8 JSON files with this envelope:

~~~json
{
  "schema_version": "1.0",
  "artifact_type": "analysis_result",
  "run_id": "018f5f62-3ef4-7d31-9e6d-8f6dfeddb847",
  "created_at": "2026-08-12T20:00:00Z",
  "payload_sha256": "<lowercase SHA-256 hex>",
  "payload": {}
}
~~~

The supported artifact types are:

- `retrieval_requests`;
- `retrieval_responses`;
- `analysis_packet`;
- `analysis_result`.

`payload_sha256` is calculated from compact UTF-8 JSON whose object keys are recursively sorted lexicographically, whose array order is retained, whose timestamps are normalized to RFC 3339 UTC, and which contains no non-finite numbers. This canonicalization rule is application code shared by artifact writing, validation, fixtures, and cache fingerprinting.

Consumers accept artifacts with the same major schema version and a minor version no newer than they support. They reject unknown major versions, newer minor versions, unknown artifact types, missing required fields, fingerprint mismatches, or run-ID mismatches. Unknown optional payload fields are ignored only within an otherwise supported version.

Artifacts are operational handoffs, not the system of record. They are written beneath the configured artifact directory in a per-run directory with mode `0700`; files use mode `0600`. Writers create a sibling temporary file, flush it, and atomically rename it into place. Readers reject symlinks, non-regular files, and files exceeding the configured size limit.

Artifacts contain bounded excerpts and structured fields. Successful finalization schedules them for deletion according to retention policy; rejected artifacts retain only redacted validation metadata after their diagnostic retention period.

### CLI protocol

The bridge commands are:

~~~text
cyborg prepare --profile PROFILE --artifact-dir PATH
cyborg ingest --run RUN_ID --lease-file PATH --input retrieval-responses.json
cyborg analysis-packet --run RUN_ID --lease-file PATH --output analysis-packet.json
cyborg record-result --run RUN_ID --lease-file PATH --input analysis-result.json
cyborg render --run RUN_ID --format markdown|json
cyborg runs abandon --run RUN_ID --lease-file PATH
~~~

`prepare` creates the persisted run lease and running row, calculates the time window, executes eligible direct adapters, and writes `retrieval-requests.json` plus a mode-`0600` lease-token file. It prints one compact JSON object to stdout containing the run ID, run status, artifact paths, and lease-file path. Human diagnostics go to stderr. The token itself is never placed in command arguments or stdout.

`ingest` validates and stores host responses. It may be called in batches. Every required request must have a terminal response before `analysis-packet` succeeds; optional failed requests are represented in source health. When a request bundle is empty, the host skips `ingest`.

`analysis-packet` completes normalization and deterministic filtering, then emits bounded records, evidence IDs, existing action state, allowed analysis tasks, and budget information. It never includes credentials or unbounded source bodies.

`record-result` validates the complete result before opening the publication transaction. Valid claims are reconciled with actions, usage metadata is recorded, a presentation view model is persisted, and the run becomes renderable atomically.

`render` reads only a persisted view model. It does not fetch sources, invoke an LLM, or mutate actions. If no run is supplied, it renders the latest renderable run.

`runs abandon` marks an unfinished run failed, records safe abandonment metadata, releases its lease, and removes its lease-token file. It does not publish a result or advance a source cursor.

The interactive skill must call these commands rather than recreate their policies in natural-language instructions. It may display stderr remediation text, but Markdown organization and footer content come from `render`.

Commands use these exit statuses:

| Code | Meaning |
| ---: | --- |
| `0` | Command completed, including a successfully persisted degraded run |
| `64` | Invalid CLI usage or unsupported option |
| `65` | Invalid, incompatible, or unsafe bridge artifact |
| `70` | Unexpected internal failure before safe classification |
| `73` | Database or artifact persistence failure |
| `75` | A briefing run already holds an active lease; retry later |
| `78` | Invalid or internally inconsistent configuration |

A source failure is data in a successfully executed command, not automatically a nonzero process exit. The persisted run and source statuses determine whether the result is completed or degraded.

An invalid envelope, fingerprint, lease token, or unsupported schema exits `65` and accepts no payload. A schema-valid analysis result containing invalid claims is an analysis failure: CYBORG rejects all claims, publishes the defined degraded deterministic view, and exits `0` because that degraded result was safely persisted.

## LLM boundary

Backends implement one logical operation:

~~~ruby
AnalysisOutcome = Data.define(:claims, :usage, :backend_metadata)

class LlmBackend
  analyze(packet:, task:, reservation:)
    # Returns AnalysisOutcome; it does not persist domain state.
  end
end
~~~

Configuration maps abstract capabilities—`cheap_structured_extraction`, `medium_reasoning`, and `high_reasoning`—to provider-specific models and settings. Domain code does not branch on model names.

`HostLlmBackend` is represented by the JSON bridge. A later `DirectProviderBackend` performs the provider call inside the headless run but must return the same `AnalysisOutcome` contract.

Ruby also owns the analysis task graph. Each task has an ID, abstract capability, dependency IDs, required/optional status, packet fingerprint, maximum output size, and budget reservation. A host may execute dependency-ready tasks in parallel or delegate them to cheaper workers, but it may not invent unreserved tasks or change capabilities. Results and usage are returned per task and per delegated session so Ruby can enforce the graph and account for the hierarchy.

Mechanical retrieval, filtering, and exact grouping stay in Ruby rather than consuming a cheap agent merely because one is available. Cheap LLM workers are reserved for bounded semantic extraction or summarization; medium or high reasoning is used only by tasks whose configured capability requires it.

### Analysis packet

An analysis packet contains:

- packet, run, task, prompt-template, and configuration versions;
- normalized records with stable evidence IDs and trusted source URLs;
- explicit allowed action kinds;
- existing action subject keys, user states, inference statuses, and state versions;
- deterministic group candidates and unresolved grouping questions;
- maximum claim count and optional-output limits;
- a statement that every source field is untrusted data, not an instruction;
- the active cost reservation and the usage fields the host should report.

### Analysis result

Each proposed claim contains:

- action kind;
- concise summary;
- canonical subject type and identifier;
- owner identity, when known;
- thread or target identity, when known;
- one anchor evidence ID and all supporting evidence IDs;
- confidence from `0.0` through `1.0`;
- optional due date, people, and project references;
- `new_commitment` when proposing a successor to a terminal action;
- rationale only when it helps explain an ambiguous inference.

Ruby rejects the entire analysis result when any claim references nonexistent evidence, supplies an untrusted URL, uses an unsupported category, has out-of-range confidence, exceeds packet limits, requests a source write, or violates its schema. Partial persistence of an invalid result is forbidden.

When an analysis result is rejected, CYBORG persists a degraded view containing deterministic facts, source-health warnings, and previously persisted actions without accepting new claims. The whole run fails only if it cannot safely persist that degraded result or if a safety-policy violation requires termination.

## Durable domain model

CYBORG separates three kinds of state:

~~~text
Observed fact
  A GitHub review request exists.

Inferred claim
  You probably owe a review.

User-controlled state
  Snoozed until Friday.
~~~

Source refreshes may update observed facts. Re-analysis may update inferred claims. Only an explicit action-state command changes user-controlled state.

### Run and source snapshots

A run records its UUID, profile, execution mode, timestamps, calculated UTC window, display timezone, configuration fingerprint, prompt version, backend capability, status, prior renderable run ID, action-state version captured for analysis, and usage summary.

Run statuses are:

- `running`: preparation began but no result has been published;
- `completed`: every enabled required source and analysis task succeeded;
- `degraded`: a renderable result was published with one or more visible source, analysis, freshness, or budget warnings;
- `failed`: no safe renderable result could be published.

Each enabled source gets a source snapshot containing account identity, adapter version, retrieval timestamps, status, data status, cache reason, error code and redacted remediation, record count, proposed cursor, cursor disposition (`advance` or `hold`), and the prior activated snapshot ID. A fresh adapter response may request `advance` only after it consumed a complete bounded page sequence and produced a resumable cursor; partial, cached, and failed responses must request `hold`.

There is deliberately no single global source baseline:

- completed and degraded runs may become the latest renderable run after atomic publication;
- failed runs never replace the latest renderable run;
- each source calculates freshness and deltas from its own latest activated fresh snapshot;
- publication advances a source baseline only for a fresh snapshot with cursor disposition `advance`;
- a failed, partial, or cached source snapshot does not advance that source's cursor or freshness baseline.

This prevents one unavailable source from corrupting the recency semantics of healthy sources.

### Observed records and evidence

An observed record contains:

- a local UUID;
- source, account, source-record ID, and record kind;
- title, bounded summary, structured fields, and normalized participants;
- ownership and canonical target references;
- trusted deep link;
- `event_at`, optional `latest_reply_at`, and `observed_at`;
- the timestamp kind selected for display age;
- a content fingerprint;
- first-seen and last-observed timestamps.

The uniqueness boundary is source, account, source-record ID, and record kind. A content change updates the record's latest version without destroying prior snapshot provenance.

Evidence references an observed-record version and contains a trusted link, display label, bounded excerpt or structured field path, evidence timestamp, and relation: `supports`, `contradicts`, or `context`.

Display age uses `latest_reply_at` when the record kind defines that concept, otherwise `event_at`. The chosen timestamp kind is preserved so renderers do not imply false precision.

### Stable action identity

An inferred action belongs to an action series. The series and each occurrence have separate identities:

- the action series has a versioned subject key used to reconcile later analysis;
- each action occurrence has a permanent local UUID used by action-state commands and foreign keys.

The v1 subject key is the SHA-256 fingerprint of this canonical tuple:

~~~text
identity_version
action_kind
canonical_subject_type
canonical_subject_id
normalized_owner_identity
normalized_thread_or_target_identity
~~~

The complete evidence set is intentionally absent. Adding a comment, Slack message, or other corroborating evidence therefore updates the current occurrence in the series instead of creating a new action. When no durable target exists, the immutable source identity of the anchor evidence becomes the canonical subject ID.

Normalization is deterministic and source-specific. Canonical GitHub targets use the hostname plus repository node ID and issue or pull-request node ID, not titles or URLs that may change. Local Git targets use the repository identity plus full commit or ref identity. Display wording never participates in identity.

If improved entity mapping changes a subject key without changing the underlying subject, reconciliation stores the old key as an alias of the same action series. Aliases are unique and never silently reassigned.

### Inference status and user state

Inference status and user state are independent columns.

Inference status is:

- `active`: current evidence continues to support the action;
- `stale`: current observations no longer support it strongly enough for the default view;
- `superseded`: a verified successor represents the later commitment.

User state is:

- `open`;
- `acknowledged`;
- `snoozed`, with a required UTC `snoozed_until`;
- `done`;
- `dismissed`.

Re-analysis may change inference status, summary, confidence, due date, and evidence. It may never change user state or its state-version counter. Reaching the snooze time makes the action eligible for display again but does not erase its transition history.

The CLI owns explicit user transitions:

~~~text
cyborg actions acknowledge ACTION_ID
cyborg actions snooze ACTION_ID --until RFC3339_TIMESTAMP
cyborg actions done ACTION_ID
cyborg actions dismiss ACTION_ID
cyborg actions reopen ACTION_ID
~~~

`reopen` is the only operation that moves a `done` or `dismissed` action back to `open`. Every transition records old state, new state, timestamp, origin, and state version.

Allowed transitions are:

| Command | Accepted current states | Result |
| --- | --- | --- |
| `acknowledge` | open, snoozed | acknowledged; clears `snoozed_until` |
| `snooze` | open, acknowledged, snoozed | snoozed; sets or replaces `snoozed_until` |
| `done` | open, acknowledged, snoozed | done; clears `snoozed_until` |
| `dismiss` | open, acknowledged, snoozed | dismissed; clears `snoozed_until` |
| `reopen` | acknowledged, snoozed, done, dismissed | open; clears `snoozed_until` |

Repeating a command when the action is already in its requested state is an idempotent success and creates no transition row. Every other transition is rejected. An expired snooze remains `snoozed` but becomes currently displayable; expiration alone does not mutate state or increment its version. Done, dismissed, stale, and superseded occurrences are hidden from the default view unless configuration explicitly includes them.

### Reconciliation and successor actions

Claims reconcile in this order:

1. Match or create the action series using the subject key or a registered alias.
2. Select the series' latest occurrence.
3. If that occurrence is open, acknowledged, or snoozed, update its inference fields and attach new evidence without changing user state.
4. If that occurrence is done or dismissed, attach evidence that predates or was already known at the terminal transition without reopening it.
5. Create the next occurrence in the series only when the claim sets `new_commitment`, its anchor evidence occurred after the terminal transition, and that anchor was not associated with the prior occurrence at transition time.
6. Link the new occurrence to its predecessor and mark the predecessor inference as superseded. Preserve the predecessor's terminal user state.

If those successor conditions are not provable, CYBORG retains the terminal action and records the claim as an ambiguous reconciliation warning rather than manufacturing a duplicate.

## Persistence architecture

CYBORG uses Ruby 4.x, Sequel, and sqlite3. Sequel repositories isolate SQL and transactions from domain values; domain objects do not call one another to persist related records.

SQLite uses foreign-key enforcement, WAL journaling, a bounded busy timeout, and strict tables where supported. Timestamped Sequel migrations are the only way to change schema. Persisted timestamps are RFC 3339 UTC strings; display timezone is captured separately on each run. Money is stored as integer micros of the configured currency, never floating point.

The logical tables are:

| Table | Key constraints and purpose |
| --- | --- |
| `runs` | UUID primary key; lifecycle, window, versions, and prior renderable run |
| `run_leases` | One active row; run relation, token fingerprint, heartbeat, and expiry |
| `source_snapshots` | UUID; unique run/source/account; status, data/cache reason, proposed cursor, disposition, and prior activated snapshot |
| `source_baselines` | Unique source/account pointer to the latest activated fresh snapshot |
| `observed_records` | UUID; unique source/account/source ID/kind; first and last observed |
| `observed_record_versions` | UUID; unique record/content fingerprint; bounded normalized payload |
| `snapshot_records` | Unique snapshot/record-version association |
| `evidence` | UUID; record-version reference, trusted link, excerpt or field path |
| `action_series` | UUID; unique current subject key and identity version |
| `inferred_actions` | UUID; unique series/occurrence number; inference fields and user state version |
| `action_key_aliases` | Unique historical subject key mapped permanently to one action series |
| `action_evidence` | Unique action/evidence relation plus first and last associated run |
| `action_transitions` | Append-only user-state audit history |
| `action_successors` | Unique predecessor/successor relation |
| `analysis_results` | UUID; input/output fingerprints, validation status, backend metadata |
| `presentation_results` | One immutable view model per renderable run/profile |
| `cache_entries` | Stage, key, class, versions, expiry, invalidation, and bounded payload |
| `usage_records` | Run/task/session relation, reservation, tokens, cost, and certainty |

Source ingestion is transactional per source snapshot: either its normalized records, evidence, and proposed cursor are committed together or none are. Ingestion does not activate the proposed cursor. One source failure does not roll back already committed snapshots from other sources.

Result publication is one transaction. It validates the captured action-state versions against current rows, reconciles using the current user state, writes analysis and presentation records, activates eligible per-source baseline pointers, updates the run status, and advances the latest-renderable pointer together. A crash or constraint failure cannot expose a partially reconciled run or an advanced cursor without its renderable result.

Each command uses an operating-system lock only while it changes shared run state. The multi-command host workflow is protected by a persisted run lease containing run ID, random lease token fingerprint, creation time, last heartbeat, and expiry. `prepare` atomically refuses to create a second active lease; each later bridge command presents the opaque lease token, renews the lease, and may act only on its run. The token is returned in the protected `prepare` result and is never logged or persisted in plaintext.

Finalization or explicit abandonment releases the lease. An expired lease may be reclaimed only after its run is marked failed with `run.lease_expired`; it is never silently reused. The default lease is ten minutes and is configurable above the maximum analysis timeout. A second briefing invocation exits with status `75` while a valid lease exists.

Rendering remains read-only and does not require the run lease. Action-state commands use short database transactions while a run is analyzing; final publication re-reads state versions so it cannot overwrite a concurrent manual transition.

## Configuration, paths, and time

The default configuration is `~/.config/cyborg/config.toml`; `CYBORG_CONFIG` may point to another file. `cyborg config path` prints the resolved path. The file contains source identifiers, repository roots, profiles, time rules, cache policy, model capability mappings, cost ceilings, renderer settings, and the skill-editing footer. It never contains tokens.

Runtime state defaults to `~/Library/Application Support/CYBORG/` on macOS:

- `cyborg.sqlite3` for durable state;
- `artifacts/` for protected host handoffs;
- `logs/` for redacted operational logs;
- `state.lock` for short command-level critical sections.

Each run records a configuration fingerprint calculated from the fully resolved, non-secret configuration using the same canonical JSON rules as bridge artifacts. Configuration loading rejects unknown required sections, invalid enum values, nonexistent required paths, impossible time windows, and cost limits below required reservations.

The named calendar profile defines timezone, working hours, weekend days, holidays, and observed-date rules. The default US personal/business profile includes New Year's Day, Martin Luther King Jr. Day, Juneteenth, Independence Day, Labor Day, Thanksgiving, Christmas, and configurable Easter observance. Users may add, remove, or override dates without code changes.

Relevant windows are calculated in the configured timezone and persisted as UTC. The default brief covers midnight at the start of the previous business day through the end of the next business day. Source-specific profiles, such as fourteen business days for calendar tasks, may extend that window without embedding calendar rules in adapters.

## Pipeline

The full pipeline is:

~~~text
configuration and budget reservation
  -> source cache lookup
  -> direct retrieval / host request emission
  -> source normalization and snapshot persistence
  -> deterministic filtering and exact deduplication
  -> deterministic candidate extraction and entity grouping
  -> bounded analysis packet
  -> LLM claims where interpretation remains
  -> complete schema/evidence/safety validation
  -> action reconciliation
  -> immutable presentation view model
  -> surface rendering
~~~

Known rules—business windows, GitHub notification reasons, CI-only exclusion, repository bounds, timestamp selection, exact duplicates, stale cursors, and action transitions—remain Ruby code. The LLM never receives permission to redefine them.

Source content, MCP results, issue text, commit messages, email, chat, webpages, and browser history are untrusted data. They cannot authorize tool calls, add retrieval operations, change configuration, reveal credentials, alter action state, or request external writes. Future writes require a separate subsystem with explicit capabilities, deterministic parameter validation, confirmation outside generated text, and an audit record.

## Caching

Cache entries have an explicit class:

- `ordinary`: source retrieval, normalization, candidate extraction, grouping, and ordinary synthesis; default TTL 30 minutes;
- `expensive`: reflection and long-horizon recommendations; profile-specific TTL of at least three hours.

Expense is never inferred from TTL. A cache key includes stage, canonical input fingerprint, implementation version, configuration fingerprint, source adapter versions, prompt version, and backend identity where relevant.

The analysis input fingerprint uses sorted normalized record content fingerprints, task, prompt version, configuration fingerprint, and relevant action-state versions. It does not rely solely on newly allocated snapshot IDs. Therefore, a source-cache hit with unchanged records reuses validated analysis instead of spending tokens again.

Cache operations are:

- normal run: read valid ordinary and expensive entries;
- `cyborg-no-cache`: mark eligible ordinary entries invalidated, bypass them, and retain valid expensive entries;
- `cyborg-no-cache-even-expensive`: mark both classes invalidated and bypass them.

Invalidation records timestamp, command, run ID, and reason. Retention later removes expired payloads while preserving bounded audit metadata. One hundred rapid identical normal invocations must result in no additional LLM calls after the first validated result, provided the relevant configuration and user action state are unchanged.

## Budget and usage accounting

The configured default ceiling is $5.00 per run. This is a local launch budget, not an unconditional promise about a host or provider bill.

Before LLM work, the budget controller creates a usage reservation from the configured worst-case input/output tokens and current price catalog. Work cannot launch without a reservation. Required work reserves first; reflection and other optional tasks are skipped when the remaining budget cannot cover their reservation. No new work launches after reserved plus reported spend reaches the ceiling.

When the host exposes live usage and cancellation, the host adapter cancels still-running delegated tasks once reported spend reaches the ceiling. When it does not, CYBORG can prevent further reserved work but cannot guarantee termination of an opaque call already controlled by the host; that limitation is reported with the final cost uncertainty.

Each orchestration, host, direct-provider, or delegated session receives a separate usage row related to the run and parent session. Rows distinguish reserved, provider-reported, locally estimated, and unknown tokens and cost. Unused reservations are released when usage becomes known or work is canceled.

When a host does not expose usage or model pricing, CYBORG records the configured reservation and marks final cost uncertain. The renderer states that the local launch policy was enforced but final provider billing is unknown.

The price catalog records provider, model, input/output rates, source URL, effective date, and last verification time. Automatic seven-day refresh is part of the direct-provider scheduling milestone. V1 uses a human-reviewed configured catalog and warns when it is older than seven days.

## Failure handling and health

The operational rule is:

> Fail an adapter loudly and degrade the run usefully; fail the whole run only when CYBORG cannot publish a safe result.

Every configured source reports `healthy`, `degraded`, `failed`, or `disabled`, plus fresh/cached/none data status. A valid policy cache hit remains healthy. A failure fallback is degraded even when cached data is usable. A degraded presentation begins with `⚠️ SOURCE HEALTH` and states the source, last fresh refresh, whether cached data was used, bounded remediation, and whether missing data may affect inferred actions.

Systemic failures include invalid configuration before a run can be defined, database corruption, inability to persist a safe result, artifact tampering, and safety-policy violations requiring termination. These produce a failed run when persistence remains possible and a nonzero CLI status.

Logs redact authorization values, environment secrets, unnecessary source bodies, and prompt content. Error records use stable codes plus safe remediation rather than persisting raw command output indiscriminately.

## Presentation contract

The canonical presentation input is an immutable persisted view model, not Markdown. It contains:

- run and source-health summaries;
- ordered action and informational sections;
- item IDs, summaries, timestamps, freshness, urgency, confidence, and state;
- trusted source and evidence links;
- warnings, skipped tasks, and cost certainty;
- configured footer text.

All renderers must be semantically equivalent: they expose the same items, ordering, states, links, and warnings from the same view model. They need not be byte-identical because Markdown, JSON, notifications, and a width-sensitive TUI have different formatting constraints.

The default action-first ordering is:

~~~text
⚠️ SOURCE HEALTH
DO
RESPOND
PREP
WAITING ON
DECIDE
CHANGED
FYI
~~~

Freshness and urgency are independent. Compact age uses the selected event timestamp, floors to the largest useful unit (`s`, `m`, `h`, or `d`), and prefixes future values with `in`. Recency markers compare records with the source's prior activated fresh snapshot; urgency markers use configured age and action rules.

The default marker precedence is deterministic:

1. `🔥🔥` for age from zero up to but not including 30 minutes.
2. `🔥` for age from 30 minutes up to but not including 90 minutes.
3. `🆕`, only when no fire marker applies, when the record was first seen after the prior activated source snapshot or its age is from two hours up to but not including four hours.
4. `🚨` independently for an active pending action whose user state makes it currently displayable; it may appear beside any recency marker.

The renderer supports disabling optional markers. Emoji not explicitly required by the product brief remain disabled by default.

The reminder for editing the skill is configured presentation footer text. It is not an inferred claim and is always the final Markdown line when enabled.

## Reflection attribution

Reflection consumes the same normalized records and evidence model with longer windows and expensive caching. It may summarize authored commits, merged pull requests, completed tasks, sent communications, LLM chats, and configured browsing activity as later adapters become available.

Attribution must be evidence-based. LLM-chat or branch attribution is labeled uncertain unless tied to a durable repository, task, branch, or commit identifier. Reflection may report insufficient signal and must not manufacture trends or recommendations.

Git reports additions and deletions, not a separate reliable count of modified lines. CYBORG therefore defines user-facing line churn as additions plus deletions from text-file numstat. Binary changes and rename-only changes are reported separately and never guessed. This replaces the original ambiguous additions-plus-modifications-plus-deletions metric with one that can be reproduced from Git.

## First usable release: v1 vertical slice

V1 proves the permanent architecture through one interactive path rather than implementing every target surface.

### Included

- Ruby 4.x CLI modular monolith;
- Sequel migrations and SQLite repositories;
- TOML configuration and business-day calendar;
- run lifecycle, per-source health, caches, usage reservations, and protected artifacts;
- direct GitHub adapter through `gh`;
- direct local Git activity adapter;
- fixture source and fixture LLM backends;
- host-mediated analysis through the JSON bridge;
- observed records, evidence, stable actions, reconciliation, and manual state commands;
- persisted Markdown and JSON renderers;
- brief action view plus local-Git reflection;
- deterministic unit, contract, integration, and end-to-end tests.

### GitHub adapter contract

The GitHub adapter invokes a configured `gh` executable and reuses its authenticated account. CYBORG never asks `gh` to reveal its token and never stores the token.

Health checks distinguish:

- `github.binary_missing`: the configured executable is absent or not executable;
- `github.unauthenticated`: `gh auth status --active --hostname HOST` reports no usable account;
- `github.api_unavailable`: an authenticated API request fails or times out;
- `github.invalid_response`: output violates the adapter schema or bounds.

The adapter uses bounded, paginated `gh api` requests and parses JSON inside Ruby. It retrieves the configured account's notification threads and enough pull-request/comment metadata to identify:

- pull requests from others requesting the user's review;
- comments or reviews on the user's pull requests;
- replies, mentions, and assignments directed to the user.

Notifications whose only reason is CI activity are excluded deterministically. A pull-request thread with another included reason is not discarded merely because it also contains check activity. Repository and organization allowlists, hostname, maximum pages, and maximum records are configuration.

Stable targets use GitHub node IDs when available. URLs are constructed or accepted only for the configured GitHub hostname. The adapter is read-only and invokes no mutating `gh` command or API method.

### Local Git adapter contract

The local Git adapter scans only configured roots and explicit repositories. Discovery has a maximum depth, maximum repository count, and no symlink traversal. A directory is a repository only when `git -C PATH rev-parse --git-dir` succeeds within the configured timeout.

Authored activity matches configured author email addresses and optional signing identities. It collects unique commits in the reflection window, then associates each commit with one display branch using this priority: current branch containing the commit, configured primary branch containing it, most recently updated local branch containing it, then detached/unclassified. A commit is counted once per repository even if several refs contain it.

Summaries use commit metadata and bounded diffs. Line churn is text additions plus deletions; binary and rename-only changes are separate counters. Command arguments are passed without a shell, output bytes and execution time are bounded, and repository content is treated as untrusted.

### Deferred from v1

The following remain target capabilities but are not v1 acceptance requirements:

- direct Anthropic or OpenAI backends;
- launchd scheduling at 8 AM, noon, and 3 PM on weekdays;
- automatic weekly provider-price refresh;
- Gmail, Calendar, Slack, Linear, Hacker News, browser-history, and LLM-chat adapters;
- TUI, notification, audio, and web renderers;
- a persistent local service;
- external write actions.

The first post-v1 milestone adds a direct-provider backend and launchd scheduling without changing normalized records, actions, repositories, or the presentation view model. Later sources are added one vertical adapter at a time with their own fixtures and health contract.

## Verification strategy

The deterministic test suite uses temporary SQLite databases, a fixed clock, fixture sources, fixture host artifacts, and recorded structured LLM results. It never requires live credentials or network access.

Unit tests cover:

- business-day, timezone, holiday, and observed-date calculations;
- artifact canonicalization, fingerprints, versions, bounds, and atomic writes;
- exact source deduplication and timestamp selection;
- subject-key normalization, aliases, successor criteria, and state transitions;
- cache keys, invalidation classes, TTLs, and unchanged-input reuse;
- budget reservation, optional-work skipping, uncertainty, and usage hierarchy;
- GitHub filtering and local-Git attribution from fixtures;
- view-model ordering, markers, warnings, links, and footer placement;
- secret and untrusted-content redaction.

Contract tests run every adapter against success, cached, malformed, timeout, authentication, pagination-limit, and partial-data fixtures. LLM contract tests reject nonexistent evidence, untrusted URLs, unsupported categories, over-limit claims, source-write requests, and adversarial instructions embedded in source text.

End-to-end tests exercise:

~~~text
fixture/direct retrieval
  -> source snapshots and observed records
  -> analysis packet
  -> fixture analysis result
  -> validation and action reconciliation
  -> SQLite publication
  -> semantically equivalent Markdown and JSON
~~~

Critical scenarios are:

1. New evidence attaches to a completed action without reopening it.
2. A later, explicitly supported commitment creates a linked successor.
3. GitHub fails while local Git remains useful and the run renders degraded.
4. A malformed host artifact is rejected without partial claim persistence.
5. A claim referencing unknown evidence yields a degraded deterministic result.
6. One hundred identical normal runs perform no additional LLM work after the first validated result.
7. A failed run advances neither the renderable pointer nor a source cursor.
8. A degraded run advances healthy source baselines but not failed or cached source baselines.
9. Ordinary invalidation preserves expensive entries; full invalidation bypasses both classes.
10. A manual action transition during analysis survives final publication.
11. Budget exhaustion skips optional work and stops new launches while preserving an auditable result.

Live smoke tests are separate and opt-in. They verify `gh` authentication, configured repository discovery, direct-provider credentials in the later milestone, and adapter API compatibility without becoming release-test dependencies.

## Acceptance criteria

V1 is complete when:

- the interactive skill can execute the full JSON-file protocol without owning domain policy;
- GitHub and local Git produce bounded normalized records with evidence and visible health;
- invalid or adversarial host results cannot mutate action state or persist unsupported claims;
- done, dismissed, acknowledged, and snoozed state survives retrieval and re-analysis;
- genuinely later commitments become explicit successors rather than silent reopenings;
- completed and degraded results publish atomically and failed runs remain non-renderable;
- repeated unchanged runs reuse source and analysis caches without additional LLM calls;
- local budget reservations and uncertainty are visible and auditable;
- Markdown and JSON expose the same persisted items, states, order, warnings, and trusted links;
- the deterministic suite passes without network access or a live LLM.

The target repeatability contract is:

> Given identical normalized source content, configuration, user action-state versions, and a persisted validated analysis result, CYBORG produces identical domain state and presentation view models. Surface formatting may differ, and regenerated probabilistic analysis may differ, but every accepted change is schema-valid, evidence-grounded, explicit, and idempotently reconciled.

## Architectural alternatives

### Skill-centric orchestration

A skill could call MCP tools, prompt an LLM, and use Ruby only for formatting. This is useful for a disposable product prototype, but it makes durable state, scheduling, cache semantics, action identity, and failure handling depend on prompt adherence. It is not the selected implementation architecture.

### Ruby core with protocol-based host integration

This is the selected architecture. It keeps deterministic policy and state in Ruby while allowing a host to execute capabilities unavailable to a child process. The explicit artifact protocol also makes host behavior inspectable and fixture-testable.

### Persistent local service

A daemon could simplify concurrent clients and reduce startup latency. It also adds lifecycle, port, authentication, and upgrade concerns before v1 needs them. It remains compatible with the modular monolith if later measurements justify it.

### All sources in v1

Implementing Gmail, Calendar, Slack, GitHub, and Linear together would demonstrate breadth sooner, but authentication and source semantics would obscure defects in the core contracts. The selected GitHub-plus-local-Git slice proves remote retrieval, local activity, actions, reflection, evidence, caching, and rendering with fewer independent failure modes.

## Related documentation

- [Original product brief](./executive-summary-skill.md): desired information sources, presentation, scheduling, caching, and reflection behavior.
- [Original architecture design](./cyborg-architecture-design.md): the initial Ruby-core decision and broader target architecture.
- [Claude Code feature overview](https://code.claude.com/docs/en/features-overview): current separation among skills, MCP tools, hooks, and subagents.
- [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp): host-managed MCP server and tool capabilities.
- [GitHub CLI API manual](https://cli.github.com/manual/gh_api): authenticated REST/GraphQL invocation, pagination, and JSON processing.
- [GitHub CLI authentication status](https://cli.github.com/manual/gh_auth_status): non-secret authentication health checks.
- [Sequel documentation](https://sequel.jeremyevans.net/documentation.html): migrations, transactions, schema constraints, and SQLite support.
