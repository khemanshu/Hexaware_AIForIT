---
name: agentforce-ticket-pipeline
description: "Use this skill whenever the user asks Claude to work on a Jira ticket end-to-end for an Agentforce delivery project. Triggers include: \"work on {KEY}-{n}\", \"start ticket {KEY}-{n}\", \"implement {KEY}-{n}\", \"pick up {KEY}-{n}\", or any instruction to take a Jira ticket through the full development lifecycle — from reading the ticket, drafting a Technical Implementation Plan in Confluence, generating Salesforce metadata, validating against the org, creating a GitHub branch and PR, and finally deploying after merge. Always use this skill when the user references a Jira ticket alongside any development, implementation, or delivery intent, even if they phrase it casually. This skill is project-agnostic — all project-specific constants (Jira project key, GitHub repo, Confluence folders) are loaded from .agentforce-pipeline.yml in the repo root. This skill governs the pipeline orchestration only — delegate actual metadata generation to sf-apex, sf-flow, sf-ai-agentforce, sf-genai-prompt-authoring, sf-metadata, and sf-permissions as needed."
---

# Agentforce Ticket Pipeline (Claude Code Edition, Project-Agnostic)

End-to-end CI/CD workflow for Agentforce delivery projects. Orchestrates six phases —
Discover → Plan → Build → Validate → Ship → Deploy — across Jira, Confluence, Salesforce,
and GitHub. Claude runs all phases autonomously — the user only needs to:
- Confirm which Salesforce org to use (Phase 1)
- Approve the Implementation Plan (Gate 1)
- Review and merge the PR (Gate 2)
- Confirm deployment instruction (Phase 6)

**Environment assumption: this skill runs inside Claude Code, started from the local repo
working directory. There is no sandbox. All file paths are real paths on your machine.**

**Project-agnostic: all project-specific constants live in `.agentforce-pipeline.yml` at
the repo root. The skill itself contains zero hardcoded project identifiers.**

---

## Workspace Constants — loaded from config, NOT hardcoded

Every project-specific value comes from `.agentforce-pipeline.yml` in `REPO_ROOT`.
The skill itself is fully reusable across any number of projects.

### Required config keys

| Key | Example | Description |
|---|---|---|
| `jira_project` | `KAN` | Jira project key — used for ticket references like `{jira_project}-{n}` |
| `github_repo` | `khemanshu/Agentforce-Library` | GitHub `owner/repo` for branch + PR creation |
| `github_default_branch` | `main` | Branch PRs target (default: `main`) |
| `confluence_space` | `KAN` | Confluence space key for both folders |
| `confluence_tech_impl_folder` | `Agentforce Technical Implementation` | Parent folder for Implementation Plans (this skill) |
| `confluence_design_doc_folder` | `Agentforce Design Documents` | Parent folder for Design Documents (sibling skill) |
| `global_manifest` | `manifest/package.xml` | Path (relative to REPO_ROOT) to the global package.xml |
| `agent_manifest_dir` | `manifest/agents/` | Directory for per-agent manifests |
| `branch_prefix` | `feature/` | Prefix for feature branches (default: `feature/`) |
| `salesforce_api_version` | `66.0` | Default API version for new manifests |
| `metadata_root` | `force-app/main/default` | Root folder for Salesforce metadata (default: SFDX standard) |

### Optional config keys

| Key | Example | Description |
|---|---|---|
| `apex_test_level` | `NoTestRun` | Default `apexTestLevel` for `deploy_metadata` |
| `commit_signature` | `🤖 Generated with Claude Code (Hexaware Agentforce Library)` | Footer for commit messages and PR bodies |
| `prerequisites_comment_template` | (string) | Custom template for cross-ticket dependency comments in agent manifests |

### Sample `.agentforce-pipeline.yml`

