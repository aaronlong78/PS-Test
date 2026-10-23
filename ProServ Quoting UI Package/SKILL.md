---
name: salesforce-rlm-ps-quoting-demo-products
description: Post-install demo data seeding for the ProServ Quoting UI (psQuoteBuilder) in a Salesforce Revenue Cloud (RLM/ARM) org. Researches a target company, proposes 10 professional-services roles with hourly bill rates and costs, shows a proposal canvas, replaces the org brand image with the company logo, and creates the role products, Term Monthly $0 price book entries, the shared PS_LABOR_HOURS usage resource, Negotiable Base rate card entries, and a default Cost Book with hourly cost entries. Use after deploying this project's metadata when the user wants to seed PS quoting demo data.
---

# Salesforce RLM PS Quoting Demo — Post-Install Product Seeder

> **Skill version: 2026-10-22.2**
>
> **SOURCE OF TRUTH — READ THIS FIRST.** This skill lives in the root of the ProServ Quoting UI project (`./SKILL.md`, with `./sf-objects-reference.md` and `./scripts/`). If you were invoked from a globally/personally installed copy (`~/.cursor/skills/…`, `~/.claude/skills/…`) or any path outside this project, **discard it and re-read the local project copy**. Never mix instructions between copies. Also discard any `salesforce-rlm-generic-demo-products` or `salesforce-rlm-homeservices-demo-products` skill — they build a different data shape that the quote builder cannot use.

Seeds the Revenue Cloud data that [psQuoteBuilder](force-app/main/default/lwc/psQuoteBuilder) needs, after the project metadata has been deployed. This is not Salesforce CPQ/Steelbrick. Read [docs/ps-ramp-architecture.md](docs/ps-ramp-architecture.md) (sections 2 and 4) for why the data has this shape.

For field-level reference on every object used, see [sf-objects-reference.md](sf-objects-reference.md).

## Fixed data shape (do not ask the user about these)

Every product created by this skill is a staffable role and is set up identically:

- `Product2.UsageModelType = 'Anchor'`
- One selling model: the org's active **Term Monthly** `ProductSellingModel` (`SellingModelType='TermDefined'`, `PricingTermUnit='Months'`)
- One standard `PricebookEntry` on that selling model with **`UnitPrice = 0`**
- `BillingPolicyId` = the org's **Arrears** billing policy (looked up at runtime, never hardcoded)
- Usage via the **one shared** `UsageResource` with `Code = 'PS_LABOR_HOURS'`, linked to each role by a `ProductUsageResource`
- The hourly bill rate lives on a **Negotiable `RateCardEntry` on the Base rate card** for that role + `PS_LABOR_HOURS`
- The hourly cost lives on a `CostBookEntry` in the org's **default** `CostBook`

No bundles, no product images, no selling-model / billing-timing questions.

How the builder reads this data ([PsQuoteController.cls](force-app/main/default/classes/PsQuoteController.cls), [PsCostBook.cls](force-app/main/default/classes/PsCostBook.cls)):

- A role is any `RateCardEntry` with `UsageResource.Code = 'PS_LABOR_HOURS'`, `RateCard.Type = 'Base'`, and `ProductId` set. `Rate` is the list hourly rate.
- The role must also have an active standard `PricebookEntry` whose selling model is `TermDefined` / `Months`. That entry anchors the quote line.
- Cost: `PS_Quote_Settings.Default.Cost_Book_Name__c` is blank, so the builder uses the `CostBook` with `IsDefault = true` and reads `CostBookEntry.Cost` (effective now) as the hourly cost.

## Prerequisites

- This project's metadata is already deployed to the target org (see Phase 3 check)
- Salesforce CLI (`sf`) installed; `python3` available (REST calls, logo resize)
- Canvas tooling available for the proposal canvas
- Run commands from the project root
- This **is** an SFDX project, but never rely on or change its default org: never `sf config set`, never log in with `--set-default`. Pass `--target-org "<orgUsername>"` on every `sf` command and as the third argument to helper scripts.

## Questions (required)

For every user **decision or confirmation** after Phase 0, use Cursor's structured question UI (`AskQuestion`): selectable options, not numbered lists in chat. The built-in **Other** option is how the user types extra detail (edits, overrides, a username not in the list). Do not invent extra choices beyond those listed in each phase.

