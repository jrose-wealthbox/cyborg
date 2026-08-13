# CYBORG Architecture Design

Status: Design approved for documentation

This document defines the target architecture for CYBORG, a personal information dashboard and executive-summary agent. It describes system boundaries and contracts, not an implementation sequence or MVP plan.

The original product brief remains in [docs/executive-summary-skill.md](./executive-summary-skill.md). This document does not replace or modify that brief.

## Architectural decision

CYBORG is a headless Ruby application with durable local state. A host-specific LLM skill is a thin adapter for interactive invocation and presentation; it is not the system of record.

The Ruby application owns the data plane:

- source adapters and source health;
- configuration and time-window calculation;
- retrieval, normalization, filtering, and deduplication;
- SQLite state, cache entries, and cursors;
- inferred-action identity and user-controlled action state;
- evidence and provenance;
- execution state, failure handling, and cost accounting where observable;
- structured-result validation;
- renderer contracts.

The LLM owns the probabilistic intelligence plane:

- semantic classification;
- cross-source synthesis when deterministic grouping is insufficient;
- reflection and recommendations;
- natural-language explanation.

The skill, CLI, scheduler, TUI, notifications, and future web UI are control or presentation surfaces over the same application contracts and persisted state.

## Goals

CYBORG should:

- present the smallest amount of information that improves the next decision;
- emphasize actions, responses, preparation, waiting, and meaningful change;
- combine related information across Gmail, Slack, Linear, GitHub, and future sources while preserving source evidence;
- support interactive host-mediated LLM calls and unattended direct-provider execution;
- remain useful when individual sources are unavailable or stale;
- make freshness, urgency, confidence, and provenance visible and distinct;
- preserve user-controlled action state across repeated retrievals and changing LLM wording;
- support Markdown, TUI, JSON, notification, audio, and future web renderers;
- keep secrets out of ordinary repository configuration;
- make repeated runs cheap through layered caching;
- keep source and analysis contracts provider-agnostic.

## Non-goals

This document does not define:

- an implementation roadmap or phased delivery plan;
- a particular Ruby web framework;
- a requirement to reimplement every existing MCP connector in Ruby;
- automatic write access to Gmail, Slack, Calendar, GitHub, Linear, or other source systems;
- byte-for-byte deterministic LLM output;
- indefinite retention of all source content;
- a multi-user authorization model.

## System boundary

~~~text
┌─────────────────────────────────────────────────────────┐
│ Presentation / host surfaces                             │
│ Claude Code skill · Claude Desktop · TUI · web UI       │
└──────────────────────────┬──────────────────────────────┘
                           │ invoke / consume contracts
┌──────────────────────────▼──────────────────────────────┐
│ CYBORG Ruby application                                  │
│                                                          │
│  Run coordinator                                         │
│  ├─ source registry and capability discovery             │
│  ├─ retrieval scheduler                                  │
│  ├─ normalization and deduplication                      │
│  ├─ action/commitment extraction                         │
│  ├─ analysis orchestration                               │
│  ├─ cache and run-state management                       │
│  └─ renderer/API                                         │
│                                                          │
│  SQLite: facts · evidence · actions · runs · usage       │
└───────────────┬─────────────────────┬────────────────────┘
                │                     │
       ┌────────▼────────┐   ┌────────▼─────────┐
       │ Source adapters  │   │ LLM adapters      │
       │ Direct API       │   │ Host-mediated     │
       │ MCP/host bridge  │   │ Anthropic        │
       │ Local OS/files   │   │ OpenAI           │
       └──────────────────┘   └──────────────────┘
~~~

The central rule is:

> If a behavior must be correct, repeatable, cached, audited, or tested, it belongs in Ruby. If it is interpretive or linguistic, it may belong to the LLM.