```yaml
# Project: Hexaware Agentforce Library
jira_project: KAN
github_repo: khemanshu/Agentforce-Library
github_default_branch: main

confluence_space: KAN
confluence_tech_impl_folder: Agentforce Technical Implementation
confluence_design_doc_folder: Agentforce Design Documents

global_manifest: manifest/package.xml
agent_manifest_dir: manifest/agents/
branch_prefix: feature/
salesforce_api_version: "66.0"
metadata_root: force-app/main/default

apex_test_level: NoTestRun
commit_signature: "🤖 Generated with Claude Code (Hexaware Agentforce Library)"
```

---

## Tools Used

| Capability | Tool | Source |
|---|---|---|
| Jira + Confluence | `getJiraIssue`, `createConfluencePage`, `updateConfluencePage`, `addCommentToJiraIssue`, `transitionJiraIssue` | Atlassian Rovo MCP |
| Read files | `Read` | Native Claude Code |
| Find files | `Glob` | Native Claude Code |
| Search inside files | `Grep` | Native Claude Code |
| Surgical edits | `Edit` (or `MultiEdit`) | Native Claude Code |
| Create files | `Write` | Native Claude Code |
| All Git operations | `Bash` running `git` | Native Claude Code |
| GitHub branch + PR | `gh` CLI via `Bash` (preferred), or `create_branch` / `create_pull_request` via GitHub MCP (fallback) | Either |
| Validate + deploy | `deploy_metadata` | Salesforce DX MCP |

---

## Hard Rules (read before every phase)

1. **Two review gates are mandatory hard stops.** Never proceed past Gate 1 (plan approval)
   or Gate 2 (PR merge) without explicit user confirmation.
2. **Always confirm the target Salesforce org at the start of every ticket.** List all
   connected orgs and ask the user which one to use. Use that org for the entire ticket
   unless the user explicitly asks to change it.
3. **Always load `.agentforce-pipeline.yml` first.** If the file does not exist, run the
   bootstrap flow (Phase 0) before doing anything else. Never proceed with hardcoded values.
4. **Validate before committing anywhere.** Files are written to the local repo, validated
   against the org, and only committed + pushed to GitHub after a clean validation.
5. **One clean commit per ticket.** All changed files are staged and committed locally in a
   single commit, then pushed to the remote feature branch. Never commit partial or
   unvalidated work.
6. **Feature branches are created on GitHub first, then checked out locally.** Create the
   branch on the remote from `{github_default_branch}`, then `git fetch && git checkout`
   locally to track it. All subsequent Git work — `add`, `commit`, `push` — happens from
   the local repo.
7. **Never modify files not in scope for the ticket.** Run the pre-build repo scan first,
   assign each file a status (New / Modify / Skip), and only touch files marked New or Modify.
8. **Never create unnecessary files.** Every file written must correspond to a component
   explicitly required by the ticket. No temp files, no test files, no scaffolding.
9. **All post-deploy manual steps** must be captured as a checklist on the PR, mirrored as
   a Jira comment, and added to the Confluence implementation page.
10. **Delegate code generation** to the appropriate skill (sf-apex, sf-flow, sf-ai-agentforce,
    etc.). This skill handles orchestration, naming conventions, and sequencing only.

---

## Phase 0 — Bootstrap (only runs if config is missing)

**Goal:** If `.agentforce-pipeline.yml` does not exist in `REPO_ROOT`, gather the values
from the user and create it. Skip this phase entirely if the file already exists.

### Steps

1. `Bash`: `pwd` → `REPO_ROOT`
2. `Read`: `{REPO_ROOT}/.agentforce-pipeline.yml`
   - If the file exists → skip to Phase 1
   - If the file does not exist → continue
3. Sanity-check the directory looks like an Agentforce repo:
   - `Glob`: `{REPO_ROOT}/sfdx-project.json` (should exist)
   - `Glob`: `{REPO_ROOT}/force-app/**` (should exist)
   - If neither exists, ask the user to confirm they're in the right directory before
     creating any config.
4. Auto-detect what we can:
   - `Bash`: `git remote get-url origin` → derive `github_repo` (parse `owner/repo` from URL)
   - `Bash`: `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'`
     → `github_default_branch`
