/**
 * PsQuoteController
 * =================
 * LWC-facing controller for the psQuoteBuilder (PS/SOW Excel-like quoting UI).
 *
 * New (usage-native) model:
 * - A staffable role is a usage Anchor product that has a Negotiable Base RateCardEntry on the
 *   "PS Labor Hours" resource. The hourly rate shown in the builder comes from that rate-card entry.
 * - Each resource slot (the Nth copy of a role within a phase; the same slot across phases is the
 *   same person) is quoted as ONE QuoteLineItem on the Term Monthly selling model at $0. The negotiated
 *   hourly rate is written to QuoteLineRateCardEntry.NegotiatedRate (one entry per line = the usage
 *   rate override) plus reference custom fields; actual billing is usage-based against that rate.
 * - The weekly ramp is an LWC-only estimate, persisted in PS_Estimate_Segment__c so the builder can
 *   rebuild the grid when an existing quote is reopened.
 *
 * Endpoints:
 * - searchRoles(term): type-ahead for staffable roles (Term Monthly PBE anchor) + hourly rate.
 * - getQuoteEstimate(quoteId): reload a saved estimate (phases/resources/hours) for an existing quote.
 * - getRoleEconomics(): hourly cost per role (resolved cost book, see PsCostBook) + list rate + target margin.
 * - buildQuote(payload): generates the quote via PsQuoteService (Connect APIs).
 */
