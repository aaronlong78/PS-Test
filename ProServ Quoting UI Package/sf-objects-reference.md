# Salesforce RLM Object & Field Reference — PS Quoting Demo Data

Field format: `API Name | Type | Notes`

Companion to [`SKILL.md`](SKILL.md) (`salesforce-rlm-ps-quoting-demo-products`). Use the skill for workflow and this file for field-level gotchas. The data shape matches what [PsQuoteController.cls](force-app/main/default/classes/PsQuoteController.cls) and [PsCostBook.cls](force-app/main/default/classes/PsCostBook.cls) query; see [docs/ps-ramp-architecture.md](docs/ps-ramp-architecture.md) section 4.

> Fields marked ⚠️ are common failure points.

---

## Runtime lookups (never hardcode IDs)

Resolve at runtime against the target org. Stop if a required record is missing.

| Object | Match | Query |
|---|---|---|
| `TaxPolicy` | `Default Tax Policy` | `SELECT Id FROM TaxPolicy WHERE Name = 'Default Tax Policy'` |
| `BillingPolicy` | Arrears policy (search) | `SELECT Id, Name, Status FROM BillingPolicy WHERE Name LIKE '%Arrears%'` — use the single active match; ask if several |
| `ProductSellingModel` | Term Monthly | `SELECT Id, Name FROM ProductSellingModel WHERE SellingModelType = 'TermDefined' AND PricingTermUnit = 'Months' AND Status = 'Active'` — prefer `Name = 'Term Monthly'` if several |
| `Pricebook2` | Standard | `SELECT Id FROM Pricebook2 WHERE IsStandard = true` |
| `ProrationPolicy` | `Default Proration Policy` | `SELECT Id FROM ProrationPolicy WHERE Name = 'Default Proration Policy'` |
| `UnitOfMeasureClass` | Time class | `SELECT Id, Name, Type, Status FROM UnitOfMeasureClass WHERE Type = 'Time' OR Name = 'Time'` — create if missing |
| `UnitOfMeasure` | Hour | `SELECT Id, Name, Status FROM UnitOfMeasure WHERE UnitOfMeasureClassId = '<timeClassId>' AND Name IN ('Hour','Hours')` — create if missing |
| `UnitOfMeasure` | USD (rate unit) | `SELECT Id FROM UnitOfMeasure WHERE UnitCode = 'USD' AND UnitOfMeasureClass.Type = 'Currency' AND Status = 'Active'` — required for `RateCardEntry.RateUnitOfMeasureId` |
| `UsageResourceBillingPolicy` | `Monthly Total` | `SELECT Id FROM UsageResourceBillingPolicy WHERE Name = 'Monthly Total'` |
| `UsageOveragePolicy` | `Default Usage Overage Policy` | `SELECT Id FROM UsageOveragePolicy WHERE Name = 'Default Usage Overage Policy'` |
| `RatingFrequencyPolicy` | `Monthly Rating Frequency` | `SELECT Id FROM RatingFrequencyPolicy WHERE Name = 'Monthly Rating Frequency'` |
| `RateCard` | Base rate card | `SELECT Id, Name FROM RateCard WHERE Type = 'Base'` — prefer `Name = 'Base Rate Card'` if several |
| `UsageResource` | Existing PS resource | `SELECT Id, Status FROM UsageResource WHERE Code = 'PS_LABOR_HOURS'` — reuse if present |
| `CostBook` | Current default | `SELECT Id, Name, IsDefault FROM CostBook` |
| `LightningExperienceTheme` | Developer Name `QuantumBitSLDSv2` | Tooling API (see brand image section) |

> ⚠️ Only `TermDefined` + `PricingTermUnit = 'Months'` selling models are visible to the builder. A product on any other selling model will not appear in the role search.

---

## ProductCatalog
| API Name | Type | Value / Notes |
|---|---|---|
| `Name` | Text(255) | Company name + " Catalog" (e.g. "Acme Catalog") |

> ⚠️ `IsActive` does **not** exist on `ProductCatalog` — omit it.

---

## ProductCategory
| API Name | Type | Value / Notes |
|---|---|---|
| `Name` | Text(255) | Always `"Offerings"` |
| `CatalogId` | Lookup(ProductCatalog) | ID of the catalog above |