5. Ask the user the values we cannot detect:
   > "I'll set up `.agentforce-pipeline.yml` for this project. I detected:
   > - github_repo: {detected}
   > - github_default_branch: {detected}
   >
   > Please provide:
   > - jira_project (e.g. KAN, AGENT, SFDC)
   > - confluence_space (usually same as jira_project)
   > - confluence_tech_impl_folder (e.g. 'Agentforce Technical Implementation')
   > - confluence_design_doc_folder (e.g. 'Agentforce Design Documents')
   >
   > Defaults I'll use unless you override: branch_prefix=feature/, manifest paths
   > follow standard SFDX layout, Salesforce API version 66.0."
6. `Write`: `{REPO_ROOT}/.agentforce-pipeline.yml` with the resolved values
7. Suggest the user commit it:
   > "Created `.agentforce-pipeline.yml`. I'd recommend committing this file so teammates
   > inherit it. Run: `git add .agentforce-pipeline.yml && git commit -m 'chore: add agentforce pipeline config'`"
8. Proceed to Phase 1.

---

## Phase 1 — Discover

**Goal:** Read the ticket, confirm the target org, and confirm understanding.

**Steps:**

1. `Bash`: `pwd` — confirm `REPO_ROOT`. (If Phase 0 just ran, this is already done.)
2. `Read`: `{REPO_ROOT}/.agentforce-pipeline.yml` — parse all keys and bind them to
   the variables used throughout the rest of this skill:
   - `JIRA_PROJECT`, `GITHUB_REPO`, `GITHUB_DEFAULT_BRANCH`
   - `CONFLUENCE_SPACE`, `CONFLUENCE_TECH_IMPL_FOLDER`, `CONFLUENCE_DESIGN_DOC_FOLDER`
   - `GLOBAL_MANIFEST`, `AGENT_MANIFEST_DIR`, `BRANCH_PREFIX`
   - `SALESFORCE_API_VERSION`, `METADATA_ROOT`, `APEX_TEST_LEVEL`, `COMMIT_SIGNATURE`
3. Confirm the ticket key matches `JIRA_PROJECT`. If the user said "work on FOO-12" but
   `JIRA_PROJECT=KAN`, stop and ask:
   > "This repo's config is set to Jira project `KAN`, but you referenced `FOO-12`. Did
   > you mean `KAN-12`, or are you in the wrong repo?"
4. Fetch the Jira ticket using `getJiraIssue` with key `{JIRA_PROJECT}-{n}`.
5. Extract: summary, description, acceptance criteria, story points, issue type, linked
   tickets.
6. List all connected Salesforce orgs:
   - `Bash`: `sf org list --json` (or use Salesforce DX MCP `list_all_orgs`)
7. Ask the user:
   > "Here are the connected Salesforce orgs: {list}. Which one should I use for this ticket?"
8. Wait for the user to confirm the org. Store as `ACTIVE_SF_ORG` for all phases.
9. Present a one-paragraph summary in chat confirming ticket understanding. Ask for
   clarification on any ambiguous acceptance criteria before moving on.

---

## Phase 2 — Plan

**Goal:** Produce a Technical Implementation Plan in Confluence and get user approval.

**CRITICAL: The full plan must be written ONLY in Confluence — never in chat.**
The only thing shared in chat is the Confluence page URL and the Gate 1 prompt.

### 2a. Create the Confluence page

Use `createConfluencePage` — write the full plan directly into the page. Do NOT draft in chat.

- **Space:** `{CONFLUENCE_SPACE}`
- **Parent folder:** `{CONFLUENCE_TECH_IMPL_FOLDER}`

> Design Documents (from agentforce-design-doc skill) → parent folder: `{CONFLUENCE_DESIGN_DOC_FOLDER}`
> Technical Implementation Plans (this skill) → parent folder: `{CONFLUENCE_TECH_IMPL_FOLDER}`
> Both always in space: `{CONFLUENCE_SPACE}`

- **Page title:** `{JIRA_PROJECT}-{n} — {ticket summary} — Implementation Plan`
- **Required sections:**

