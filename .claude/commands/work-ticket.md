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
