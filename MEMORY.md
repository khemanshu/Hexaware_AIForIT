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
  read/edit on the fields a feature's Apex needs via `WITH USER_MODE`. Second example:
  `Account_Health_Management` (KAN-26), granting read/edit on the four Account health-
  tracking fields — a purely metadata (no-Apex) ticket, confirming this pattern applies to
  UI-only field rollouts too, not just Apex-consuming ones. Name new permission sets after
  the feature/capability they grant access to, not the object.
- When a feature needs two access tiers, deliver them as two separate permission sets
  rather than one set with mixed FLS: `VIP_Client_Management` (edit) / `VIP_Client_Read_Only`
  (read-only), both granting FLS on the same field list (KAN-27, `Account.VIP_Tier__c` /
  `Dedicated_Account_Manager__c` / `Special_Handling_Notes__c`). Keeps assignment simple
  (assign one or the other per user/role) instead of relying on profile-layered FLS overrides.

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
- Customer Success health/attrition tracking on Account (KAN-26, metadata-only — no Apex/
  Flow): `Health_Status__c` (restricted Picklist: `Stable`, `At Risk`, `Critical - Churn Risk`)
  is the **controlling** field for `Primary_Risk_Reason__c` (restricted, dependent Picklist:
  `Low Product Adoption`, `Pricing/Budget Constraints`, `Competitor Pressure`, `Support Issues`,
  `Loss of Executive Sponsor` — available only when Health Status is `At Risk` or
  `Critical - Churn Risk`, no values under `Stable`), plus `Last_Health_Assessment_Date__c`
  (Date) and `CSM_Strategic_Notes__c` (LongTextArea, length 32768, visibleLines 6). Confirmed
  against a live check-only deploy: picklist value `fullName`s **may contain a hyphen
  (`Critical - Churn Risk`) or a slash (`Pricing/Budget Constraints`)** — the stricter
  "no hyphens" reading in `platform-custom-field-generate`'s advanced-picklists reference is
  over-conservative for spaced/worded values; only a genuinely invalid leading-digit/no-letter
  name fails. Surfaced on the `Account-Account Layout` page layout in a new "Customer Health"
  section, split across two adjacent `layoutSections` sharing the same `<label>` (first
  `TwoColumnsLeftToRight` with `editHeading=true` for Health Status/Last Assessment Date/
  Primary Risk Reason, second `OneColumn` with `editHeading=false` immediately below for the
  full-width `CSM_Strategic_Notes__c`) — Metadata API `layoutSections` cannot mix column
  layouts within one section, so a "two-column header + full-width sub-area" ask from a TDD
  is modeled as two consecutive sections instead. FLS delivered via a new permission set,
  `Account_Health_Management` (see Permission Sets below). This two-consecutive-sections
  technique (`TwoColumnsLeftToRight` + `editHeading=true`, immediately followed by
  `OneColumn` + `editHeading=false`, both sharing the same `<label>`) was reused in KAN-27
  for the "VIP Client Details" section (Tier/Dedicated Account Manager in the two-column
  header row, `Special_Handling_Notes__c` full-width below) — this is now the established,
  repo-confirmed pattern for "labeled header row + full-width note field" layout asks on
  `Account-Account Layout`, not a one-off.
- VIP client flagging (KAN-27, metadata-only — no Apex/Flow): `VIP_Tier__c` (restricted
  Picklist: `Standard` default, `Gold`, `Platinum`), `Dedicated_Account_Manager__c` (Lookup
  to User), and `Special_Handling_Notes__c` (LongTextArea). A validation rule,
  `Account.VIP_Tier_Requires_Account_Manager`, requires `Dedicated_Account_Manager__c` to be
  populated whenever `VIP_Tier__c` is `Gold` or `Platinum`. FLS delivered via two permission
  sets, `VIP_Client_Management` / `VIP_Client_Read_Only` (see Permission Sets below). This is
  the first `ValidationRule` component tracked in this repo's manifest — see Manifest below
  for the package.xml implication.

## Validation gotcha: AIFORIT org may be missing prior "validated" metadata

- Check-only dry runs are rolled back by design — a ticket passing its dry run does **not**
  mean its metadata was ever actually deployed to the target org. Discovered in KAN-27
  Phase 4: a dry run scoped only to the new KAN-27 files failed because the AIFORIT org
  does not actually have the KAN-26 Account fields (e.g. `Health_Status__c`) that the
  existing `Account-Account Layout` layout references — KAN-26 had only ever been
  check-only validated, never really deployed. When a targeted dry run references
  pre-existing layout/metadata that depends on a prior ticket's fields, widen the dry run's
  scope (or its `--tests`/manifest inputs) to include that prior ticket's metadata too,
  rather than assuming "merged PR" implies "present in the org."

## Manifest

- `manifest/package.xml` uses `<members>*</members>` wildcards for most metadata types
  (ApexClass, LightningComponentBundle, etc.) and lists `CustomField`/`PermissionSet`/
  `Layout` members explicitly. Follow this pattern: add new custom fields/objects as
  explicit `<members>`, rely on the wildcard for class/component types.
- Every metadata **type** new to the manifest needs its own `<types>` block (with `<name>`
  set to the Metadata API type name), not just a new `<members>` entry under an existing
  block — a `<types>` block only ever holds members of the one type named in its `<name>`.
  First surfaced in KAN-27 adding the first `ValidationRule` (`Account.
  VIP_Tier_Requires_Account_Manager`): it required a brand-new `<types><name>ValidationRule
  </name></types>` block, it could not be appended into the existing `CustomField` or
  `PermissionSet` blocks.
- Current manifest API version is `67.0`. `.agentforce-pipeline.yml` still says `66.0` —
  the manifest's own `<version>` is authoritative; do not downgrade `package.xml` to match
  the config file, update the config instead if/when a ticket needs to.

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