| Section | Contents |
|---|---|
| Overview | One-paragraph summary of what this agent/feature does |
| Salesforce components | Table: Component, Type, Status (New / Modified / Existing-no-change) |
| Data model | Objects, fields, and relationships involved |
| Flow / sequence | Step-by-step execution path (trigger → prompt → Apex → record update → fallback) |
| Grounding strategy | Which Prompt Flow inputs provide context to the LLM |
| Allowed values | Picklist/enum constraints the LLM must respect |
| Error handling | Fault paths, fallback Tasks, partial-success patterns |
| Einstein Trust Layer | ZDR, PII masking requirements |
| Post-deploy manual steps | Anything not deployable via metadata |
| Test plan | Apex test scenarios, Flow manual test cases, Agentforce smoke tests |
| Out of scope | What this ticket explicitly does NOT cover |
| Implementation | Leave blank — populated in Phase 5 |

### 2b. Attach to Jira

Both steps must complete BEFORE presenting Gate 1:
- Add Confluence page URL as a comment on the Jira ticket (`addCommentToJiraIssue`)
- Do NOT transition Jira status yet — ticket stays in its current state until Gate 1 is approved

### Gate 1 — Plan approval (HARD STOP)

Share only the URL in chat:
> "Technical Implementation Plan is ready for review: {Confluence page URL}
> Please review and reply 'approved' when happy to proceed, or let me know what to change."

**Do not proceed to Phase 3 until the user explicitly approves.**
**Do not paste any plan content into chat — the URL is the only output from this phase.**

---

## Phase 3 — Build

**Goal:** Create local branch, write all metadata files, update manifests.

**Transition Jira to `In Progress`** (`transitionJiraIssue`) — this is the signal that
implementation has started, triggered by the user's Gate 1 approval.

### 3a. Create feature branch (remote-first, then local)

```bash
# 1. Sync local default branch with remote
git checkout {GITHUB_DEFAULT_BRANCH}
git pull origin {GITHUB_DEFAULT_BRANCH}
git status                          # confirm clean

# 2. Create the remote branch from {GITHUB_DEFAULT_BRANCH}
gh api repos/{GITHUB_REPO}/git/refs \
  -X POST \
  -f ref="refs/heads/{BRANCH_PREFIX}{JIRA_PROJECT}-{n}-{kebab-slug}" \
  -f sha="$(git rev-parse origin/{GITHUB_DEFAULT_BRANCH})"

# Or, if not using gh CLI: call GitHub MCP `create_branch` with:
#   owner+repo from GITHUB_REPO,
#   branch={BRANCH_PREFIX}{JIRA_PROJECT}-{n}-{kebab-slug},
#   from_branch={GITHUB_DEFAULT_BRANCH}

# 3. Track the new remote branch locally
git fetch origin
git checkout {BRANCH_PREFIX}{JIRA_PROJECT}-{n}-{kebab-slug}
git status                          # confirm tracking origin/...
```

### 3b. Pre-build repo scan (MANDATORY before writing any file)

Reconcile every component in the ticket against what already exists.

```
Glob: {METADATA_ROOT}/classes/**/*.cls
Glob: {METADATA_ROOT}/flows/**/*.flow-meta.xml
Glob: {METADATA_ROOT}/genAiPromptTemplates/**/*.genAiPromptTemplate-meta.xml
Glob: {METADATA_ROOT}/permissionsets/**/*.permissionset-meta.xml
Glob: {METADATA_ROOT}/objects/**/*
```

For cross-references (e.g. "is this Apex class referenced from any Flow?"), use `Grep`:

```
Grep: "CaseAgentTriageJsonParser" in {METADATA_ROOT}/flows/
Grep: "Intelligent_Case_Prioritization" in {METADATA_ROOT}/
```

Then present a file-by-file plan in chat:

| Component | File | Repo Status | Action |
|---|---|---|---|
| `MyPromptTemplate` | `genAiPromptTemplates/MyPromptTemplate...xml` | Not found | **Create** |
| `Intelligent_Case_Prioritization` | `flows/Intelligent_Case_Prioritization...xml` | Exists | **Modify — add scheduled path only** |
| `CaseAgentTriageJsonParser` | `classes/CaseAgentTriageJsonParser.cls` | Exists | **Skip — no changes required** |

