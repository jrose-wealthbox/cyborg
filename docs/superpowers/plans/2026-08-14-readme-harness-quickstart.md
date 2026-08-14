# README Coding-Harness Quickstart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `README.md` sufficient to initialize CYBORG, configure credentials safely, and run the application through a provider-neutral coding harness.

**Architecture:** Keep CYBORG’s credential boundary explicit: configuration stores policy and identifiers, GitHub authentication remains owned by `gh`, and model access remains owned by the coding harness. Point the harness to the canonical repository-local skill instead of duplicating bridge policy.

**Tech Stack:** Markdown, Ruby CLI commands, GitHub CLI (`gh`), CYBORG host skill

## Global Constraints

- Modify `README.md` only for implementation; do not change application behavior.
- Never instruct users to place credentials in TOML, committed `.env` files, prompts, logs, or artifacts.
- Keep commands consistent with `bin/cyborg`, `config/example.toml`, and `skills/cyborg/SKILL.md`.
- Stage only the intended README and plan documentation; leave the unrelated `Gemfile.lock` modification unstaged.

---

### Task 1: Document Initialization, Credentials, and Harness Invocation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `config/example.toml`, `skills/cyborg/SKILL.md`, `skills/cyborg/references/bridge-protocol.md`, `bin/cyborg`
- Produces: a copy-and-paste first-run path and provider-neutral harness invocation for repository users

- [ ] **Step 1: Add the credential-free initialization path**

Keep the existing setup commands and state explicitly that the bundled fixture source requires no credentials or network access. Confirm that `CYBORG_CONFIG` points to the copied TOML and that `bin/cyborg config path` resolves it.

- [ ] **Step 2: Add the credential boundary**

Document these exact source/authentication mappings:

```text
Fixture source   -> no credentials
Local Git source -> no credentials; reads existing local repositories
GitHub source    -> authenticated GitHub CLI session (`gh auth login`)
LLM analysis     -> current coding-harness session; no CYBORG API-key field
```

Include:

```sh
gh auth login --hostname github.com --web
gh auth status --active --hostname github.com
```

Mention `GH_TOKEN` or `GITHUB_TOKEN` only as externally injected headless alternatives that override stored `gh` credentials. State that the configuration `account` value is an identifier, not a secret.

- [ ] **Step 3: Add the coding-harness workflow**

Add this provider-neutral prompt, using `/tmp/cyborg-artifacts` as disposable first-run state:

```text
Read and use `skills/cyborg/SKILL.md`. Run CYBORG interactively with profile `default` and artifacts under `/tmp/cyborg-artifacts`. Follow `skills/cyborg/references/bridge-protocol.md` through prepare, optional retrieval ingestion, analysis-packet execution, record-result, and Markdown rendering. Display only the renderer output and keep lease contents and protected source payloads out of prompts and logs.
```

Explain that no single `cyborg run` command exists yet; the harness coordinates `prepare`, optional `ingest`, `analysis-packet`, host analysis, `record-result`, and `render`.

- [ ] **Step 4: Verify documentation against the implementation**

Run:

```sh
test -f skills/cyborg/SKILL.md
test -f skills/cyborg/references/bridge-protocol.md
bundle exec ruby bin/cyborg version
env -u CYBORG_CONFIG HOME=/tmp/cyborg-readme-home bundle exec ruby bin/cyborg config path
bundle exec ruby -Itest test/system/support_cli_test.rb
git diff --check -- README.md
```

Expected: both referenced skill files exist; version and config-path commands exit `0`; support CLI tests pass; no whitespace errors.

- [ ] **Step 5: Review and publish**

Show the complete `README.md` diff to the user. After approval, stage only the intended documentation, commit with:

```sh
git add README.md docs/superpowers/plans/2026-08-14-readme-harness-quickstart.md
git commit -m "docs: explain coding harness setup"
```

Then push the current `main` branch to `origin` without staging `Gemfile.lock`.