**Exception — Phase 0:** ask the exact freeform kickoff sentence in chat and nothing else first.

**Exception — Phase 2 confirmation:** do **not** use `AskQuestion`. While a question card is open, the chat links above it are hidden or not clickable, so the user can't open the canvas. End the turn with the clickable canvas link and ask the user to reply in chat (see Phase 2).

## Phase 0 - Kickoff Prompt (required)

Before any research or org work, ask this exact question first:

`Please tell me the name of the company you want me to research and share the company website URL.`

If the user provides only one item, ask only for the missing item before continuing.

## Phase 1 - Research

Research the company's services and propose **exactly 10** professional-services / staffing roles that company would plausibly staff on an engagement (e.g. Engagement Manager, Solution Architect, Senior Implementation Engineer, Data Migration Specialist, QA Analyst, Trainer). Roles should reflect the company's actual offerings and industry, not a generic list.

Rules:
- Exactly 10 roles, all standalone (no bundles, no add-ons)
- Concise unique product codes (e.g. `PS-PM`, `PS-SA`); avoid collisions with existing `Product2.ProductCode` values in the org (checked in Phase 5)
- Concise descriptions (one or two sentences)
- Realistic **hourly bill rate** per role for the company's market and seniority
- Realistic **hourly cost** per role (fully loaded labor cost). Target margins around the builder's target margin of **40%** (`PS_Quote_Settings.Default.Target_Margin_Pct__c`), with realistic variation (roughly 30–50%) across roles

Internal list per role:
- Product name
- Product code
- Description
- Hourly bill rate (USD)
- Hourly cost (USD)
- Margin % = (rate − cost) / rate

Also capture the company logo from the researched website. Do **not** use `GenerateImage` for anything in this skill — download the real logo.

Logo capture rules:
- Prefer the header/nav logo over favicon or `og:image`
- Prefer a downloaded JPG, PNG, or GIF header logo and store it under `./assets/<company>/` (this folder is outside `force-app/` and is not deployed)
- If the header/nav logo is SVG, rasterize it locally to PNG (qlmanage, sips, or Pillow). Do **not** fall back to favicon or `og:image` while a header SVG exists.
- Crop padded thumbnails to the actual wordmark before Phase 4b. `qlmanage -t` often produces a 1200×1200 canvas; contain+pad to 600×120 on that padded image makes a tiny logo.
- `qlmanage -t` renders a **square** thumbnail and cuts off wide wordmarks (Kyndryl rendered as "kynd"). Before rendering, rewrite the SVG root to a square `viewBox` that pads top and bottom (e.g. `viewBox="0 0 124 40"` → `width="1240" height="1240" viewBox="0 -42 124 124"`), render with `qlmanage -t -s 2000`, then crop to the non-white/non-transparent bounding box with Pillow.
- Open the final PNG with `Read` and check it visually (whole wordmark, tight crop) before Phase 2.
- The sandbox blocks writes to `/tmp`. Write the scaled SVG, rendered thumbnail, and other intermediates under `./assets/<company>/`.
- The logo will be resized to 600x120 px in Phase 4b (contain+pad; do not stretch)
- Only stop and ask for a local image path if rasterization fails or no header logo exists

## Phase 2 - Propose and Confirm

Write the proposal canvas to two identical files and keep both in sync after edits:

- **Review copy (the one you link):** `/Users/<user>/.cursor/projects/<workspace>/canvases/<company>-ps-roles-proposal.canvas.tsx`. Cursor only renders canvases from this directory, and the path has no spaces, so a markdown link to it is clickable and opens the rendered canvas in a tab.
- **Project copy (kept with the project):** `./canvases/<company>-ps-roles-proposal.canvas.tsx`, outside `force-app/` so it is never deployed. This opens as source code, so it is not the review link.

The canvas must include:
- The captured company logo, embedded as a base64 PNG data URI (`data:image/png;base64,…`). A canvas cannot load a local file path. Use a thumbnail about 320px wide. Write the canvas with a placeholder such as `__LOGO_B64__`, then substitute the base64 string with a short Python step instead of pasting it by hand.
- One row per role: name, code, description, hourly bill rate, hourly cost, margin %
- A note that every role is created as Anchor / Term Monthly with a $0 price book entry, billed on actual hours at the rate shown

