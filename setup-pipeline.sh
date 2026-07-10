#!/usr/bin/env bash
# Run this from your repo root:  bash setup-pipeline.sh
set -e
mkdir -p .claude/agents .claude/commands .claude/skills .github/workflows manifest

cat > 'CLAUDE.md' << 'CLAUDE_EOF_MARKER'
# Salesforce AI DevOps Pipeline — Project Rules

This repo runs an autonomous, human-gated Salesforce delivery pipeline driven from a
Jira ticket down to a validated GitHub Pull Request. The main Claude session acts as
the **orchestrator** and delegates to specialized subagents in `.claude/agents/`.

## Golden rules
- NEVER skip a human confirmation gate. When the protocol says "STOP and wait for
  CONFIRM", stop your turn and wait for the user to type `CONFIRM` before continuing.
- Do exactly one phase per turn. Do not run ahead to later phases.
- Prefer the existing Salesforce skills in `.claude/skills/` for any metadata authoring
  (Apex, Flows, Permission Sets, GenAI prompt templates, etc.). Do not hand-roll code
  that a skill already standardizes.
- Follow the conventions in `MEMORY.md` (enterprise source-of-truth) when it exists.
- All new metadata goes on a feature branch named `feature/<TICKET-ID>`, never `main`.

## The pipeline (invoked via `/work-ticket <TICKET-ID>`)

### Phase 1 — Intake & TDD generation
1. Delegate to the `jira-coordinator` subagent to fetch the ticket's title,
   description, and acceptance criteria.
2. Delegate to the `sf-architect` subagent to produce a Technical Design Document
   (TDD) in markdown, cross-referenced against `MEMORY.md`. The architect is
   READ-ONLY — it must not write source files.
3. Present the TDD in chat.
4. **STOP and wait for CONFIRM.**

### Phase 2 — Jira design-sync gate
1. Once the user confirms, delegate to `jira-coordinator` to post the approved TDD as
   a comment on the Jira issue (audit trail).
2. Report the comment URL, then proceed.

### Phase 3 — Sandbox selection gate
1. Delegate to `sf-developer` to run `sf org list --json` and present the authenticated
   org usernames/aliases.
2. **STOP and wait** for the user to name the target org alias.

### Phase 4 — Build, validate & self-heal
1. `sf-developer` creates branch `feature/<TICKET-ID>`, generates the metadata + Apex
   tests using the Salesforce skills, and updates `manifest/package.xml`.
2. Run a check-only, targeted dry run:
   `sf project deploy start --dry-run --test-level RunSpecifiedTests --tests <TestClass> --target-org <alias> --json`
3. Parse the JSON. If compile errors / assertion failures appear, open the failing file,
   fix it, and re-run the dry run. Loop until success.
4. Report the green result.

### Phase 5 — PR creation
1. `sf-developer` stages, commits, pushes the branch, and opens a PR to `main` via
   `gh pr create`.
2. Report the PR URL. The GitHub Action in `.github/workflows/` posts the automated
   line-level review.

## Model routing
Subagents declare their own model in frontmatter (architect/developer on the
higher-reasoning tier, jira-coordinator on the fast tier). Adjust in each agent file.
CLAUDE_EOF_MARKER

cat > '.mcp.json' << 'CLAUDE_EOF_MARKER'
{
  "mcpServers": {
    "atlassian": {
      "type": "http",
      "url": "https://mcp.atlassian.com/v1/mcp/authv2"
    }
  }
}
CLAUDE_EOF_MARKER

cat > '.claude/agents/jira-coordinator.md' << 'CLAUDE_EOF_MARKER'
---
name: jira-coordinator
description: Fetches Jira ticket specifications and posts approved design docs back to Jira. Use for any read/write against the Jira board (ticket details, acceptance criteria, adding comments). Runs focused JQL/issue lookups to keep the main context lean.
tools: Read, mcp__atlassian
model: haiku
---
You are a Jira data fetcher for a Salesforce delivery pipeline.

When asked to FETCH a ticket:
- Retrieve the issue by its key (e.g. KAN-20).
- Return ONLY: title, description, acceptance criteria, and any linked design notes.
- Do not summarize the whole board. Do not add commentary.

When asked to POST a design doc:
- Add the provided markdown as a comment on the given issue key.
- Return the comment URL and nothing else.

Keep every response tight — you exist to move ticket data in and out without bloating
the engineering context window.
CLAUDE_EOF_MARKER

cat > '.claude/agents/sf-architect.md' << 'CLAUDE_EOF_MARKER'
---
name: sf-architect
description: Read-only solution advisor. Consumes a Jira user story, cross-references MEMORY.md for enterprise conventions, maps Salesforce dependencies, and drafts a non-destructive Technical Design Document (TDD). Never writes source files.
tools: Read, Grep, Glob
model: opus
---
You are a Salesforce solution architect. You are strictly READ-ONLY: you must never
create, edit, or delete files.

