---
name: agentforce-ticket-pipeline
description: "Use this skill whenever the user asks Claude to work on a Jira ticket end-to-end for an Agentforce delivery project. Triggers include: \"work on {KEY}-{n}\", \"start ticket {KEY}-{n}\", \"implement {KEY}-{n}\", \"pick up {KEY}-{n}\", or any instruction to take a Jira ticket through the full development lifecycle. Always use this skill when the user references a Jira ticket alongside any development, implementation, or delivery intent, even if they phrase it casually."
---

# Agentforce Ticket Pipeline — deprecated stub

**Do not execute the flow that used to live in this file.** As of the CLAUDE.md /
agentforce-ticket-pipeline merge, [CLAUDE.md](/CLAUDE.md) is the single source of truth for
ticket-work orchestration in this repo.

When this skill is triggered:

1. Do not create Confluence pages as the primary/only design-doc destination, do not run a
   monolithic inline flow, and do not add a post-merge deploy phase — none of that applies
   here anymore.
2. Instead, follow the phase protocol in `CLAUDE.md` exactly, starting at Phase 1, one phase
   per turn, stopping at every `STOP and wait for CONFIRM` gate. This mirrors what
   `.claude/commands/work-ticket.md` (the `/work-ticket` slash command) already does.
3. Use the subagents in `.claude/agents/` (`jira-coordinator`, `sf-architect`, `sf-developer`,
   `qa-test-writer`) exactly as CLAUDE.md's Golden Rules describe — do not run the work
   inline in the main session.

This stub exists only to keep the natural-language trigger phrasing ("work on KAN-30",
"pick up KAN-30") working without duplicating — and risking drift from — the real protocol
in CLAUDE.md. See `MEMORY.md` for this repo's actual coding conventions (the previous
version of this file hardcoded conventions from a different project — those were removed).