Required review flow (do not skip or reorder; do not continue until confirmed):

1. Write the canvas to both paths above.
2. End the turn with a final chat message, with no `AskQuestion` call in that turn, that contains:
   - A bold, clickable markdown link to the **review copy** on its own line, using the full absolute path: `**[Open the <Company> proposal canvas](/Users/<user>/.cursor/projects/<workspace>/canvases/<company>-ps-roles-proposal.canvas.tsx)**`
   - One sentence saying it opens the rendered canvas in a tab to review roles, rates, and costs. If it is the first `.canvas.tsx` in that directory, add one sentence explaining what a canvas is.
   - The review question as text: `Review the proposal canvas, then reply **confirm** to proceed, or tell me which roles, rates, costs, or the logo to change.`
   
   A markdown table in chat is not a substitute for the link, and writing the file does not count as showing it.
3. Wait for the user's reply. Treat only an explicit confirmation as confirmed. For edits, update both copies and repeat step 2 with the same link. The list must still contain exactly 10 roles unless the user explicitly asks for a different count.

## Phase 3 - Org Authentication and Post-Install Check

### Select and authenticate the org

1. Run `sf org list` and ask which org to target with `AskQuestion`. Present the **connected** usernames/aliases as selectable options. Do not skip this question even if only one org is connected. If you deployed the metadata to an org earlier in this conversation, list that org first and mark it `(Recommended)`. The user picks **Other** to type the username of an org that is not authorized yet.
2. If the chosen/entered username is not a connected org, authenticate it:
   - Ask with `AskQuestion` which login URL to use: `Production / Developer Edition (https://login.salesforce.com)`, `Sandbox (https://test.salesforce.com)`, or a My Domain URL via Other.
   - Run `sf org login web --instance-url "<loginUrl>"` (add `--alias` if the user wants one). **Never** pass `--set-default` / `--set-default-dev-hub`.
3. Verify: `sf org display --target-org "<orgUsername>" --json`. Print the `username` and org `id` in chat before any changes. If the authenticated username does not match what the user entered, stop and tell the user.

Use that username as `<orgUsername>` for every later command.

### Verify the metadata is deployed

This skill runs **post install**. Before seeding, confirm the project metadata exists in the org:

- `SELECT Id FROM ApexClass WHERE Name IN ('PsQuoteController','PsQuoteService','PsCostBook')` → 3 rows
- `sf sobject describe --sobject PS_Estimate_Segment__c --target-org "<orgUsername>"` succeeds
- `SELECT Id FROM PermissionSet WHERE Name = 'PS_Quote_Builder'` → 1 row

If anything is missing, deploy it now using the steps below, then re-run these checks.

### Deploying the metadata

1. Always set the Remote Site URL before deploying, even if the file looks correct. Run `sf org display --target-org "<orgUsername>" --json`, take `instanceUrl`, and write it into `<url>` in [PsRevCloudSelf.remoteSite-meta.xml](force-app/main/default/remoteSiteSettings/PsRevCloudSelf.remoteSite-meta.xml). Print the old and new URL in chat. The file holds whichever org was deployed last.
2. Run a check-only deploy first:
   `sf project deploy start --manifest manifest/package.xml --target-org "<orgUsername>" --dry-run --wait 30`
   The deploy is atomic: one bad reference rolls back everything. The usual failures are on `PS_Quote_Record_Page`: header quick actions that exist only in the dev org (e.g. `Quote.RLM_CreateContract`, `Quote.RLM_Create_Ramp_Schedule_V4`) and Work Guide properties from newer Orchestrator releases (`isAutoAdvanceToNextWorkItem`). See docs section 4.1. Tell the user what failed before removing anything from the page.
3. Deploy for real with the same command without `--dry-run`.
4. Trial and Developer Edition orgs may skip Apex tests during the deploy, so run them explicitly:
   `sf apex run test --class-names PsQuoteControllerTest --code-coverage --result-format human --wait 20 --target-org "<orgUsername>"`