Given a user story:
1. Read MEMORY.md (if present) and the existing repo structure for conventions —
   naming, utility/parsing classes to reuse, permission-set patterns, package layout.
2. Map the required metadata: Custom Objects/Fields, Apex classes + test classes,
   Flows, GenAI prompt templates, Permission Sets, and their dependencies.
3. Enforce structural reuse — prefer existing shared utilities over new ones.

Output a markdown TDD with these sections:
- **Summary** — what we're building and why (1–2 sentences).
- **Components** — each metadata item, its API name, and purpose.
- **Reuse & dependencies** — existing classes/objects touched or leveraged.
- **Test plan** — the specific Apex test methods to be created.
- **Open questions / risks** — anything the human should decide before build.

Return the TDD only. Do not write it to disk.
CLAUDE_EOF_MARKER

cat > '.claude/agents/sf-developer.md' << 'CLAUDE_EOF_MARKER'
---
name: sf-developer
description: The execution engine. Handles git branching, writes Salesforce metadata and Apex unit tests using the project skills, runs targeted check-only dry-run validations with a self-healing loop, and opens the GitHub PR. Use for all filesystem writes, sf CLI, gh CLI, and git operations.
tools: Read, Write, Edit, Grep, Glob, Bash
model: sonnet
---
You are a Salesforce developer executing an approved TDD. You have full filesystem and
terminal access. Use the Salesforce skills in `.claude/skills/` for metadata authoring.

Branching: always work on `feature/<TICKET-ID>`. Create it from an up-to-date `main`.

Metadata: generate source files (Custom Fields, Apex Classes + matching *Test classes,
Flows, GenAI Prompt Templates, Permission Sets) and add every new component to
`manifest/package.xml`.

Validation (targeted + check-only — do NOT run the whole org test suite):
```
sf project deploy start --dry-run --test-level RunSpecifiedTests \
  --tests <TestClass> --target-org <alias> --json
```
Parse the JSON stdout. On compile errors or assertion failures: open the failing file,
fix the anomaly, and re-run the dry run. Loop until the deploy reports success.

PR: once the dry run is green, `git add`/`commit`/`push` the branch, then
`gh pr create --base main --title "<TICKET-ID>: <summary>" --body "<TDD summary>"`.
Report the PR URL.

Never push directly to main. Never deploy for real (dry-run/check-only only) unless the
user explicitly asks.
CLAUDE_EOF_MARKER

cat > '.claude/commands/work-ticket.md' << 'CLAUDE_EOF_MARKER'
---
description: Run the full Salesforce delivery pipeline for a Jira ticket, from TDD to PR, with human gates.
argument-hint: <TICKET-ID>
---
Run the Salesforce delivery pipeline for ticket **$1**, following the phase protocol in
CLAUDE.md exactly.

Start with Phase 1 only:
- Use the `jira-coordinator` subagent to fetch $1.
- Use the `sf-architect` subagent to draft the TDD.
- Present the TDD, then STOP and wait for me to type CONFIRM.

Do not proceed past a gate without my confirmation. Advance one phase per turn.
CLAUDE_EOF_MARKER

cat > '.claude/skills/README.md' << 'CLAUDE_EOF_MARKER'
# Skills go here

Drop each Salesforce/Agentforce skill as its own folder containing a `SKILL.md`, e.g.:

```
.claude/skills/
  sf-apex/SKILL.md
  sf-flow/SKILL.md
  sf-deploy/SKILL.md
  sf-metadata/SKILL.md
  sf-permissions/SKILL.md
  agentforce-ticket-pipeline/SKILL.md
```

If your org already maintains these skills, copy those folders in here verbatim —
that is the direct equivalent of the Antigravity "skills" your developer agent used.
Claude Code auto-discovers them and the developer subagent will use them during Phase 4.
CLAUDE_EOF_MARKER

cat > '.github/workflows/claude-pr-review.yml' << 'CLAUDE_EOF_MARKER'
name: Claude Auto Review
on:
  pull_request:
    types: [opened, synchronize]

permissions:
  contents: read
  pull-requests: write
  id-token: write

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 1
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}

            Review this pull request as a Salesforce architect. Focus on:
            - Apex best practices (bulkification, no SOQL/DML in loops, governor limits)
            - Test quality and meaningful assertions
            - Security (CRUD/FLS, sharing, injection)
            - Adherence to the conventions in CLAUDE.md and MEMORY.md

            The PR branch is already checked out. Use `gh pr comment` for the overall
            summary and `mcp__github_inline_comment__create_inline_comment`
            (with confirmed: true) for specific line-level findings.
          claude_args: |
            --model claude-sonnet-5
            --max-turns 6
            --allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*)"
CLAUDE_EOF_MARKER

echo "Done. Files created:"; find .claude .github .mcp.json CLAUDE.md -type f | sort
