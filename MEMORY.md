# MEMORY.md — Enterprise Source-of-Truth

Read by `sf-architect` (Phase 1 TDD) and `sf-developer` (Phase 4 build) on every ticket, per
[CLAUDE.md](CLAUDE.md). Update this file as real conventions get established in this repo —
do not add rules that aren't backed by something actually in `force-app/` or an explicit team
decision.

## Apex conventions

- Use `with sharing` on new Apex classes unless a ticket has a specific, documented reason
  to run in system context. This repo's own code-generation templates
  (`.claude/skills/platform-apex-generate/assets/*.cls`) consistently default to `with sharing`.
- Layering convention (established KAN-24, first trigger stack in this repo): `Trigger` →
  `TriggerHandler` (routes before/after contexts) → `Service` (orchestrates SOQL/DML,
  bulkified) → `Domain` (pure in-memory field derivation, no SOQL/DML) → `Selector`
  (encapsulates all SOQL for the object, `inherited sharing`, enforces FLS/CRUD via
  `WITH USER_MODE`). This repo has **no TAF** (`Trigger_Action__mdt` / metadata-driven
  trigger framework) — single-trigger tickets should default to this Custom Handler
  pattern rather than introducing TAF, unless/until a ticket explicitly needs multiple
  independently-orderable actions per object.
- Recursion guard convention: a `private static Boolean` flag (e.g. `isReconciling`) on
  the `TriggerHandler` class, set to `true` immediately before dispatching after-context
  service logic and reset to `false` in a `finally` block. Check the flag at the top of
  every handler method (including before-context ones, if the service's own compensating
  DML could re-trigger field derivation) to short-circuit recursive invocations caused by
  the service's own DML re-firing the trigger.
- `WITH USER_MODE` selectors require the running user to actually have the FLS-granting
  permission set assigned *before* the transaction starts — assigning a permission set to
  the currently-running user mid-test does not refresh that user's cached FLS state. Test
  classes exercising FLS-gated selectors must create a dedicated test user (in
  `@testSetup`) with the permission set pre-assigned, and wrap test bodies in
  `System.runAs(testUser)`.
- `DateTime` fields persist at whole-second precision — do not rely on sub-second
  offsets for deterministic same-transaction tie-breaks (e.g. "most recently stamped wins"
  logic). Use a secondary sort key instead, such as `Id DESC` in the selector's `ORDER BY`,
  since record Ids are monotonically increasing with insert/update order.
- Lookup fields with `deleteConstraint=SetNull` are cleared by the platform *before* the
  corresponding trigger's `after delete` context runs its own queries. Code that needs the
  pre-delete value (e.g. fallback/reconciliation logic after a parent's referenced child is
  deleted) must capture it from `Trigger.old` up front and pass it through explicitly — it
  cannot be recovered by re-querying the parent afterward.

## Validation gotcha: check-only deploys and brand-new fields

- A check-only/dry-run deploy (`sf project deploy start --dry-run`) cannot validate Apex
  tests that query brand-new custom fields introduced in the same deployment — the schema
  isn't provisioned within the rolled-back validation transaction even though Apex compiles
  clean against it. If a ticket's tests need to query new fields, those fields must be
  deployed for real (schema-only, human-authorized exception to normal check-only
  validation) before the check-only test-validation dry run will succeed. Apex/triggers/
  tests themselves still go through the org's normal (non-check-only) deployment process
  after PR review — only the schema is deployed early, and only with explicit user
  authorization.

## Permission Sets

- Permission Sets (not Profile edits) are the standard mechanism for delivering FLS on new
  custom fields. First example: `Primary_Contact_Management` (KAN-24), granting
  read/edit on the fields a feature's Apex needs via `WITH USER_MODE`. Name new permission
  sets after the feature/capability they grant access to, not the object.

## Case object

- `Case.Region__c` (Text, 255, not required, not unique) was added in KAN-22 — the only
  custom field on Case so far. No customization exists yet for `Priority`, `Type`, or a
  `Resolution` field; don't assume fixed picklist values or a `Resolution__c` field until a
  ticket actually introduces them.

## Account / Contact objects

- `Account.Primary_Contact__c` (Lookup to Contact, `deleteConstraint=SetNull`),
  `Contact.Is_Primary__c` (Checkbox), and `Contact.Primary_Marked_Date__c` (DateTime) were
  added in KAN-24 to auto-sync each Account's designated primary Contact. Maintained by
  `ContactTrigger` → `ContactTriggerHandler` → `ContactPrimaryContactService` (see Apex
  conventions above for the layering/recursion-guard/tie-break patterns this introduced).

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
