# PS / SOW Quoting — Architecture

A ProServ / staffing quoting UI for Revenue Cloud orgs. The builder sits on the Quote record page. The
weekly staffing ramp is an **estimate**; each resource is quoted once as a $0 monthly line and billed on
**actual hours** (usage) at the negotiated hourly rate.

## 1. Why this design
Writing the weekly ramp back to the quote created **one QuoteLineItem (and later one Asset) per
resource per week**, so a 2-phase/2-week quote produced ~20 lines / ~30 assets. Activation then
generated **term billing schedules for every zeroed weekly line AND usage schedules** — double
billing. Zeroing the term net prices by DML also dirtied `Order.ValidationResult` and blocked
activation. Root fix: stop ramping the quote; keep the ramp as an estimate and quote each resource
once.

## 2. Target model
- The weekly ramp is an **LWC-only estimate**. It is persisted in a child object
  **`PS_Estimate_Segment__c`** (one row per resource-week: `Quote__c`, `QuoteLineItem__c`, `Product__c`,
  `Resource_Slot__c`, `Phase__c`, `PhaseStartDate__c`, `WeekIndex__c`, `Hours__c`, `Rate__c`, `Cost__c`) so
  the builder can rebuild the grid when the quote is opened again.
- **Resource slots.** The Nth copy of a role within a phase is **slot N** of that role; the same role +
  slot in every phase is treated as the same person. A role therefore gets as many lines as its highest
  count in any single phase: a PM in Design and UAT is 1 line, 4 Implementation Engineers in Build are
  4 lines (if Design also had 2, those are slots 1-2 and continue into Build). When a role has more than
  one slot, each line's `Description` is labeled `"<Role> #N"`. All slots of a role share the role's
  single negotiated rate.
- Each resource slot is quoted as **one `QuoteLineItem`** on the role's **Term Monthly** selling model
  (`PricingTermUnit='Months'`) at **`UnitPrice = 0`, `Quantity = 1`**, spanning the engagement
  (`StartDate` = earliest phase start, `EndDate` = latest phase end), `BillingFrequency='Monthly'`.
  This $0 term aligns with consumption billing instead of competing with it.