public with sharing class PsQuoteController {

    // ---- DTOs (shapes shared with the LWC) ------------------------------------------
    public class RoleOption {
        @AuraEnabled public String productId;
        @AuraEnabled public String pbeId;        // Term Monthly PricebookEntry (the line anchor)
        @AuraEnabled public String rceId;        // Base RateCardEntry (the usage rate override target)
        @AuraEnabled public String code;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal rate;        // hourly rate from the rate-card entry
    }

    public class ResourceInput {
        @AuraEnabled public String productId;
        @AuraEnabled public String pbeId;
        @AuraEnabled public String roleName;     // for reload display
        @AuraEnabled public Decimal rate;        // negotiated hourly rate
        @AuraEnabled public List<Decimal> hours; // per week within the phase
    }

    public class PhaseInput {
        @AuraEnabled public String name;
        @AuraEnabled public String startDate;   // yyyy-MM-dd
        @AuraEnabled public Integer weeks;
        @AuraEnabled public List<ResourceInput> resources;
    }

    public class QuoteRequest {
        @AuraEnabled public String quoteId;        // the existing quote the builder lives on
        @AuraEnabled public String quoteName;
        @AuraEnabled public String opportunityId;
        @AuraEnabled public List<PhaseInput> phases;
    }

    public class EstimateLoad {
        @AuraEnabled public String quoteId;
        @AuraEnabled public String quoteName;
        @AuraEnabled public String opportunityId;
        @AuraEnabled public String opportunityName;
        @AuraEnabled public String accountName;
        @AuraEnabled public List<PhaseInput> phases;
    }

    public class BuildResult {
        @AuraEnabled public String quoteId;
        @AuraEnabled public String quoteUrl;
        @AuraEnabled public Integer segmentCount;   // PS_Estimate_Segment__c rows written
        @AuraEnabled public Integer lineCount;      // one line per resource slot
        @AuraEnabled public Decimal totalNet;
        @AuraEnabled public Decimal estimatedRevenue;
        @AuraEnabled public Decimal estimatedCost;  // null when no role has a cost book entry
        @AuraEnabled public Decimal marginAmount;
        @AuraEnabled public Decimal marginPct;
    }

    public class RoleCost {
        @AuraEnabled public String productId;
        @AuraEnabled public Decimal cost;        // hourly cost from the cost book (null = no entry)
        @AuraEnabled public Decimal listRate;    // rate-card hourly rate, before negotiation
    }

    public class RoleEconomics {
        @AuraEnabled public String costBookName; // null = no cost book configured
        @AuraEnabled public Decimal targetMargin;
        @AuraEnabled public List<RoleCost> roles;
    }

    // ---- Role discovery -------------------------------------------------------------
    // Usage resource that carries the per-role hourly rate (see docs/ps-ramp-architecture.md, Org prerequisites).
    private static final String LABOR_RESOURCE_CODE = 'PS_LABOR_HOURS';

    /** productId -> hourly rate from the Negotiable Base RateCardEntry on the PS Labor Hours resource. */
    private static Map<Id, Decimal> usageRatesByProduct() {
        Map<Id, Decimal> rates = new Map<Id, Decimal>();
        for (RateCardEntry rce : [
            SELECT ProductId, Rate
            FROM RateCardEntry
            WHERE UsageResource.Code = :LABOR_RESOURCE_CODE
              AND RateCard.Type = 'Base'
              AND ProductId != null
        ]) {
            if (rce.Rate != null) {
                rates.put(rce.ProductId, rce.Rate);
            }
        }
        return rates;
    }

    /** productId -> Base RateCardEntry Id (the usage rate override target). */
    private static Map<Id, Id> rceIdByProduct() {
        Map<Id, Id> ids = new Map<Id, Id>();
        for (RateCardEntry rce : [
            SELECT Id, ProductId
            FROM RateCardEntry
            WHERE UsageResource.Code = :LABOR_RESOURCE_CODE
              AND RateCard.Type = 'Base'
              AND ProductId != null
        ]) {
            ids.put(rce.ProductId, rce.Id);
        }
        return ids;
    }

    private static List<RoleOption> rolesFor(String pattern) {
        Map<Id, Decimal> usageRate = usageRatesByProduct();
        Map<Id, Id> rceByProduct = rceIdByProduct();
        if (usageRate.isEmpty()) {
            return new List<RoleOption>();
        }
        Set<Id> productIds = usageRate.keySet();
        List<RoleOption> roles = new List<RoleOption>();
        // Anchor each role on its Term Monthly standard PricebookEntry.
        List<PricebookEntry> pbes = [
            SELECT Id, UnitPrice, Product2Id, Product2.Name, Product2.ProductCode
            FROM PricebookEntry
            WHERE IsActive = true
              AND Pricebook2.IsStandard = true
              AND ProductSellingModel.SellingModelType = 'TermDefined'
              AND ProductSellingModel.PricingTermUnit = 'Months'
              AND Product2Id IN :productIds
              AND (Product2.Name LIKE :pattern OR Product2.ProductCode LIKE :pattern)
            ORDER BY Product2.Name
            LIMIT 25
        ];
        for (PricebookEntry pbe : pbes) {
            RoleOption r = new RoleOption();
            r.productId = pbe.Product2Id;
            r.pbeId = pbe.Id;
            r.rceId = rceByProduct.get(pbe.Product2Id);
            r.code = pbe.Product2.ProductCode;
            r.name = pbe.Product2.Name;
            r.rate = usageRate.get(pbe.Product2Id);
            roles.add(r);
        }
        return roles;
    }

    /** Type-ahead search for staffable roles. */
    @AuraEnabled(cacheable=true)
    public static List<RoleOption> searchRoles(String term) {
        return rolesFor('%' + (term == null ? '' : term) + '%');
    }

    // ---- Profitability inputs -------------------------------------------------------
    /** Hourly cost (resolved cost book) and list rate for every staffable role, plus the target margin. */
    @AuraEnabled(cacheable=true)
    public static RoleEconomics getRoleEconomics() {
        RoleEconomics econ = new RoleEconomics();
        econ.targetMargin = PsCostBook.targetMargin();
        econ.roles = new List<RoleCost>();
        PsCostBook.Book book = PsCostBook.resolve();
        econ.costBookName = book == null ? null : book.name;

        Map<Id, Decimal> listRates = usageRatesByProduct();
        Map<Id, Decimal> costs = PsCostBook.costsByProduct(book == null ? null : book.id, listRates.keySet());
        for (Id pid : listRates.keySet()) {
            RoleCost rc = new RoleCost();
            rc.productId = pid;
            rc.listRate = listRates.get(pid);
            rc.cost = costs.get(pid);
            econ.roles.add(rc);
        }
        return econ;
    }

    // ---- Reload a saved estimate ----------------------------------------------------
    /**
     * Rebuilds the builder's phase/resource/week model from the PS_Estimate_Segment__c rows
     * persisted when the quote was generated, so an existing quote can be reopened and edited.
     */
    @AuraEnabled(cacheable=true)
    public static EstimateLoad getQuoteEstimate(String quoteId) {
        EstimateLoad load = new EstimateLoad();
        Quote q = [
            SELECT Id, Name, OpportunityId, Opportunity.Name,
                   AccountId, Account.Name, QuoteAccountId, QuoteAccount.Name
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        load.quoteId = q.Id;
        load.quoteName = q.Name;
        load.opportunityId = q.OpportunityId;
        load.opportunityName = q.Opportunity != null ? q.Opportunity.Name : null;
        load.accountName = q.QuoteAccount != null ? q.QuoteAccount.Name
            : (q.Account != null ? q.Account.Name : null);
        load.phases = new List<PhaseInput>();

        Map<Id, Id> rceByProduct = rceIdByProduct();
        Map<Id, Id> pbeByProduct = new Map<Id, Id>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE IsActive = true
              AND Pricebook2.IsStandard = true
              AND ProductSellingModel.SellingModelType = 'TermDefined'
              AND ProductSellingModel.PricingTermUnit = 'Months'
        ]) {
            pbeByProduct.put(pbe.Product2Id, pbe.Id);
        }

        List<PS_Estimate_Segment__c> rows = [
            SELECT Phase__c, PhaseStartDate__c, WeekIndex__c, Hours__c, Rate__c,
                   Product__c, Product__r.Name, Resource_Slot__c
            FROM PS_Estimate_Segment__c
            WHERE Quote__c = :quoteId
            ORDER BY PhaseStartDate__c NULLS FIRST, Phase__c, Product__r.Name,
                     Resource_Slot__c NULLS FIRST, WeekIndex__c
        ];

        // Group rows by phase (name + start), then by product + slot (each copy of a role is its own
        // row; rows saved before slots existed count as slot 1), filling the per-week hours array.
        Map<String, PhaseInput> phaseByKey = new Map<String, PhaseInput>();
        Map<String, Map<String, ResourceInput>> resByPhaseSlot = new Map<String, Map<String, ResourceInput>>();
        Map<String, Integer> weeksByPhase = new Map<String, Integer>();

        for (PS_Estimate_Segment__c s : rows) {
            String pkey = s.Phase__c + '|' + String.valueOf(s.PhaseStartDate__c);
            Integer wi = s.WeekIndex__c == null ? 0 : (Integer) s.WeekIndex__c;
            weeksByPhase.put(pkey, Math.max(weeksByPhase.containsKey(pkey) ? weeksByPhase.get(pkey) : 0, wi + 1));
            if (!phaseByKey.containsKey(pkey)) {
                PhaseInput p = new PhaseInput();
                p.name = s.Phase__c;
                p.startDate = s.PhaseStartDate__c == null ? null : String.valueOf(s.PhaseStartDate__c);
                p.resources = new List<ResourceInput>();
                phaseByKey.put(pkey, p);
                resByPhaseSlot.put(pkey, new Map<String, ResourceInput>());
                load.phases.add(p);
            }
        }
        // size hours arrays now that weeks are known, and populate
        for (PS_Estimate_Segment__c s : rows) {
            String pkey = s.Phase__c + '|' + String.valueOf(s.PhaseStartDate__c);
            Integer weeks = weeksByPhase.get(pkey);
            phaseByKey.get(pkey).weeks = weeks;
            Map<String, ResourceInput> bySlot = resByPhaseSlot.get(pkey);
            String skey = s.Product__c + '|' + (s.Resource_Slot__c == null ? 1 : (Integer) s.Resource_Slot__c);
            ResourceInput r = bySlot.get(skey);
            if (r == null) {
                r = new ResourceInput();
                r.productId = s.Product__c;
                r.roleName = s.Product__r != null ? s.Product__r.Name : null;
                r.pbeId = pbeByProduct.get(s.Product__c);
                r.rate = s.Rate__c;
                r.hours = new List<Decimal>();
                for (Integer i = 0; i < weeks; i++) { r.hours.add(0); }
                bySlot.put(skey, r);
                phaseByKey.get(pkey).resources.add(r);
            }
            // grow array if needed
            while (r.hours.size() < weeks) { r.hours.add(0); }
            Integer wi = s.WeekIndex__c == null ? 0 : (Integer) s.WeekIndex__c;
            if (wi < r.hours.size()) {
                r.hours[wi] = s.Hours__c == null ? 0 : s.Hours__c;
            }
        }
        return load;
    }

    // ---- Build ----------------------------------------------------------------------
    @AuraEnabled
    public static BuildResult buildQuote(String payload) {
        // Accept a JSON string (not a typed param): LWC imperative calls do not reliably marshal
        // nested custom Apex types, whereas JSON.deserialize of the same shape is reliable.
        try {
            QuoteRequest request = (QuoteRequest) JSON.deserialize(payload, QuoteRequest.class);
            return PsQuoteService.build(request);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Reprice the quote so it is order-ready. Called by the LWC immediately after buildQuote in a
     * SEPARATE transaction, because buildQuote does DML and Apex forbids callouts after DML.
     */
    @AuraEnabled
    public static void repriceQuote(String quoteId) {
        try {
            PsQuoteService.repriceQuote(quoteId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}