5. Re-run the three checks above, then continue with Phase 4.

## Phase 4 - Runtime ID Lookups

Query every Id at runtime (never hardcode Ids; they differ per org). Exact queries are in [sf-objects-reference.md](sf-objects-reference.md#runtime-lookups-never-hardcode-ids).

- `TaxPolicy` where `Name='Default Tax Policy'`
- **Arrears billing policy:** search `BillingPolicy` where `Name LIKE '%Arrears%'` (active). Exactly one match → use it. Several → ask the user to pick with `AskQuestion` (one option per match). None → stop.
- **Term Monthly selling model:** `ProductSellingModel` where `SellingModelType='TermDefined'` and `PricingTermUnit='Months'` and `Status='Active'`. If several, prefer `Name='Term Monthly'`; otherwise ask.
- Standard `Pricebook2` (`IsStandard=true`)
- `ProrationPolicy` where `Name='Default Proration Policy'`
- **Time UoM class** and **Hour UoM**: `UnitOfMeasureClass` where `Type='Time'` (or `Name='Time'`), and its `UnitOfMeasure` named `Hour` / `Hours`. If missing, create them (class first, then UoM), inserting as `Draft` and then activating, in that order. The class `Type` is often `Usage`, which is fine.
- **USD rate UoM:** active `UnitOfMeasure` with `UnitCode='USD'` whose class `Type='Currency'`. Rate card entries require a Currency or Token unit; stop if missing.
- `UsageResourceBillingPolicy` where `Name='Monthly Total'`
- `UsageOveragePolicy` where `Name='Default Usage Overage Policy'`
- `RatingFrequencyPolicy` where `Name='Monthly Rating Frequency'`
- **Base rate card:** `RateCard` where `Type='Base'`. Prefer `Name='Base Rate Card'` if several.

Also check for existing PS data so the run is idempotent:
- `UsageResource` where `Code='PS_LABOR_HOURS'` (reuse if present)
- Existing `CostBook` rows and which one has `IsDefault=true`

If a required lookup record (other than the Time/Hour UoMs, which you create) is missing, stop and inform the user.

## Phase 4b - Replace Org Brand Image

Run immediately after Phase 4, before catalog creation, so branding is applied even if later steps fail.

Under Setup → Themes and Branding there is always an existing active theme with Developer Name `QuantumBitSLDSv2`. Replace its Brand Image with the researched company logo (600x120 px).

1. Sanitize a ContentAsset developer name (alphanumeric + underscores, must start with a letter, max 40 characters), e.g. `<Company>_BrandLogo`.
2. Run the helper. It resizes the logo to 600x120 with contain+pad (does not stretch), uploads it as a ContentAsset, and replaces `BRAND_IMAGE` on theme `QuantumBitSLDSv2`:

```bash
bash scripts/update-theme-brand-image.sh "<absoluteLogoPath>" "<sanitizedAssetName>" "<orgUsername>"
```

3. Do not change other theme properties (colors, banner, etc.).
4. The helper queries the theme by Developer Name at runtime. If the theme or its branding set is missing, stop the branding step, tell the user, and continue with Phase 5.

## Phase 5 - Catalog and Role Products

Use an idempotent create-or-reuse flow (match products by `ProductCode`). Prefer Python REST calls (`sf org display --json` for `instanceUrl` / `accessToken`) for records with long text, and `sf data create record --target-org` for simple ones.

1. Ensure `ProductCatalog` `<Company> Catalog` exists
2. Ensure `ProductCategory` `Offerings` exists in that catalog
3. For each of the 10 roles, create or reuse `Product2`:
   - `Name`, `ProductCode`, `Description`, `IsActive=true`, `IsAssetizable=true`, `CurrencyIsoCode='USD'`
   - `UsageModelType='Anchor'`
   - `TaxPolicyId` = Default Tax Policy
   - `BillingPolicyId` = the Arrears policy from Phase 4
   - If an existing product is reused and `UsageModelType` is not `Anchor`, update it to `Anchor`
4. Create or reuse `ProductCategoryProduct` (role → `Offerings`)
5. Create or reuse `ProductSellingModelOption`: `Product2Id`, Term Monthly `ProductSellingModelId`, `ProrationPolicyId`, `IsDefault=true`
6. Create or reuse the standard `PricebookEntry`: `Product2Id`, standard `Pricebook2Id`, Term Monthly `ProductSellingModelId`, **`UnitPrice=0`**, `IsActive=true`, `CurrencyIsoCode='USD'`

Do not create bundles, component groups, static resources, `DisplayUrl` values, or any other selling model / price book entry for these products.

## Phase 6 - Usage Configuration (shared PS_LABOR_HOURS resource)

The quote builder discovers roles through **one** usage resource coded `PS_LABOR_HOURS`. Do **not** create a usage resource per product.

Activation order matters (UoM class → UoM → UsageResource → ProductUsageResource → RateCardEntry). Insert usage records as `Draft`, then activate.

### Step 1 - Link the Base rate card to the standard price book

Ensure a `PriceBookRateCard` exists with `PriceBookId` = standard price book and `RateCardId` = Base rate card. Create it if missing (`RateCardType='Base'` if the field is writable in the org; check with `sf sobject describe`).

### Step 2 - Create or reuse the UsageResource

If `UsageResource` with `Code='PS_LABOR_HOURS'` exists, reuse it. Otherwise create:

- `Name='PS Labor Hours'`
- `Code='PS_LABOR_HOURS'`
- `Category='Usage'`
- `UnitOfMeasureClassId` = Time class
- `DefaultUnitOfMeasureId` = Hour
- `UsageResourceBillingPolicyId` = Monthly Total, only if the field is createable in the org (some orgs don't expose it; Monthly Total is still applied per role through `ProductUsageResourcePolicy`)
- `Status='Draft'`
- Do **not** set `UsageDefinitionProductId` — the resource is shared by all roles

### Step 3 - ProductUsageResource + ProductUsageResourcePolicy per role

For each role (skip if a `ProductUsageResource` for that product + resource already exists):

1. Create `ProductUsageResource`: `ProductId`, `UsageResourceId`, `Status='Draft'`, `EffectiveStartDate` = November 1 of the **previous calendar year** (run in 2026 → `2025-11-01`)
2. Create `ProductUsageResourcePolicy`: `ProductUsageResourceId`, `ProductSellingModelId` = Term Monthly, `UsageAggregationPolicyId` = Monthly Total, `UsageOveragePolicyId` = Default Usage Overage Policy, `RatingFrequencyPolicyId` = Monthly Rating Frequency

Do not create a `ProductUsageGrant`. Zero included hours means pure pay-per-use.

### Step 4 - Activate (order required)

1. Update the `UsageResource` → `Status='Active'` (once, if not already active)
2. Update each `ProductUsageResource` → `Status='Active'`

Do not reverse this order.

### Step 5 - RateCardEntry per role (the hourly bill rate)

For each role, skip if a `RateCardEntry` already exists for that `ProductId` with `UsageResource.Code='PS_LABOR_HOURS'` on the Base rate card. Otherwise create:

- `RateCardId` = Base rate card
- `ProductId` = role product
- `UsageResourceId` = PS_LABOR_HOURS resource
- `ProductSellingModelId` = Term Monthly
- `RateUnitOfMeasureId` = the **USD** unit (Currency class). Not `Hour`: the org rejects a Time-class unit with "Wrong Unit Of Measure Type". The rate is USD per hour because the usage resource's default unit is `Hour`.
- `Rate` = confirmed hourly bill rate
- `RateNegotiation='Negotiable'` (required so the quoted rate can override it)
- `EffectiveFrom` = November 1 of the previous calendar year (Date/Time, required)
- `Status='Draft'`

Do **not** set `RateCardType` or `DefaultUnitOfMeasureId` — they are derived and not writable. Immediately after insert, update the entry to `Status='Active'`.

## Phase 7 - Cost Book (hourly costs)

1. Describe the objects first and only write fields the org exposes as createable:
   `sf sobject describe --sobject CostBook --target-org "<orgUsername>"` and the same for `CostBookEntry`.
2. Create or reuse `CostBook` `Name='<Company> PS Cost Book'`, `IsDefault=true` (plus `EffectiveFrom` = Nov 1 of the previous year if the field is required).
   - If a different book is currently `IsDefault=true`, tell the user which one. Do **not** try to set it to `IsDefault=false`; the org rejects that ("You can't deselect Default"). Create (or update) the new book with `IsDefault=true`, which un-defaults the old book automatically, then re-query to confirm only the new book is the default.
3. Leave `PS_Quote_Settings.Default.Cost_Book_Name__c` blank (deployed blank) so the builder resolves the default book. If the user has set a name there, tell them it overrides the default and must be cleared or changed to the new book name.
4. For each role, create or reuse one `CostBookEntry`:
   - `CostBookId`, `ProductId`
   - `Cost` = confirmed **hourly** cost
   - `EffectiveFrom` = November 1 of the previous calendar year; leave `EffectiveTo` blank
   - `IsActive=true` if the field exists

The builder only reads entries where `EffectiveFrom <= now` and `EffectiveTo` is blank or in the future.

## Phase 8 - Post-Install Setup and Verification

1. Assign the permission set to the running user (deployed custom fields have no access until this is done):
   `sf org assign permset --name PS_Quote_Builder --target-org "<orgUsername>"` (an "already assigned" result is fine)
2. Check the Remote Site Setting: query `RemoteProxy` via the Tooling API (`SiteName='PsRevCloudSelf'`) and compare `EndpointUrl` with the org's `instanceUrl`. If they differ or the record is missing, set `<url>` in [PsRevCloudSelf.remoteSite-meta.xml](force-app/main/default/remoteSiteSettings/PsRevCloudSelf.remoteSite-meta.xml) to the `instanceUrl` and deploy only that folder:
   `sf project deploy start --source-dir force-app/main/default/remoteSiteSettings --target-org "<orgUsername>" --wait 10`
   Re-query `RemoteProxy` to confirm it matches. Stop and tell the user only if that deploy fails; quote build callouts fail until the URL matches.
3. Verify the seeded data with the same filters the builder uses. Expect **10** rows for each:

```sql
SELECT ProductId, Rate, RateNegotiation FROM RateCardEntry
WHERE UsageResource.Code = 'PS_LABOR_HOURS' AND RateCard.Type = 'Base' AND ProductId != null
```

```sql
SELECT Product2Id, UnitPrice FROM PricebookEntry
WHERE IsActive = true AND Pricebook2.IsStandard = true
  AND ProductSellingModel.SellingModelType = 'TermDefined'
  AND ProductSellingModel.PricingTermUnit = 'Months'
  AND Product2.ProductCode IN (<the 10 codes>)
```

```sql
SELECT ProductId, Cost FROM CostBookEntry
WHERE CostBook.IsDefault = true AND ProductId IN (<the 10 product Ids>)
```

4. Make **PS Quote Record Page** the App Default Quote page for the Revenue Cloud app:
   `bash scripts/set-quote-app-default.sh "<orgUsername>"`
   The helper finds the unmanaged app labeled `Revenue Cloud` (pass its developer name as a second argument if the lookup fails), retrieves the target org's copy, replaces only the Quote View / Large `actionOverrides` entry, deploys the app back, and re-retrieves to verify. It is idempotent. Never add the `CustomApplication` to `manifest/package.xml` or `force-app/`; deploying the whole app would overwrite that org's navigation and other page assignments. If the helper fails, tell the user and give the manual path (Lightning App Builder → open the page → Activation → App Default → Revenue Cloud).

## Completion

Provide a concise summary:
- Company researched and target org (username + org Id)
- The 10 roles with code, hourly rate, hourly cost, margin %
- Org brand image result on theme `QuantumBitSLDSv2` (ContentAsset name and `/file-asset/…` value, or skipped and why)
- Shared resources used/created: Arrears billing policy, Term Monthly selling model, Base rate card, `PriceBookRateCard`, `PS_LABOR_HOURS` usage resource, Time/Hour and USD UoMs
- Cost Book name and whether a previous default book was un-defaulted
- Permission set assignment, and the Remote Site URL (matched, or corrected and redeployed, with old → new URL)
- Verification counts from Phase 8
- Records created vs reused, and any skipped steps and why
- Quote record page app-default result (app developer name, previous page it replaced, or why it was skipped)