> ⚠️ `IsActive` does **not** exist on `ProductCategory` — omit it.

---

## ProductCategoryProduct
| API Name | Type | Value / Notes |
|---|---|---|
| `ProductId` | Lookup(Product2) | Role product |
| `ProductCategoryId` | Lookup(ProductCategory) | The "Offerings" category |

---

## Product2 (one per role)
| API Name | Type | Value / Notes |
|---|---|---|
| `Name` | Text(255) | Role name |
| `ProductCode` | Text(255) | Concise unique code (e.g. `PS-SA`) — idempotency key |
| `Description` | Text Area(4000) | Concise description — prefer Python REST for long text, not `--values` |
| `IsActive` | Checkbox | `true` |
| `IsAssetizable` | Checkbox | `true` (activation creates one asset per resource) |
| `CurrencyIsoCode` | Picklist | `USD` |
| `UsageModelType` | Picklist | ⚠️ Always `Anchor` |
| `TaxPolicyId` | Lookup(TaxPolicy) | Default Tax Policy |
| `BillingPolicyId` | Lookup(BillingPolicy) | Arrears policy found by search in Phase 4 |

> ⚠️ Do not set `Type`, `ConfigureDuringSale`, or `DisplayUrl` — no bundles and no images.
>
> ⚠️ Do NOT use `sf data create record --body <file>` — `--body` does not exist in SF CLI versions before 2.130. Use the Python REST approach when needed.

---

## ProductSellingModelOption
| API Name | Type | Value / Notes |
|---|---|---|
| `Product2Id` | Lookup(Product2) | Role product |
| `ProductSellingModelId` | Master-Detail(ProductSellingModel) | Term Monthly |
| `ProrationPolicyId` | Lookup(ProrationPolicy) | Default Proration Policy |
| `IsDefault` | Checkbox | **Always `true`** so the selling model option resolves for pricing |

> ⚠️ Field is `Product2Id`, **not** `ProductId`.

---

## PricebookEntry
| API Name | Type | Value / Notes |
|---|---|---|
| `Product2Id` | Lookup(Product2) | Role product |
| `Pricebook2Id` | Lookup(Pricebook2) | Standard price book |
| `ProductSellingModelId` | Lookup(ProductSellingModel) | Term Monthly |
| `UnitPrice` | Currency | ⚠️ Always `0` — the hourly rate is on `RateCardEntry`, not here |
| `IsActive` | Checkbox | `true` |
| `CurrencyIsoCode` | Picklist | `USD` |

> The builder anchors each quote line on this entry (`UnitPrice = 0`, `Quantity = 1`). A non-zero price would bill a monthly term charge on top of the usage charges.

---

## PriceBookRateCard
Links the Base rate card to the standard price book. One per org; create only if missing.

| API Name | Type | Value / Notes |
|---|---|---|
| `PriceBookId` | Lookup(Pricebook2) | Standard price book |
| `RateCardId` | Lookup(RateCard) | Base rate card |
| `RateCardType` | Picklist | `Base` — set only if createable in the org (check with `sf sobject describe`) |

> ⚠️ Field is `PriceBookId`, **not** `Pricebook2Id`.

---

## UnitOfMeasureClass / UnitOfMeasure (create only if missing)
| Object | Field | Value / Notes |
|---|---|---|
| `UnitOfMeasureClass` | `Name` | `Time` |
| `UnitOfMeasureClass` | `Type` | `Time` (if the picklist value exists) |
| `UnitOfMeasureClass` | `Status` | Insert `Draft`, activate before creating the UoM |
| `UnitOfMeasure` | `Name` / `UnitCode` | `Hour` / `HR` |
| `UnitOfMeasure` | `UnitOfMeasureClassId` | Time class |
| `UnitOfMeasure` | `Status` | Insert `Draft`, then activate |

Describe both objects first; field sets vary slightly by release.

---

## UsageResource (one shared record)
| API Name | Type | Value / Notes |
|---|---|---|
| `Name` | Text | `PS Labor Hours` |
| `Code` | Text | ⚠️ Exactly `PS_LABOR_HOURS` — the builder finds roles by this code |
| `Category` | Picklist | `Usage` |
| `Status` | Picklist | Insert `Draft`; activate **before** the ProductUsageResources |
| `UnitOfMeasureClassId` | Lookup(UnitOfMeasureClass) | Time class |
| `DefaultUnitOfMeasureId` | Lookup(UnitOfMeasure) | Hour |
| `UsageResourceBillingPolicyId` | Lookup(UsageResourceBillingPolicy) | `Monthly Total` — only if createable; some orgs don't expose it on `UsageResource` |