| Responsibility | Ruby application | LLM |
| --- | ---: | ---: |
| Fetch source records | Yes | No |
| Calculate business-day windows | Yes | No |
| Apply source filters | Yes | No |
| Exclude known CI-only notifications | Yes | No |
| Infer that a conversation implies a follow-up | Candidate extraction | Yes |
| Persist snoozed or done state | Yes | No |
| Combine ambiguous records | Assist | Yes |
| Generate prose | No | Yes |
| Render a persisted result | Yes | Optional |
| Modify an external system | Separate future subsystem | Never implicitly |

## Host skill boundary

The CYBORG skill is a host adapter. It should:

1. invoke CYBORG in interactive mode;
2. supply or authorize host-only source access where needed;
3. provide an LLM call when the host-mediated backend is selected;
4. relay the structured result to CYBORG for validation and persistence;
5. render or display the validated result;
6. show the configurable reminder for editing the skill.

The skill must not define cache semantics, source-specific time windows, action-state meanings, deduplication identity, the meaning of “last run,” the canonical Markdown format, or authorization to perform external writes.

This boundary follows the distinction used by current agent hosts: MCP or connectors provide access to external systems, while skills provide workflow knowledge and procedures. Deterministic guarantees should be implemented in application code or enforcement hooks rather than relying solely on natural-language instructions. See the [Claude Code feature overview](https://code.claude.com/docs/en/features-overview).

## Runtime modes

Both modes use the same normalized model, SQLite database, cache keys, action identity rules, and renderer contracts.

### Interactive host-mediated mode

Used from Claude Code, Claude Desktop, or another compatible host where some connectors are already available:

~~~text
host skill
  -> cyborg prepare
  -> source adapters, including host-only MCP access
  -> bounded analysis packet
  -> host LLM synthesis
  -> cyborg record-result
  -> renderer
~~~

The returned data still passes through CYBORG normalization, evidence, validation, and persistence boundaries.

### Headless direct-provider mode

Used by macOS scheduling, a local service, or a future web backend:

~~~text
launchd / local service
  -> cyborg run
  -> direct source adapters
  -> direct LLM backend
  -> structured-result validation
  -> SQLite persistence
  -> Markdown/JSON/notification renderer
~~~

Headless execution must not depend on Claude Desktop or Claude Code being open.

## Source adapter boundary

Source adapters expose capabilities rather than forcing all sources into an identical API shape.

Conceptually:

~~~ruby
SourceAdapter
  # Metadata
  source_name
  account_identity
  capabilities

  # Retrieval
  fetch(window:, cursor:, cache_policy:)

  # Optional synchronization helpers
  health_check
  next_cursor
  deep_link(record)
end
~~~

An adapter may use a direct Ruby API client, local CLI, MCP/host bridge, macOS API, or local file. It returns normalized observed records, source health, freshness, and provenance. It does not generate dashboard prose and does not return unbounded raw content by default.

The source registry may discover installed capabilities at startup, but discovery is not permission to read every available source. A source must be explicitly enabled and configured with its account, filters, retention policy, and allowed capabilities.

## LLM adapter boundary

LLM backends expose abstract capabilities rather than vendor model names:

~~~ruby
LlmBackend
  analyze(packet:, task:, budget:)
    # Returns validated structured claims plus usage metadata.
end
~~~

Examples include cheap_structured_extraction, medium_reasoning, and high_reasoning. Provider-specific models and sampling settings map to those capabilities in configuration. Domain logic must not depend on names such as Sonnet, Haiku, Opus, or a provider model identifier.

The architecture supports:

- HostLlmBackend, where the active skill/host provides the model call;
- DirectProviderBackend, where Ruby calls a configured provider for unattended execution.

The rest of CYBORG must not care which backend produced the analysis.

## Durable domain model

CYBORG distinguishes three kinds of information:

~~~text
Observed facts
  “A Slack message was posted.”

Inferred claims
  “You probably owe Alice a reply.”

User-controlled state
  “Snoozed until Friday.”
~~~

These are not one mutable “item.” Source facts can change or disappear, an inferred action must retain evidence, and user state must survive re-fetches and re-summarization.

~~~text
Run
 ├─ SourceSnapshot
 │   └─ ObservedRecord
 │       └─ Evidence
 ├─ InferredAction
 │   ├─ Evidence references
 │   ├─ confidence
 │   └─ lifecycle state
 └─ AnalysisResult
     └─ rendered representations
~~~

### Run

A run records a unique ID, mode, start and completion timestamps, relevant time window, configuration version, LLM backend/capability, status, relationship to the last successful run, and cost/usage metadata.

Statuses are running, completed, degraded, or failed. “Last run” is distinct from “last successful run”; a run that cannot persist a result must not advance the baseline for “new since last run” markers.

### SourceSnapshot

A source snapshot records source/account identity, retrieval start/end timestamps, source cursor or sync token, freshness, status and error details, record count, and adapter version.

### ObservedRecord

An observed record contains stable source and source-record IDs, record kind, title/summary metadata, source timestamps, normalized participants and ownership, a source URL/deep link, bounded content or structured fields, a content fingerprint, and first-seen/last-observed timestamps.

Timestamp semantics are source-specific:

- event_at: when the source activity occurred;
- latest_reply_at: latest reply when applicable;
- observed_at: when CYBORG retrieved it.

Display age normally uses latest_reply_at. When that does not apply, it falls back to the source’s message-creation or event timestamp. The timestamp type is retained so the renderer does not imply false precision.

### InferredAction

An inferred action contains a stable local action ID, action kind such as do/respond/prepare/decide/waiting_on, concise summary, related people/projects, due date or inferred deadline, confidence, evidence IDs, first/last-seen timestamps, a grouping key, and user-controlled lifecycle state.

Allowed lifecycle states are:

~~~text
open
acknowledged
snoozed
done
dismissed
stale
~~~

The state belongs to the local action, not the source record. If an email remains unread after its action is marked done, CYBORG must not silently reopen that action. A genuinely new event may create a new action candidate.

### Evidence

Evidence contains the observed-record ID, source URL, source display label, relevant excerpt or field reference, evidence timestamp, and an optional relation such as supports, contradicts, or context.

Every inferred action includes evidence links and a confidence estimate. Confidence describes the inference, not source reliability, and is never a substitute for evidence.

## Deduplication and cross-source synthesis

Deduplication occurs in stages:

1. Exact source deduplication using source IDs and content fingerprints.
2. Cross-source entity matching using known users, repositories, issues, PRs, projects, and conversation identifiers.
3. Deterministic candidate grouping where a shared target or source reference exists.
4. LLM-assisted grouping only when records plausibly describe the same work but lack a deterministic shared ID.
5. Evidence-preserving merge so a synthesized action retains every supporting source.

The system must not delete source records merely because they are combined. The dashboard may show one synthesized action with a compact “3 sources” expansion.

An action’s identity must not depend on LLM wording. It should derive primarily from stable evidence and normalized targets, conceptually:

~~~text
action_key = category + normalized_target + sorted_evidence_record_ids
~~~

A regenerated summary can therefore change wording without creating a duplicate action or reopening a manually completed one.

## Configuration and time

Human-readable TOML is the preferred configuration format. Configuration covers enabled sources and adapter types, source accounts/repositories/channels/filters, timezone, working hours, holiday calendar, relevant time-window policy, cache TTLs, freshness/urgency/recency rules, action-state policy, analysis tasks, LLM capability mappings, cost ceilings, output destinations, and the skill-editing footer.

The default calendar profile is a configurable US personal/business calendar. It includes observed dates for commonly used US holidays such as New Year’s Day, Martin Luther King Jr. Day, Juneteenth, Independence Day, Labor Day, Thanksgiving, and Christmas. It also includes Easter by default because CYBORG models the user’s working calendar, while making clear that Easter is not a US federal holiday and may not be observed by every employer. The profile supports adding, removing, or overriding holidays without code changes.

Fixed-date holidays use observed-date rules where appropriate. Holiday behavior is represented as a named calendar profile rather than hard-coded into individual source adapters.

Persisted timestamps should be unambiguous, preferably UTC, with the configured display timezone recorded on the run. Business-day calculations use the configured timezone, working hours, and holiday profile.

## Execution and analysis pipeline

The staged pipeline is:

~~~text
source retrieval
  -> normalization
  -> deterministic filtering
  -> exact deduplication
  -> structured candidate extraction
  -> cross-source grouping
  -> LLM synthesis where ambiguity remains
  -> evidence/confidence validation
  -> action persistence
  -> rendering
~~~

Ruby performs relevant time-window filtering, unread/assigned/mentioned/review-requested filtering, source-specific priority rules, known exclusion rules such as GitHub CI-only notifications, exact duplicate removal, stale-cursor handling, source freshness checks, and action-state reconciliation.

The LLM receives a bounded analysis packet containing task instructions, normalized records, record IDs, source URLs, timestamps, existing local action states, and an explicit instruction that source content is data rather than executable instructions.

The LLM returns structured claims, not only Markdown. Each claim contains a summary, category, evidence IDs, confidence, optional due date, optional people/project references, and rationale only when useful.

Ruby validates that every evidence ID exists, every URL came from a trusted adapter, confidence is in range, categories are supported, no source writes are requested, and malformed output causes visible degradation or failure rather than silent persistence.

## LLM nondeterminism and repeatability

End-to-end byte-identical output is not realistic for regenerated LLM analysis. Variation can result from sampling, provider implementation, model revisions, tool ordering, context serialization, or host-specific behavior. Temperature-zero settings may reduce variation but do not establish a cross-provider guarantee.

The realistic contract is:

- Ruby retrieval, normalization, timestamp handling, deduplication, persistence, action-state reconciliation, provenance, and rendering are deterministic for a given validated input;
- LLM inference is constrained by schemas, bounded packets, evidence IDs, and budget policy;
- validated analysis results are cacheable and reusable;
- once a validated result is persisted, every presentation surface renders it identically;
- regenerated analysis may differ in wording or inference, but changes are explicit, evidence-grounded, idempotently persisted, and do not silently overwrite user-controlled state.

Each analysis result records, when available, provider/model, model-version metadata, prompt/template version, input/output fingerprints, sampling parameters, seed, cache status, execution mode, and provider-reported/local estimated usage.

The effective analysis input fingerprint includes source snapshot IDs, configuration version, task, prompt/template version, and relevant action-state inputs. Identical inputs reuse a prior validated result instead of asking an LLM to regenerate equivalent prose.

## Caching, budgets, and usage accounting

Caching belongs below the LLM skill and is owned by Ruby. The target architecture supports separate cache layers for source retrieval, normalization, candidate extraction, grouping, synthesis, and reflection.

Each cache entry includes input fingerprint, source/configuration versions, model/backend identity when relevant, creation/expiration timestamps, estimated/observed usage, cost metadata, and invalidation reason.

The default cache TTL is configurable, with ordinary items defaulting to 30 minutes and expensive reflection items using longer TTLs. A no-cache operation may invalidate ordinary caches while preserving expensive entries; a separate no-cache-even-expensive operation invalidates all eligible caches.

The budget controller reserves budget before LLM work, accounts for known usage, avoids optional reflection when the reserve is insufficient, stops launching work when the local budget is exhausted, records skipped tasks, distinguishes estimated from provider-reported usage, and retains separate usage rows for orchestration and delegated sessions.

A hard dollar guarantee is impossible when a host controls the model call or pricing metadata is unavailable. CYBORG can enforce its own launch budget and report uncertainty explicitly; it must not claim that the external provider’s final bill is known when it is not.

## Presentation contracts

Markdown and TUI output are renderings of validated persisted results, not canonical storage formats.

Supported conceptual renderers include:

- brief: action-first scan;
- detail: source and evidence expansion;
- morning: forward-looking priorities and preparation;
- midday: changes, urgent responses, and blockers;
- evening: completed work, unresolved commitments, and next-day preview;
- tui: terminal-safe formatting;
- json: future web/API consumers;
- optional notification and audio renderers.

The default organization is action-oriented:

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

A source-oriented detail view remains available for investigation, but the default output should not reproduce each application’s inbox separately.

Each rendered item supports, where available, source hyperlinks, evidence links, compact age, configurable freshness markers, configurable urgency markers, confidence for inferred actions, and source freshness state.

Freshness and urgency are independent. A new item is not necessarily urgent, and an old unresolved commitment may be highly urgent.

Recency symbols are configuration, not domain logic. They are calculated from event timestamps and the last successfully completed run, not merely from the current wall-clock time. The renderer supports disabling them to avoid visual noise. The final reminder about editing the skill is a configurable footer, not part of the analysis model or action records.

## Reflection and activity attribution

Reflection consumes the same normalized source and evidence model as the action-oriented brief, but uses a longer retention window and separate cache policy.

It may summarize code committed, pull requests merged, completed or closed tasks, Slack messages and emails sent, LLM chats, relevant local Git/worktree activity, and configured browser or reading activity.

LLM-chat attribution is uncertain unless the activity is directly tied to a repository, task, branch, or other durable identifier. Output labels inferences as uncertain rather than presenting them as confirmed authorship.

For code activity, “lines of code” means additions plus modifications plus deletions. A change with 10 additions, 5 modifications, and 100 deletions is reported as 115 lines from the user’s perspective. Internal metrics may retain subtotals, but the user-facing contract does not require showing them.

Reflection may say that signal is insufficient. It must not force trends, insights, or recommendations merely to fill a section.

## Failure handling

Source failures are isolated by adapter. Each source reports healthy, degraded, failed, or disabled.

A run continues when one source fails, while displaying a prominent warning with the affected source, last successful refresh, whether cached data was used, remediation steps, and whether the failure may have affected inferred actions.

The whole run fails only for systemic conditions such as database corruption, invalid configuration, inability to persist results, or a safety-policy violation.

Warnings use ⚠️ because the product brief explicitly requires it. Other emoji remain opt-in through renderer configuration.

## Security and trust boundaries

Briefing execution is read-only by contract.

CYBORG treats emails, Slack messages, issue/PR descriptions and comments, web pages, documents, MCP output, and browser history as untrusted content. External text may be summarized but cannot authorize a tool call, change configuration, reveal secrets, or alter action state.

Future writes belong to a separate action subsystem with explicit capabilities, narrow per-tool permissions, deterministic parameter validation, confirmation outside generated text, an audit record, and no implicit escalation from briefing mode.

This boundary is necessary because indirect prompt injection and MCP tool poisoning can place attacker-controlled instructions into otherwise trusted tool results. The [OWASP MCP tool poisoning guidance](https://owasp.org/www-community/attacks/MCP_Tool_Poisoning) recommends least privilege, server-side enforcement, approved tool sources, and explicit confirmation for sensitive actions.

## Secrets and retention

CYBORG should not make ordinary configuration files the source of truth for OAuth tokens or provider keys. Preferred credential sources are:

1. existing provider CLI or session credentials;
2. macOS Keychain or equivalent secure credential store;
3. environment variables for controlled headless execution;
4. encrypted local credential storage only if unavoidable.

The repository contains source identifiers, filters, and non-secret behavior configuration only. Logs redact authorization headers, tokens, unnecessary message bodies, and sensitive prompt content.

CYBORG retains bounded excerpts, structured fields, fingerprints, metadata, and source links by default rather than indefinitely storing every full message or browsing record. Retention is configurable per source and record class.

## Scheduling

Scheduling is an operating-system or service concern, not an LLM behavior. On macOS, a per-user launchd job is the target mechanism for scheduled execution. The application still records the run lifecycle and can be invoked ad hoc from the CLI or a host skill.

The run record distinguishes started_at, completed_at, last_successful_run_at, last_rendered_at, and last_source_refresh_at. This prevents a partially failed run from becoming the baseline for “new since last run” calculations.

## Verification strategy

The architecture must be testable without live LLM calls or production connectors.

Ruby tests cover business-day and holiday calculations, observed-date rules, timestamp fallback rules, age/freshness/urgency/recency calculations, exact and cross-source deduplication, action-state reconciliation, evidence preservation, cache hits/invalidation, source degradation, budget reservation/skipping, malformed LLM response rejection, renderer contracts, and secret redaction.

Contract fixtures represent Gmail, Calendar, Slack, GitHub, Linear, Hacker News, local Git, and LLM-chat activity in normalized form.

LLM tests use recorded structured responses and adversarial content fixtures. They verify that external instructions are treated as data and that claims cannot reference nonexistent evidence.

End-to-end tests exercise:

~~~text
source fixture
  -> run coordinator
  -> SQLite
  -> analysis fixture/backend
  -> validated result
  -> Markdown/TUI/JSON
~~~

Live smoke tests may validate credentials and adapter behavior, but remain separate from deterministic test suites.

## Acceptance criteria

The acceptance contract is not byte-identical prose from regenerated LLM calls. It is deterministic application behavior around a probabilistic analysis boundary:

> Given identical source snapshots, configuration, and a persisted validated analysis result, CYBORG produces identical persisted facts, action states, provenance, and renderer output regardless of whether the result is viewed through a skill, CLI, scheduler, or future web client.

When analysis is regenerated, CYBORG does not require byte-identical LLM output. It requires schema-valid, evidence-grounded, budgeted output with stable local identities, idempotent persistence, and explicit recording of changed inferences. User-controlled action states must not be silently reopened or overwritten by regenerated wording.

## Architectural tradeoffs

### Skill-centric implementation

The LLM skill could own orchestration, call MCP tools directly, and invoke Ruby only for caching or formatting. This minimizes initial code, but makes durable state, scheduling, cost control, failure handling, and reproducibility depend on host behavior and prompt adherence. It is suitable for a prototype, not the target architecture.

### Ruby core with pluggable LLM host

This is the selected architecture. It provides durable state and deterministic boundaries while allowing existing host connectors to remain useful. It also supports direct-provider execution later without changing the domain model.

### Persistent local service

A local daemon or HTTP service is a compatible deployment shape for the selected architecture. It is useful when multiple surfaces need concurrent access, but the service should expose the Ruby application contracts rather than become a second source of domain semantics.

## Inspiration and related patterns

The design is informed by these current patterns:

- [Claude Code feature overview](https://code.claude.com/docs/en/features-overview): skills, MCP, hooks, and subagents solve different problems and are intended to be combined rather than treated as interchangeable.
- [Vercel personal-agent template](https://github.com/vercel-labs/personal-agent-template): an agent runtime sits alongside a persistent application layer backed by SQLite, with durable memory and explicit approval for memory changes.
- [OpenWorker](https://github.com/andrewyng/openworker): a local agent server separates the desktop surface from tools, connectors, scheduling, and approval before consequential actions.
- [OpenJarvis](https://github.com/open-jarvis/OpenJarvis): scheduled digest, stateful monitor, skills, and on-demand orchestration are separate runtime concepts.
- [Google Workspace MCP documentation](https://developers.google.com/workspace/guides/configure-mcp-servers?hl=en): read and write capabilities should be explicit and inherit the user’s access controls.
- [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/agents/): orchestration, tools, guardrails, handoffs, and sessions can be layered, but an application may also own the orchestration loop directly.
- [Waku Agent](https://github.com/ShenSeanChen/waku-agent): local-first scheduled briefings and clickable source links are practical presentation patterns.

These examples support the architectural conclusion that CYBORG should own a durable application/data layer while treating skills and presentation surfaces as replaceable interfaces.