**Hard rules:**
- **Skip** files must never be opened, read, or written
- **Modify** files must be read first (`Read`), then patched with `Edit`/`MultiEdit`
- **Create** files are written fresh (`Write`)
- Standard Salesforce fields (e.g. AccountId, ContactId) never need Permission Set FLS entries
- Never add fields to a Permission Set unless those fields were explicitly created in this ticket

### 3c. Generate metadata files

Delegate to the appropriate skill based on component type:

| Component type | Skill to use |
|---|---|
| Apex classes / test classes | `sf-apex` |
| Flows (record-triggered, autolaunched) | `sf-flow` |
| Prompt Templates (Flex, Field Generation) | `sf-genai-prompt-authoring` |
| Agent topics / actions | `sf-ai-agentforce` |
| Custom objects / fields / picklists | `sf-metadata` |
| Permission Sets | `sf-permissions` |

**Conventions always enforced:**
- No `with sharing` on any Apex class
- No `Resolution__c` field — use `Description`
- Allowed Priority picklist: `Low / Medium / High / Critical`
- Allowed Type picklist: `Product Support / Account Support / General / Technical Issue`
- `sanitizeJson()` in any Apex that parses LLM output
- All Apex test classes must cover ≥ 85% with happy-path and error-path scenarios
- Fault connectors on every Flow action call that invokes a prompt or Apex class

### 3d. Write files to local repo

For every file in the plan:

| Action | Tool | Pattern |
|---|---|---|
| **Create** | `Write` | Direct write to the correct path under `REPO_ROOT` |
| **Modify** | `Read` then `Edit` (or `MultiEdit`) | Surgical, pattern-matched edits — no full-file rewrites |
| **Skip** | — | Do nothing |

After writing all files:
- `Glob` the changed directories to confirm files exist
- `Read` 1–2 of the new/modified files as a spot check

### 3e. Update manifests

**Global manifest** (`{GLOBAL_MANIFEST}`):
- `Read` first
- `Edit`: add new `<members>` entries inside the relevant `<types>` block
- Never remove or reorder existing entries

**Agent-specific manifest** (`{AGENT_MANIFEST_DIR}/package-{agent-name}.xml`):
- Filename: kebab-case agent name (e.g. `package-auto-assign-account-and-contact.xml`)
  — NEVER the ticket number (e.g. never `package-{JIRA_PROJECT}-13.xml`)
- Include all components this agent owns or directly uses
- Use `<version>{SALESFORCE_API_VERSION}</version>`
- Add a Prerequisites comment for any cross-ticket dependencies:

```xml
<!--
    Prerequisites (deployed separately — not included in this package):
    - CaseAgentTriageJsonParser (ApexClass) — deployed via {JIRA_PROJECT}-12
-->
```

---

## Phase 4 — Validate

**Goal:** Confirm metadata is deployment-ready — no actual deployment.

### 4a. Run validation

Use `deploy_metadata` Salesforce MCP tool in **validate-only** mode:
- **directory:** `REPO_ROOT`
- **manifest:** `{AGENT_MANIFEST_DIR}/package-{agent-name}.xml`
- **usernameOrAlias:** `ACTIVE_SF_ORG` (confirmed in Phase 1)
- **apexTestLevel:** `{APEX_TEST_LEVEL}` (use `RunSpecifiedTests` only if Apex is in the manifest)
- **checkOnly:** `true`

(Equivalent CLI fallback if MCP fails:
`sf project deploy validate -d {METADATA_ROOT}/.. -x {AGENT_MANIFEST_DIR}/package-{agent-name}.xml -o {ACTIVE_SF_ORG}`)

### 4b. Fix loop

- **0 errors:** proceed to Phase 5
- **Any error:** patch the affected file with `Edit`, re-run validation
- Repeat until clean. Do not proceed to Phase 5 until `numberComponentErrors: 0`

