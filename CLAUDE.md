# Salesforce AI DevOps Pipeline — Project Rules

This repo runs an autonomous, human-gated Salesforce delivery pipeline driven from a
Jira ticket down to a validated GitHub Pull Request. The main Claude session acts as
the **orchestrator** and delegates to specialized subagents in `.claude/agents/`.

This is the single source of truth for ticket-work orchestration in this repo. The
`.claude/skills/agentforce-ticket-pipeline` skill is a deprecated stub that points back
here — do not resurrect its old Confluence-only / monolithic flow.

## Config
Load `.agentforce-pipeline.yml` at the start of Phase 1 and bind its keys for the rest of
the ticket: `jira_project`, `github_repo`, `github_default_branch`, `branch_prefix`,
`confluence_space`, `confluence_tech_impl_folder`, `global_manifest`,
`salesforce_api_version`. If the file is missing, ask the user for `jira_project` and
`confluence_space`/`confluence_tech_impl_folder` before proceeding — don't hardcode values.

## Golden rules
- NEVER skip a human confirmation gate. When the protocol says "STOP and wait for
  CONFIRM", stop your turn and wait for the user to type `CONFIRM` before continuing.
- Do exactly one phase per turn. Do not run ahead to later phases.
- Prefer the existing Salesforce skills in `.claude/skills/` for any metadata authoring
  (Apex, Flows, Permission Sets, GenAI prompt templates, etc.). Do not hand-roll code
  that a skill already standardizes.
- Follow the conventions in `MEMORY.md` (enterprise source-of-truth) when it exists.
- All new metadata goes on a feature branch named `{branch_prefix}<TICKET-ID>-<kebab-slug>`
  (e.g. `feature/KAN-22-region-field-on-case`), created on GitHub first (remote), then
  fetched and checked out locally — never branch locally off a stale `main`, and never
  commit to `main`.
- In Phase 4, always dispatch `sf-developer` and `qa-test-writer` in parallel (single turn,
  two `Agent` calls). QA test-scenario drafting is independent of the build/validate loop
  and must never block on it or be skipped.

## The pipeline (invoked via `/work-ticket <TICKET-ID>`)

### Phase 1 — Intake & TDD generation
1. Load `.agentforce-pipeline.yml` (see Config above).
2. Delegate to the `jira-coordinator` subagent to fetch the ticket's title,
   description, and acceptance criteria.
3. Delegate to the `sf-architect` subagent to produce a Technical Design Document
   (TDD) in markdown, cross-referenced against `MEMORY.md`. The architect is
   READ-ONLY — it must not write source files.
4. Present the TDD in chat.
5. **STOP and wait for CONFIRM.**

### Phase 2 — Design-sync gate (Confluence + Jira)
1. Once the user confirms, delegate to `jira-coordinator` to:
   - Create a Confluence page under `{confluence_space}` /
     `{confluence_tech_impl_folder}` (title: `<TICKET-ID> — <summary> — Technical Design`)
     containing the full TDD — this is the durable record.
   - Post a condensed summary plus the Confluence page URL as a comment on the Jira
     issue (audit trail) — do not paste the entire TDD into the Jira comment.
2. Report both URLs, then proceed.

### Phase 3 — Sandbox selection gate
1. Delegate to `sf-developer` to run `sf org list --json` and present the authenticated
   org usernames/aliases.
2. **STOP and wait** for the user to name the target org alias.

### Phase 4 — Build, validate & self-heal
1. Dispatch two subagents in parallel (single turn, two `Agent` tool calls):
   - `sf-developer`: runs the mandatory pre-build repo scan (see its own instructions),
     creates branch `{branch_prefix}<TICKET-ID>-<kebab-slug>` remote-first, generates the
     metadata + Apex tests using the Salesforce skills, and updates `{global_manifest}`.
   - `qa-test-writer`: drafts Test Cases / Test Scenarios from the confirmed TDD and
     acceptance criteria, and posts them as a comment on the Jira issue. Read-only on the
     filesystem/org — its only write is the Jira comment.
2. Once `sf-developer` has generated the metadata, run a check-only, targeted dry run:
   `sf project deploy start --dry-run --test-level RunSpecifiedTests --tests <TestClass> --target-org <alias> --json`
3. Parse the JSON. If compile errors / assertion failures appear, open the failing file,
   fix it, and re-run the dry run. Loop until success.
4. Report the green result and the Jira test-scenarios comment URL from `qa-test-writer`.

### Phase 5 — PR creation
1. Once Phase 4 validation is green and before committing, `sf-developer` updates
   `MEMORY.md` with the enterprise-relevant conventions/decisions from this ticket
   (new components, patterns, gotchas future tickets should know about) — see
   `MEMORY.md` update rules below.
2. `sf-developer` stages, commits (including the `MEMORY.md` update), pushes the
   branch, and opens a PR to `main` via `gh pr create` — so the `MEMORY.md` change
   ships in the same PR as the metadata.
3. Report the PR URL. The GitHub Action in `.github/workflows/` posts the automated
   line-level review.

**`MEMORY.md` update rules:** append/update only durable, reusable facts (new object/field
naming patterns, new Apex/Flow conventions, integration gotchas, architectural decisions)
— not a changelog of what this ticket did. If an existing section already covers the
pattern, update it in place rather than duplicating. Keep entries terse and scoped to
what a future `sf-architect` TDD or `sf-developer` build would need to know.

The pipeline stops here. Deployment to Salesforce after merge is a separate, manual,
out-of-band action — not part of this protocol.

## Model routing
Subagents declare their own model in frontmatter (architect/developer on the
higher-reasoning tier, jira-coordinator on the fast tier, qa-test-writer on the
mid tier). Adjust in each agent file.
