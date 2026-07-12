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
- In Phase 4, always dispatch `sf-developer` and `qa-test-writer` in parallel (single turn,
  two `Agent` calls). QA test-scenario drafting is independent of the build/validate loop
  and must never block on it or be skipped.

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
1. Dispatch two subagents in parallel (single turn, two `Agent` tool calls):
   - `sf-developer`: creates branch `feature/<TICKET-ID>`, generates the metadata + Apex
     tests using the Salesforce skills, and updates `manifest/package.xml`.
   - `qa-test-writer`: drafts Test Cases / Test Scenarios from the confirmed TDD and
     acceptance criteria, and posts them as a comment on the Jira issue. Read-only on the
     filesystem/org — its only write is the Jira comment.
2. Once `sf-developer` has generated the metadata, run a check-only, targeted dry run:
   `sf project deploy start --dry-run --test-level RunSpecifiedTests --tests <TestClass> --target-org <alias> --json`
3. Parse the JSON. If compile errors / assertion failures appear, open the failing file,
   fix it, and re-run the dry run. Loop until success.
4. Report the green result and the Jira test-scenarios comment URL from `qa-test-writer`.

### Phase 5 — PR creation
1. `sf-developer` stages, commits, pushes the branch, and opens a PR to `main` via
   `gh pr create`.
2. Report the PR URL. The GitHub Action in `.github/workflows/` posts the automated
   line-level review.

## Model routing
Subagents declare their own model in frontmatter (architect/developer on the
higher-reasoning tier, jira-coordinator on the fast tier, qa-test-writer on the
mid tier). Adjust in each agent file.