---

## Phase 5 — Ship

**Goal:** Push validated code to GitHub, open PR, annotate all systems.

### 5a. Commit and push (one clean commit)

All Git operations happen via `Bash`. Never push commits through the GitHub MCP — that
bypasses local Git history.

```bash
git status                                              # review changes
git add <files-from-phase-3>                            # stage only ticket files
git diff --staged                                       # sanity check
git commit -m "feat({JIRA_PROJECT}-{n}): {ticket summary}"
git push -u origin {BRANCH_PREFIX}{JIRA_PROJECT}-{n}-{kebab-slug}
```

Stage only the files created or modified in Phase 3. Never `git add .` blindly.

### 5b. Open Pull Request

Either path works:

**Via `gh` CLI (preferred):**
```bash
gh pr create \
  --base {GITHUB_DEFAULT_BRANCH} \
  --head {BRANCH_PREFIX}{JIRA_PROJECT}-{n}-{kebab-slug} \
  --title "feat({JIRA_PROJECT}-{n}): {ticket summary}" \
  --body-file /tmp/pr-body.md
```

**Via GitHub MCP:** call `create_pull_request` with the same fields.

PR body:

```markdown
## Summary
<one paragraph>

## Components
**Modified:** {list}
**New:** {list}
**Unchanged / reused:** {list}
**Manifests:** {GLOBAL_MANIFEST} + {AGENT_MANIFEST_DIR}/package-{agent-name}.xml

## Validation
✅ Validated against `{ACTIVE_SF_ORG}` — 0 errors, 0 test failures

## Test plan
- [ ] Deploy using {AGENT_MANIFEST_DIR}/package-{agent-name}.xml
- [ ] <scenario 1>
- [ ] <scenario 2>
- [ ] Simulate prompt failure — confirm fallback Task created
- [ ] Confirm Einstein Trust Layer: ZDR and PII masking ON

## Post-deploy manual steps ⚠️
- [ ] <step 1>
- [ ] <step 2>

## Confluence
{Confluence page URL}

{COMMIT_SIGNATURE}
```

### 5c. Post comments and update Confluence

- **Jira comment:** PR URL + post-deploy checklist (`addCommentToJiraIssue`)
- **Confluence:** populate the Implementation section with branch, PR URL, validation results,
  components table, post-deploy checklist, key decisions (`updateConfluencePage`)
- **Jira status:** Do NOT transition — ticket stays `In Progress` until PR is merged and
  deployed

### Gate 2 — PR review (HARD STOP)

> "PR is open at {PR URL}. Please review and merge when ready.
> Once merged, tell me to deploy and I will deploy from {GITHUB_DEFAULT_BRANCH}."

**Do not proceed to Phase 6 until the user confirms the PR is merged.**
**Never attempt to merge the PR — that is always the user's action.**

---

## Phase 6 — Deploy

**Goal:** Deploy merged code from default branch to Salesforce.

Triggered only when user says "deploy" / "deploy {JIRA_PROJECT}-{n}" after confirming merge.

### 6a. Sync local repo to default branch

```bash
git checkout {GITHUB_DEFAULT_BRANCH}
git pull origin {GITHUB_DEFAULT_BRANCH}
git status                          # confirm clean and up to date
```

### 6b. Deploy

Use `deploy_metadata` Salesforce MCP tool:
- **directory:** `REPO_ROOT`
- **manifest:** `{AGENT_MANIFEST_DIR}/package-{agent-name}.xml`
- **usernameOrAlias:** `ACTIVE_SF_ORG`
- **apexTestLevel:** `{APEX_TEST_LEVEL}` (or `RunSpecifiedTests` if Apex is in the manifest)

This is an actual deployment (not validate-only) — deploying from `{GITHUB_DEFAULT_BRANCH}`
after merge.

### 6c. Post-deployment actions

1. Jira comment confirming deployment with component org IDs (`addCommentToJiraIssue`)
2. Transition Jira ticket to `Ready for QA` (`transitionJiraIssue`)
3. Update Confluence Implementation section with deployment date and org IDs
4. Remind user of remaining post-deploy manual steps in chat