> ⚠️ Do **not** create one resource per product, and do not set `UsageDefinitionProductId` — every role shares this resource.

---

## ProductUsageResource (one per role)
| API Name | Type | Value / Notes |
|---|---|---|
| `ProductId` | Lookup(Product2) | Role product |
| `UsageResourceId` | Lookup(UsageResource) | `PS_LABOR_HOURS` resource |
| `Status` | Picklist | Insert `Draft`; activate **after** the UsageResource |
| `EffectiveStartDate` | Date | November 1 of the previous calendar year (run in 2026 → `2025-11-01`) |

---

## ProductUsageResourcePolicy (one per ProductUsageResource)
| API Name | Type | Value / Notes |
|---|---|---|
| `ProductUsageResourceId` | Master-Detail(ProductUsageResource) | The role's PUR |
| `ProductSellingModelId` | Lookup(ProductSellingModel) | Term Monthly |
| `UsageAggregationPolicyId` | Lookup(UsageResourceBillingPolicy) | `Monthly Total` (the API field points at UsageResourceBillingPolicy) |
| `UsageOveragePolicyId` | Lookup(UsageOveragePolicy) | `Default Usage Overage Policy` |
| `RatingFrequencyPolicyId` | Lookup(RatingFrequencyPolicy) | `Monthly Rating Frequency` |

No `ProductUsageGrant` is created (zero included hours = pure pay-per-use).

---

## RateCardEntry (one per role — the hourly bill rate)
| API Name | Type | Value / Notes |
|---|---|---|
| `RateCardId` | Master-Detail(RateCard) | Base rate card |
| `ProductId` | Lookup(Product2) | Role product |
| `UsageResourceId` | Lookup(UsageResource) | `PS_LABOR_HOURS` resource |
| `ProductSellingModelId` | Lookup(ProductSellingModel) | Term Monthly |
| `RateUnitOfMeasureId` | Lookup(UnitOfMeasure) | ⚠️ **USD** (Currency class). `Hour` is rejected with "Wrong Unit Of Measure Type"; the unit must be in a Currency or Token class. The per-hour basis comes from the usage resource's default unit (`Hour`). |
| `Rate` | Number(12, 6) | Confirmed hourly bill rate |
| `RateNegotiation` | Picklist | ⚠️ Always `Negotiable` — lets `QuoteLineRateCardEntry.NegotiatedRate` override it |
| `EffectiveFrom` | Date/Time | ⚠️ Required. November 1 of the previous calendar year |
| `Status` | Picklist | Insert `Draft`, then update to `Active` |

> ⚠️ `RateCardType` and `DefaultUnitOfMeasureId` are **derived, not writable** — do not set them.
>
> ⚠️ `RateCardType` / `Status` are not SOQL-filterable from Apex; the builder filters on `RateCard.Type = 'Base'`. Use the same filter when checking for existing entries.

**Activation order (usage):** UoM class → UoM → Draft UsageResource → Draft PURs + PURPs → activate UsageResource → activate PURs → Draft RateCardEntry → activate RateCardEntry.

---

## CostBook
| API Name | Type | Value / Notes |
|---|---|---|
| `Name` | Text | `<Company> PS Cost Book` |
| `IsDefault` | Checkbox | `true` — the builder uses the default book because `PS_Quote_Settings.Default.Cost_Book_Name__c` is blank |
| `EffectiveFrom` | Date/Time | November 1 of the previous calendar year, only if present and required |

> ⚠️ Only one book can be the default, and the current default can't be cleared directly ("You can't deselect Default"). Tell the user which book is the current default, then create or update the new book with `IsDefault = true`; that un-defaults the old one automatically.
>
> Describe the object first (`sf sobject describe --sobject CostBook`) and write only createable fields.

---