- The negotiated hourly rate is written to **`QuoteLineRateCardEntry.NegotiatedRate`** (one entry per
  line, `RateCardEntryId` = the role's Negotiable Base `PS_LABOR_HOURS` entry) — the usage rate override.
  It is also mirrored to reference custom fields `QuoteLineItem.Negotiated_Rate__c` / `Estimated_Hours__c`
  (not used by any pricing procedure).
- Conversion uses the **native** `createOrderFromQuote` action, which carries
  `QuoteLineRateCardEntry.NegotiatedRate` to `OrderItemRateCardEntry.NegotiatedRate` automatically. No
  conversion Apex/flow.

```
psQuoteBuilder on the Quote record page (weekly ramp = estimate only)
  -> PsQuoteService.build:
       - 1 QuoteLineItem per resource slot (Term Monthly, UnitPrice 0, Qty 1, engagement dates) via Connect place
       - QuoteLineRateCardEntry.NegotiatedRate = negotiated rate (per line)
       - QLI custom fields Negotiated_Rate__c / Estimated_Hours__c
       - Quote profitability fields (PS_Estimated_Revenue__c / Cost / Margin / Margin_Pct, PS_Cost_Book_Name__c)
       - PS_Estimate_Segment__c rows (full ramp) for reload
       - reprice the quote (so it is order-ready)
  -> native "Create Order from Quote"  ->  Order + OrderItems + OrderItemRateCardEntry (negotiated rate carried)
     -> activate -> 1 asset per resource + one $0 monthly schedule + one usage schedule per resource
```

**Reprice seam:** inserting `QuoteLineRateCardEntry` / updating line custom fields by DML leaves
`LastPricedDate` behind the line edits, so `createOrderFromQuote` rejects with "prices aren't updated".
`PsQuoteService.build` ends with a **System reprice** (place PATCH on the quote) so the quote is
order-ready. `IsChosenRate` is REST-only (not Apex-writable) but is unnecessary with one entry per line.

## 3. Components
- [PsQuoteController.cls](../force-app/main/default/classes/PsQuoteController.cls) — LWC endpoints. Role
  discovery via products with a `PS_LABOR_HOURS` Base `RateCardEntry`, anchored on the Term Monthly PBE
  (`searchRoles`); `getRoleEconomics` (cost + list rate + target margin); `getQuoteEstimate` rebuilds the
  estimate from `PS_Estimate_Segment__c` (grouped by role + slot; rows without a slot load as slot 1);
  `buildQuote` / `repriceQuote`.
- [PsQuoteService.cls](../force-app/main/default/classes/PsQuoteService.cls) — build (consolidate by slot, place
  $0 monthly lines, rate override, custom fields, estimate rows, reprice) via same-org Connect REST callouts.
- [PsCostBook.cls](../force-app/main/default/classes/PsCostBook.cls) — resolves the cost book at runtime
  (`PS_Quote_Settings__mdt.Default.Cost_Book_Name__c`, else the org's default `CostBook`) and per-role hourly
  costs from `CostBookEntry`.
- `PS_Quote_Settings__mdt` (`Default` record) — `Cost_Book_Name__c` (blank = use the default cost book) and
  `Target_Margin_Pct__c`.
- [psQuoteBuilder](../force-app/main/default/lwc/psQuoteBuilder) — the estimate grid; Quote record page only.
- [PS_Quote_Record_Page](../force-app/main/default/flexipages/PS_Quote_Record_Page.flexipage-meta.xml) — Quote
  record page hosting the builder. It uses RLM template fields (`RLM_Approval_Level__c`,
  `RLM_Approval_Status__c`, `RLM_Payment_Terms__c`, `RLM_TermMonths__c`) and Revenue Cloud / Approvals
  components, so the target org must have them. Its header actions are limited to `Quote.RLM_Create_Proposal`,
  `Quote.RLM_Submit_for_Approval`, and standard actions; org-specific actions (e.g.
  `RLM_Create_Ramp_Schedule_V4`, `RLM_CreateContract`) are not shipped by the RLM template and break the deploy.
- [psRoleLookup](../force-app/main/default/lwc/psRoleLookup) — role type-ahead used inside the builder.
- [PsSessionId.page](../force-app/main/default/pages/PsSessionId.page) — Lightning sessions can't make REST
  callouts (HTTP 401); this page exposes an API-enabled session id for `PsQuoteService`.
- [PsRevCloudSelf](../force-app/main/default/remoteSiteSettings/PsRevCloudSelf.remoteSite-meta.xml) — Remote
  Site Setting for the same-org callout.
- `PS_Estimate_Segment__c` object/fields; `QuoteLineItem.Negotiated_Rate__c` / `Estimated_Hours__c`;
  Quote `PS_*` profitability fields; `PS_Quote_Builder` permission set.

## 4. Org prerequisites
Deploying the metadata is not enough; the builder depends on per-org Revenue Cloud data and one per-org
metadata value.

### 4.1 Before deploying
- **Remote Site Setting URL.** `PsRevCloudSelf.remoteSite-meta.xml` contains the source org's My Domain
  URL. Change `<url>` to the target org's My Domain URL (`https://<mydomain>.my.salesforce.com`) before each
  deploy, or the build callouts fail. The agent sets this automatically from `sf org display` before each
  deploy, and the post-install check redeploys it if it doesn't match.
- **API version.** `PsQuoteService.API_VERSION` (currently `v68.0`) must be supported by the target org.
- **Re-retrieving or editing the record page.** If `PS_Quote_Record_Page` is retrieved again from a dev
  org, or edited in Lightning App Builder, check it before committing: a fresh org rejects header actions
  that only exist in the dev org (e.g. `Quote.RLM_CreateContract`, `Quote.RLM_Create_Ramp_Schedule_V4`:
  "We couldn't validate Quick Action …") and Work Guide properties from newer Orchestrator releases
  (`isAutoAdvanceToNextWorkItem`). The deploy is atomic, so either error rolls back everything.
- **Validate first.** Run the deploy with `--dry-run` before the real deploy to catch these errors without
  changing the org.
- **Run the tests explicitly.** Trial and Developer Edition orgs may skip Apex tests during the deploy. Run
  `sf apex run test --class-names PsQuoteControllerTest --code-coverage --target-org "<orgUsername>"`
  afterwards.

### 4.2 Usage facts (how "usage-based" works in RLM)
- `ProductSellingModel.SellingModelType` has only **`OneTime` / `TermDefined` / `Evergreen`** — there is
  **no `UsageBased` selling model.**
- Usage behavior comes from **`Product2.UsageModelType`** (`Anchor` for staffing roles). A usage product
  still carries a normal selling model (here **Term Monthly**) plus a `PricebookEntry`.
- The **per-unit usage rate lives on `RateCardEntry.Rate`**, not on `PricebookEntry.UnitPrice`.
- `RateCardEntry.RateNegotiation = 'Negotiable'` is what allows the quoted rate to override the base rate.

### 4.3 Data the builder needs (per org)

| Object | Role for staffing | Key fields |
| --- | --- | --- |
| `UnitOfMeasure` (+ `UnitOfMeasureClass`) | "Hour" in a Time class | the metered unit |
| `UsageResource` | **"PS Labor Hours"** | `Code = 'PS_LABOR_HOURS'` (the builder finds roles by this code) |
| `Product2` (each role) | the sellable role | `UsageModelType = 'Anchor'` |
| `ProductSellingModel` + `PricebookEntry` | quote-line anchor | active **Term Monthly** (`TermDefined`, `PricingTermUnit='Months'`) PBE on the Standard Price Book |
| `ProductUsageResource` (PUR) | links role -> Labor Hours | |
| `ProductUsageGrant` (PUG) | included allowance | 0 included = pure pay-per-use |
| `RateCard` (`Type=Base`) + `PriceBookRateCard` | pricing container on the Standard PB | `PriceBookRateCard` field is `PriceBookId` |
| `RateCardEntry` | **per-role hourly rate** | `Product`, `UsageResource`, `Rate`=hourly, `RateUnitOfMeasure`=USD (Currency class; the resource's default unit is Hour), `RateNegotiation='Negotiable'`, `Status='Active'`, `EffectiveFrom` |
| `CostBook` + `CostBookEntry` (optional) | hourly cost per role for margin | `CostBookEntry.Cost` = hourly cost, effective now; book is the default or named in `PS_Quote_Settings.Default` |

Setup learnings:
- Activation order matters (UoM classes -> UoMs -> UsageResources -> PURs -> PUGs -> RateCardEntry);
  activating out of order throws validation errors.
- Usage records insert as **`Draft`, then activate**.
- On `RateCardEntry`, `RateCardType` and the `Default*` UoM fields are **derived (not writable)**, and
  `EffectiveFrom` is **required**. `RateCardType`/`Status` are **not SOQL-queryable in Apex** (filter via
  `RateCard.Type` instead).

### 4.4 After deploying
- Make **PS Quote Record Page** (`PS_Quote_Record_Page`, which already contains `psQuoteBuilder`) the
  **app default for Revenue Cloud**: `bash scripts/set-quote-app-default.sh "<orgUsername>"`. The
  assignment lives on the app (`CustomApplication` Quote View override), not on the FlexiPage, so the script
  retrieves the target org's own Revenue Cloud app, swaps only the Quote override, and deploys it back.
  It is safe to re-run. Don't add the app to `manifest/package.xml`: deploying a `CustomApplication`
  replaces the whole app, including that org's navigation and other page assignments.
  Manual alternative: Lightning App Builder -> open the page -> Activation -> App Default -> Assign as App
  Default -> Revenue Cloud -> Save.
- Assign the `PS_Quote_Builder` permission set (deployed custom fields have no field access for any
  profile, including System Administrator, until it is assigned).
- Optionally set `PS_Quote_Settings.Default` (`Cost_Book_Name__c`, `Target_Margin_Pct__c`).
- To seed demo data (10 researched roles, the shared `PS_LABOR_HOURS` resource, Base rate card entries,
  a default cost book, and the brand image), run the post-install skill in [SKILL.md](../SKILL.md). It also
  assigns the permission set, checks the Remote Site URL, and sets the Quote app default.

## 5. Deferred
- **Per-phase billed-rate variation** (same resource billed at different rates in different phases). The
  estimate captures per-phase rates, but a single usage rate-card entry per line can't vary the billed
  rate by phase (an `AssetStatePeriod` carries quantity/amount, not a usage rate). Assume **one rate per
  resource**; revisit with date-bounded rate-card entries if a demo needs it.
- **Actuals rating** (usage records -> Calculate Rate -> `UsageRatableSummary` -> invoice) needs
  `UsageResourceBillingPolicy` + binding/decision-table config; not part of this project.