---

## Tool Reference

| Phase | Action | Tool |
|---|---|---|
| 0 | Bootstrap config (if missing) | `Read` / `Write` / `Bash` |
| 1 | Confirm repo root | `Bash`: `pwd` |
| 1 | Load config | `Read`: `.agentforce-pipeline.yml` |
| 1 | Fetch ticket | Atlassian Rovo: `getJiraIssue` |
| 1 | List orgs | `Bash`: `sf org list --json` (or Salesforce DX MCP) |
| 2 | Create Confluence page | Atlassian Rovo: `createConfluencePage` |
| 2 | Attach URL to Jira | Atlassian Rovo: `addCommentToJiraIssue` |
| 3 | Transition to In Progress | Atlassian Rovo: `transitionJiraIssue` |
| 3 | Sync default branch | `Bash`: `git checkout {default} && git pull` |
| 3 | Create remote branch | `Bash`: `gh api ...` or GitHub MCP `create_branch` |
| 3 | Check out new branch | `Bash`: `git fetch && git checkout <branch>` |
| 3 | Scan repo | `Glob` + `Grep` |
| 3 | Read existing file | `Read` |
| 3 | Modify file | `Edit` / `MultiEdit` |
| 3 | Create file | `Write` |
| 4 | Validate (check-only) | Salesforce DX: `deploy_metadata` (checkOnly) |
| 5 | Stage + commit + push | `Bash`: `git add / commit / push` |
| 5 | Open PR | `Bash`: `gh pr create` or GitHub MCP `create_pull_request` |
| 5 | Post Jira comment | Atlassian Rovo: `addCommentToJiraIssue` |
| 5 | Update Confluence | Atlassian Rovo: `updateConfluencePage` |
| 6 | Sync to default branch | `Bash`: `git checkout {default} && git pull` |
| 6 | Deploy | Salesforce DX: `deploy_metadata` |
| 6 | Post deployment comment | Atlassian Rovo: `addCommentToJiraIssue` |
| 6 | Transition to Ready for QA | Atlassian Rovo: `transitionJiraIssue` |
| 6 | Update Confluence | Atlassian Rovo: `updateConfluencePage` |

---

## Naming Conventions

| Artifact | Pattern | Example |
|---|---|---|
| Branch | `{BRANCH_PREFIX}{JIRA_PROJECT}-{n}-{slug}` | `feature/KAN-13-auto-assign-account-and-contact` |
| PR title | `feat({JIRA_PROJECT}-{n}): {ticket summary}` | `feat(KAN-13): Auto Assign Account and Contact` |
| Confluence page | `{JIRA_PROJECT}-{n} — {summary} — Implementation Plan` | `KAN-13 — Auto Assign Account and Contact — Implementation Plan` |
| Agent manifest | `package-{agent-name}.xml` | `package-auto-assign-account-and-contact.xml` |
| Apex class | `{AgentName}{Function}` (PascalCase) | `CaseAgentTriageJsonParser` |
| Apex test class | `{ClassName}Test` | `CaseAgentTriageJsonParserTest` |
| Flow (trigger) | `{Agent_Name_Snake}` | `Intelligent_Case_Prioritization` |
| Flow (grounding) | `{Object}_Get_{Context}` | `Case_Get_Contact_and_Account_by_Email` |
| Prompt Template | `{Agent_Name_Snake}` | `Case_Get_Matching_Contact_and_Account` |

---

## Jira Status Transitions

| Event | Transition |
|---|---|
| User approves Gate 1 (Implementation Plan) | → `In Progress` |
| Deployment to Salesforce confirmed | → `Ready for QA` |

Never transition to `Done` — that is the QA team's action after testing passes.

---

## Phase Summary Card

