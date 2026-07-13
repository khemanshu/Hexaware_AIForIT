# MEMORY.md — Enterprise Source-of-Truth

Read by `sf-architect` (Phase 1 TDD) and `sf-developer` (Phase 4 build) on every ticket, per
[CLAUDE.md](CLAUDE.md). Update this file as real conventions get established in this repo —
do not add rules that aren't backed by something actually in `force-app/` or an explicit team
decision.

## Apex conventions

- Use `with sharing` on new Apex classes unless a ticket has a specific, documented reason
  to run in system context. This repo's own code-generation templates
  (`.claude/skills/platform-apex-generate/assets/*.cls`) consistently default to `with sharing`.
- No project Apex classes exist in `force-app/` yet — there is no established naming or
  layering convention (Service/Selector/Domain) to enforce beyond what the
  `platform-apex-generate` skill already provides. `sf-architect` should default to that
  skill's patterns rather than inventing new ones.

## Case object

- `Case.Region__c` (Text, 255, not required, not unique) was added in KAN-22 — the only
  custom field on Case so far. No customization exists yet for `Priority`, `Type`, or a
  `Resolution` field; don't assume fixed picklist values or a `Resolution__c` field until a
  ticket actually introduces them.

## Manifest

- `manifest/package.xml` uses `<members>*</members>` wildcards for most metadata types
  (ApexClass, LightningComponentBundle, etc.) and lists `CustomField` members explicitly
  (currently just `Case.Region__c`). Follow this pattern: add new custom fields/objects as
  explicit `<members>`, rely on the wildcard for class/component types.
- Current manifest API version is `67.0`. `.agentforce-pipeline.yml` still says `66.0` —
  treat the manifest's actual version as authoritative until the config is updated.

## Notes on migrated conventions

A prior version of the (now-retired) `agentforce-ticket-pipeline` skill hardcoded several
rules inherited from a different project (`Agentforce-Library`): banning `with sharing`,
banning a `Resolution__c` field in favor of `Description`, fixed `Priority`/`Type` picklist
values, a mandatory `sanitizeJson()` helper, an 85% Apex coverage floor, and mandatory Flow
fault connectors. None of these were verifiable against this repo's actual state — the
`with sharing` ban directly contradicted this repo's own code templates, and there's no
Resolution or Priority/Type customization to ban or constrain. They were deliberately **not**
carried forward. Add them back here individually, with justification, if/when they become
real decisions for this project.