## CostBookEntry (one per role — the hourly cost)
| API Name | Type | Value / Notes |
|---|---|---|
| `CostBookId` | Lookup(CostBook) | `<Company> PS Cost Book` |
| `ProductId` | Lookup(Product2) | Role product |
| `Cost` | Currency | Confirmed **hourly** cost |
| `EffectiveFrom` | Date/Time | November 1 of the previous calendar year |
| `EffectiveTo` | Date/Time | Leave blank (open-ended) |
| `IsActive` | Checkbox | `true`, if the field exists |

> The builder reads entries where `EffectiveFrom <= now` and `EffectiveTo` is blank or in the future; the latest `EffectiveFrom` wins per product.

---

## Post-install checks
| Item | How | Notes |
|---|---|---|
| Permission set | `sf org assign permset --name PS_Quote_Builder --target-org <orgUsername>` | Custom fields have no access until assigned |
| Remote Site | Tooling API: `SELECT SiteName, EndpointUrl FROM RemoteProxy WHERE SiteName = 'PsRevCloudSelf'` | `EndpointUrl` must match the org's `instanceUrl`; otherwise set the file's `<url>` to it and redeploy `force-app/main/default/remoteSiteSettings` |
| Record page | `bash scripts/set-quote-app-default.sh <orgUsername>` | Sets `PS_Quote_Record_Page` as the App Default Quote page (desktop) on the unmanaged app labeled `Revenue Cloud` (`RLM_Revenue_Cloud`) by editing only that app's Quote View `actionOverrides` |

---

## LightningExperienceTheme / BrandingSetProperty (org Brand Image)

Setup → Themes and Branding always has an existing active theme **QuantumBitSLDSv2** (Developer Name). Replace its Brand Image with the researched company logo: **600x120 px**, JPG/PNG/GIF, under 5 MB. Do **not** stretch; the helper contain+pads onto a 600×120 canvas.

| Object | API / field | Notes |
|---|---|---|
| `LightningExperienceTheme` | `DeveloperName` | Lookup key: `QuantumBitSLDSv2`. Query via **Tooling API**. Never hardcode the theme Id. |
| `LightningExperienceTheme` | `DefaultBrandingSetId` | Id of the theme's `BrandingSet`. Stop if missing. |
| `BrandingSetProperty` | `PropertyName` | Case-sensitive. Brand Image is `BRAND_IMAGE`. |
| `BrandingSetProperty` | `PropertyValue` | `/file-asset/<ContentAsset.DeveloperName>?v=<VersionNumber>` |
| `ContentVersion` | `IsAssetEnabled` | `true` on **first** insert so Salesforce creates a `ContentAsset`. Omit on later versions. |
| `ContentAsset` | `DeveloperName` | Alphanumeric + underscores, start with a letter, ≤40 chars (e.g. `AcmeCorp_BrandLogo`). |

> ⚠️ `BRAND_IMAGE` must refer to an **asset file** (`ContentAsset`), not a Static Resource or a regular Salesforce File URL.
>
> ⚠️ Do **not** deploy the logo through `sf project deploy start` — use `scripts/update-theme-brand-image.sh`.
>
> ⚠️ Replace only `BRAND_IMAGE`; do not change colors, banner, or other theme properties.

```bash
bash scripts/update-theme-brand-image.sh "<absoluteLogoPath>" "<sanitizedAssetName>" "<orgUsername>"
```

---

## Documentation References

- [RLM Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.revenue_lifecycle_management_dev_guide.meta/revenue_lifecycle_management_dev_guide/) — primary object reference for RLM objects
- [Usage Management Standard Objects](https://developer.salesforce.com/docs/atlas.en-us.revenue_lifecycle_management_dev_guide.meta/revenue_lifecycle_management_dev_guide/usage_management_std_objects_parent.htm) — UsageResource, PUR, policies, RateCard, RateCardEntry, PriceBookRateCard
- [Salesforce Pricing Data Model](https://developer.salesforce.com/docs/platform/data-models/guide/salesforce-pricing.html) — `ProductSellingModel`, `ProductSellingModelOption`, `PricebookEntry`
- [SF CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/cli_reference_top.htm) — `sf org login web`, `sf data create record`, `sf data query`, `sf org assign permset`
- [BrandingSet (Metadata API)](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_brandingset.htm) — `BRAND_IMAGE` 600x120 asset-file requirement
- [ContentAsset Object Reference](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_contentasset.htm) — asset files referenced by `/file-asset/`