```
Phase 0 — Bootstrap  → Only runs if .agentforce-pipeline.yml is missing
                        Auto-detect github_repo + default branch
                        Ask user for jira_project, confluence_*
                        Write config file, recommend committing it

Phase 1 — Discover   → pwd → REPO_ROOT
                        Read .agentforce-pipeline.yml → bind all variables
                        getJiraIssue → fetch ticket
                        sf org list → confirm ACTIVE_SF_ORG with user
                        Confirm understanding in chat

Phase 2 — Plan       → Write full TIP directly to Confluence (never in chat)
                        Attach URL to Jira (no status change yet)
                        *** GATE 1: share URL only, wait for "approved" ***

Phase 3 — Build      → Transition Jira to In Progress
                        git checkout {default} && git pull (sync local)
                        Create remote branch from default (gh api / GitHub MCP)
                        git fetch && git checkout <branch> (track remote)
                        Pre-build repo scan with Glob + Grep
                        Write/modify files with Write / Edit / MultiEdit
                        Update global manifest + create agent manifest

Phase 4 — Validate   → deploy_metadata (checkOnly=true) against ACTIVE_SF_ORG
                        Fix loop with Edit until 0 errors
                        *** Do not proceed until clean ***

Phase 5 — Ship       → git add / commit / push (one clean commit, all via Bash)
                        gh pr create (or GitHub MCP)
                        Jira comment + Confluence Implementation section
                        *** GATE 2: share PR URL, wait for user to merge ***
                        *** Never merge the PR yourself ***

Phase 6 — Deploy     → git checkout {default} && git pull (sync merged PR)
                        deploy_metadata from agent manifest (actual deploy)
                        Jira comment + Ready for QA + Confluence update
                        Remind user of post-deploy manual steps
```

---

## Migration Notes

If you're moving from the project-specific Claude Code skill (single-repo, hardcoded
constants), here's what changed and why:

1. **Removed: hardcoded `JIRA_PROJECT`, `GITHUB_REPO`, `CONFLUENCE_*`, `LOCAL_REPO_PATH`.**
   These now come from `.agentforce-pipeline.yml` per project.
2. **Removed: `LOCAL_REPO_PATH` entirely.** `REPO_ROOT` is whatever directory Claude Code
   was launched from. No paths baked into the skill.
3. **Added: Phase 0 — Bootstrap.** Auto-creates the config file the first time the skill
   runs in a project. Auto-detects what it can (`github_repo`, default branch) and asks for
   the rest (Jira project, Confluence folders).
4. **Added: ticket-key sanity check in Phase 1.** If the user references `FOO-12` but the
   config says `JIRA_PROJECT=KAN`, the skill stops and asks rather than silently failing.
5. **Added: `metadata_root` config key.** Defaults to `force-app/main/default` (SFDX
   standard) but allows non-standard repo layouts.
6. **Kept identical:** Atlassian Rovo MCP, Salesforce DX MCP, both review gates, all naming
   conventions, all Jira transitions, the Confluence page structure, the PR template.

### Adopting in an existing project

For each Agentforce project repo where you want to use this skill:

```bash
cd <project-repo>
# Either let the skill bootstrap on first run (Phase 0), or create manually:
cat > .agentforce-pipeline.yml <<'YAML'
jira_project: KAN
github_repo: khemanshu/Agentforce-Library
github_default_branch: main
confluence_space: KAN
confluence_tech_impl_folder: Agentforce Technical Implementation
confluence_design_doc_folder: Agentforce Design Documents
global_manifest: manifest/package.xml
agent_manifest_dir: manifest/agents/
branch_prefix: feature/
salesforce_api_version: "66.0"
metadata_root: force-app/main/default
apex_test_level: NoTestRun
commit_signature: "🤖 Generated with Claude Code (Hexaware Agentforce Library)"
YAML
git add .agentforce-pipeline.yml
git commit -m "chore: add agentforce pipeline config"
```

This project keeps the skill in-repo at `.claude/skills/agentforce-ticket-pipeline/SKILL.md`
so it's version-controlled and shared with every teammate who clones the repo — no per-machine
install step required. (The skill content is otherwise project-agnostic and portable to
`~/.claude/skills/` for use across repos if you prefer a user-level install instead.)
