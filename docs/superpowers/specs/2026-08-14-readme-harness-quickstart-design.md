# README coding-harness quickstart design

## Goal

Make the repository README sufficient for a first-time operator to initialize CYBORG, understand its credential boundary, and run the application through a coding harness without reading implementation code.

## Scope

Update `README.md` only. Preserve the existing installation, CLI, action, cache, and testing material while reorganizing the first-run path for clarity.

## Content design

1. Keep a copy-and-paste initialization sequence using the bundled fixture source. State that this path is offline and credential-free.
2. Add a credentials section that distinguishes:
   - fixture and local-Git sources, which need no credentials;
   - direct GitHub retrieval, which delegates to the authenticated `gh` CLI session;
   - host-provided analysis, which uses the coding harness session and does not require an LLM API key in CYBORG;
   - environment-injected GitHub tokens for headless use, while prohibiting secrets in TOML, committed `.env` files, prompts, logs, and artifacts.
3. Add a coding-harness section with a provider-neutral copy-and-paste prompt. The prompt instructs the harness to read `skills/cyborg/SKILL.md`, use the bridge protocol, run profile `default`, and use an explicit artifact directory.
4. Explain that CYBORG currently has no single `run` command: the harness coordinates `prepare`, optional `ingest`, `analysis-packet`, analysis, `record-result`, and `render`.
5. Retain a short manual command sequence for debugging and explain that the lease-file path—not its contents—is passed to later commands.

## Safety and correctness

- Do not suggest putting credentials in `config.toml`; the application rejects secret-shaped keys.
- Recommend `gh auth login --hostname github.com --web` and `gh auth status` for interactive GitHub authentication.
- Mention `GH_TOKEN`/`GITHUB_TOKEN` only as externally injected headless alternatives and never show a real token.
- Keep all commands consistent with the current executable and example configuration.

## Verification

- Run the documented fixture setup and CLI bootstrap commands in disposable directories.
- Verify the harness prompt references existing skill/protocol files.
- Run Markdown/diff checks and the relevant support CLI test.
- Commit only the approved README/spec files; leave unrelated worktree changes unstaged.
