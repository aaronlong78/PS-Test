/**
 * PsQuoteService
 * ==============
 * Usage-native PS/SOW quote builder. The component lives ON an existing Quote (created from the
 * Account via Quick Quote); build() writes the staffing estimate INTO that quote.
 *
 * The weekly ramp entered in psQuoteBuilder is an ESTIMATE only. On build we:
 *   0. Clear any prior PS content on the quote (role lines, their rate-card entries, estimate rows)
 *      so re-generating is idempotent. Non-role lines on the quote are left untouched.
 *   1. Add ONE QuoteLineItem per resource slot to the quote on the Term Monthly selling model at
 *      UnitPrice = 0 (a $0 usage-anchor subscription spanning the engagement), via the RLM Connect
 *      place API so the line is priced natively (no DML net-price hacks). The Nth copy of a role
 *      within a phase is slot N; the same role + slot across phases is one person and one line
 *      (e.g. 4 engineers in Build = 4 lines; a PM in Design and UAT = 1 line).
 *   2. Create a QuoteLineRateCardEntry per line carrying the NEGOTIATED hourly rate as the usage
 *      rate override (RateCardEntryId = the role's Base PS_LABOR_HOURS entry).
 *   3. Stamp reference custom fields on the line (Negotiated_Rate__c, Estimated_Hours__c).
 *   4. Persist the full weekly ramp into PS_Estimate_Segment__c so the builder can rebuild the grid,
 *      with the cost book hourly cost (Cost__c) snapshotted per row, and stamp estimated
 *      revenue / cost / margin on the Quote (PS_Estimated_*__c).
 *   5. Reprice so the quote is order-ready; native quote-to-order then carries the negotiated rate.
 */
public with sharing class PsQuoteService {

    private static final String API_VERSION = 'v68.0';
    private static final String PLACE = '/connect/rev/sales-transaction/actions/place';
    private static final String LABOR_RESOURCE_CODE = 'PS_LABOR_HOURS';

    public class PsQuoteException extends Exception {}

    // Consolidated per-slot view across all phases: the Nth copy of a role within a phase is slot N,
    // and the same role + slot in every phase is the same person (one quote line).
    private class Resource {
        Id productId;
        Integer slot;
        String pbeId;
        Decimal rate;
        Decimal cost;                 // hourly cost from the cost book (null = no entry)
        Decimal totalHours = 0;
    }

    // ---------------------------------------------------------------------------------
    // Entry point
    // ---------------------------------------------------------------------------------
    // Apex forbids callouts after DML, so the work is ordered: (1) ONE place callout that deletes
    // prior role lines, adds the new lines, and creates their QuoteLineRateCardEntry overrides, then
    // (2) the DML (line custom fields + estimate rows). The quote-level reprice that a line DML
    // requires is a separate @AuraEnabled call (repriceQuote) in its own, DML-free transaction.
    public static PsQuoteController.BuildResult build(PsQuoteController.QuoteRequest req) {
        validate(req);
        String quoteId = req.quoteId;

        Map<Id, Id> rceByProduct = rceIdByProduct();
        Set<Id> roleProductIds = rceByProduct.keySet();

        // SOQL only (no DML before the callout): prior PS role lines to replace.
        List<QuoteLineItem> oldLines = roleProductIds.isEmpty() ? new List<QuoteLineItem>() : [
            SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId AND Product2Id IN :roleProductIds
        ];

        // Consolidate resources by product + slot across every phase (one line per slot) and compute
        // the engagement window (earliest phase start -> latest phase end). Slots are numbered per
        // phase in input order; slotsByPhase holds each input resource's slot for the segment rows.
        Map<String, Resource> bySlot = new Map<String, Resource>();
        Map<Id, Integer> slotCountByProduct = new Map<Id, Integer>();
        List<List<Integer>> slotsByPhase = new List<List<Integer>>();
        Date engStart;
        Date engEnd;
        for (PsQuoteController.PhaseInput phase : req.phases) {
            Date pStart = Date.valueOf(phase.startDate);
            Date pEnd = pStart.addDays(phase.weeks * 7 - 1);
            if (engStart == null || pStart < engStart) { engStart = pStart; }
            if (engEnd == null || pEnd > engEnd) { engEnd = pEnd; }
            Map<Id, Integer> seenInPhase = new Map<Id, Integer>();
            List<Integer> phaseSlots = new List<Integer>();
            for (PsQuoteController.ResourceInput r : phase.resources) {
                Id pid = (Id) r.productId;
                Integer slot = (seenInPhase.containsKey(pid) ? seenInPhase.get(pid) : 0) + 1;
                seenInPhase.put(pid, slot);
                phaseSlots.add(slot);
                String key = slotKey(pid, slot);
                Resource agg = bySlot.get(key);
                if (agg == null) {
                    agg = new Resource();
                    agg.productId = pid;
                    agg.slot = slot;
                    agg.pbeId = r.pbeId;
                    agg.rate = r.rate;              // one global rate per role
                    bySlot.put(key, agg);
                    Integer known = slotCountByProduct.get(pid);
                    slotCountByProduct.put(pid, known == null ? slot : Math.max(known, slot));
                }
                for (Decimal h : r.hours) {
                    agg.totalHours += (h == null ? 0 : h);
                }
            }
            slotsByPhase.add(phaseSlots);
        }

        // Costs are looked up server-side (never trusted from the client payload).
        PsCostBook.Book book = PsCostBook.resolve();
        Map<Id, Decimal> costs = PsCostBook.costsByProduct(book == null ? null : book.id, slotCountByProduct.keySet());
        for (Resource agg : bySlot.values()) {
            agg.cost = costs.get(agg.productId);
        }

        // 1. One place callout: delete prior role lines, add the new $0 monthly lines, and create a
        //    QuoteLineRateCardEntry (negotiated rate) per line. Custom fields are NOT accepted by the
        //    place graph, so they are stamped by DML below.
        List<Object> records = new List<Object>();
        records.add(patchRef('refQuote', 'Quote', quoteId));
        Integer di = 0;
        for (QuoteLineItem old : oldLines) {
            records.add(deleteRec('del' + di, 'QuoteLineItem', old.Id));
            di++;
        }
        // Lines are created per product in ascending slot order; step 2 relies on that order.
        List<Resource> slots = new List<Resource>();
        for (Id pid : slotCountByProduct.keySet()) {
            for (Integer s = 1; s <= slotCountByProduct.get(pid); s++) {
                slots.add(bySlot.get(slotKey(pid, s)));
            }
        }
        Integer li = 0;
        for (Resource agg : slots) {
            String lineRef = 'li' + li;
            records.add(lineRecord(lineRef, quoteId, agg, iso(engStart), iso(engEnd)));
            Id rceId = rceByProduct.get(agg.productId);
            if (rceId != null && agg.rate != null) {
                records.add(qlrceRec('rce' + li, '@{' + lineRef + '.id}', rceId, agg.rate));
            }
            li++;
        }
        place(graph('psQuote', records), 'replace resource lines');

        // 2. Map product + slot -> newly created line (prior role lines were deleted in the same
        //    callout). Lines of the same product are told apart by creation order.
        Map<String, Id> qliBySlot = new Map<String, Id>();
        Map<Id, Integer> nextSlot = new Map<Id, Integer>();
        for (QuoteLineItem ln : [
            SELECT Id, Product2Id FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND Product2Id IN :roleProductIds
            ORDER BY CreatedDate, Id
        ]) {
            Integer s = (nextSlot.containsKey(ln.Product2Id) ? nextSlot.get(ln.Product2Id) : 0) + 1;
            nextSlot.put(ln.Product2Id, s);
            qliBySlot.put(slotKey(ln.Product2Id, s), ln.Id);
        }

        // 3. DML (after the callout): reference custom fields on each line, plus a "Role #N" label
        //    when a role is staffed more than once so the lines can be told apart.
        Map<Id, Product2> products = new Map<Id, Product2>([
            SELECT Id, Name FROM Product2 WHERE Id IN :slotCountByProduct.keySet()
        ]);
        List<QuoteLineItem> lineUpdates = new List<QuoteLineItem>();
        for (Resource agg : slots) {
            Id qliId = qliBySlot.get(slotKey(agg.productId, agg.slot));
            if (qliId == null) { continue; }
            QuoteLineItem upd = new QuoteLineItem(
                Id = qliId,
                Negotiated_Rate__c = agg.rate,
                Estimated_Hours__c = agg.totalHours
            );
            if (slotCountByProduct.get(agg.productId) > 1 && products.containsKey(agg.productId)) {
                upd.Description = products.get(agg.productId).Name + ' #' + agg.slot;
            }
            lineUpdates.add(upd);
        }
        if (!lineUpdates.isEmpty()) { update lineUpdates; }

        // 4. Replace the persisted weekly ramp estimate.
        List<PS_Estimate_Segment__c> oldSegs = [
            SELECT Id FROM PS_Estimate_Segment__c WHERE Quote__c = :quoteId
        ];
        if (!oldSegs.isEmpty()) { delete oldSegs; }
        List<PS_Estimate_Segment__c> segs = new List<PS_Estimate_Segment__c>();
        for (Integer pi = 0; pi < req.phases.size(); pi++) {
            PsQuoteController.PhaseInput phase = req.phases[pi];
            Date pStart = Date.valueOf(phase.startDate);
            for (Integer ri = 0; ri < phase.resources.size(); ri++) {
                PsQuoteController.ResourceInput r = phase.resources[ri];
                Id pid = (Id) r.productId;
                Integer slot = slotsByPhase[pi][ri];
                for (Integer w = 0; w < r.hours.size(); w++) {
                    Decimal h = r.hours[w];
                    segs.add(new PS_Estimate_Segment__c(
                        Quote__c = quoteId,
                        QuoteLineItem__c = qliBySlot.get(slotKey(pid, slot)),
                        Product__c = pid,
                        Resource_Slot__c = slot,
                        Phase__c = phase.name,
                        PhaseStartDate__c = pStart,
                        WeekIndex__c = w,
                        Hours__c = (h == null ? 0 : h),
                        Rate__c = r.rate,
                        Cost__c = costs.get(pid)
                    ));
                }
            }
        }
        if (!segs.isEmpty()) { insert segs; }

        // 5. Estimated revenue / cost / margin on the quote.
        Profit profit = profitOf(slots);
        update new Quote(
            Id = quoteId,
            PS_Estimated_Revenue__c = profit.revenue,
            PS_Estimated_Cost__c = profit.cost,
            PS_Estimated_Margin__c = profit.margin,
            PS_Estimated_Margin_Pct__c = profit.marginPct,
            PS_Cost_Book_Name__c = book == null ? null : book.name
        );

        PsQuoteController.BuildResult res = summarize(quoteId, slots.size(), segs.size());
        res.estimatedRevenue = profit.revenue;
        res.estimatedCost = profit.cost;
        res.marginAmount = profit.margin;
        res.marginPct = profit.marginPct;
        return res;
    }

    private class Profit {
        Decimal revenue = 0;
        Decimal cost;
        Decimal margin;
        Decimal marginPct;
    }

    // Margin covers only resources that have a cost, so a missing cost never reads as 100% margin.
    @TestVisible
    private static Profit profitOf(List<Resource> resources) {
        Profit p = new Profit();
        Decimal costedRevenue = 0;
        Decimal cost = 0;
        Boolean anyCost = false;
        for (Resource agg : resources) {
            Decimal rev = agg.totalHours * (agg.rate == null ? 0 : agg.rate);
            p.revenue += rev;
            if (agg.cost != null) {
                anyCost = true;
                costedRevenue += rev;
                cost += agg.totalHours * agg.cost;
            }
        }
        if (anyCost) {
            p.cost = cost;
            p.margin = costedRevenue - cost;
            p.marginPct = costedRevenue == 0 ? null : (p.margin / costedRevenue * 100).setScale(2);
        }
        return p;
    }

    /**
     * System reprice of the whole quote so it is order-ready. Must run in its own transaction with
     * NO pending DML (Apex forbids callouts after DML) - the LWC calls this right after build().
     */
    public static void repriceQuote(String quoteId) {
        if (Test.isRunningTest() || String.isBlank(quoteId)) { return; }
        List<Object> records = new List<Object>{ patchRef('q', 'Quote', quoteId) };
        place(graph('reprice', records), 'reprice quote');
    }

    // ---------------------------------------------------------------------------------
    // Rate-card lookup
    // ---------------------------------------------------------------------------------
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

    // ---------------------------------------------------------------------------------
    // REST callout helpers
    // ---------------------------------------------------------------------------------
    // Lightning (@AuraEnabled) sessions are not valid for REST callouts (HTTP 401). A Visualforce
    // page exposing {!$Api.Session_ID} yields an API-enabled session for same-org callouts.
    private static String cachedSid;
    private static String apiSessionId() {
        if (cachedSid != null) {
            return cachedSid;
        }
        cachedSid = UserInfo.getSessionId();
        if (!Test.isRunningTest()) {
            try {
                String body = Page.PsSessionId.getContent().toString();
                if (String.isNotBlank(body)) {
                    cachedSid = body.trim();
                }
            } catch (Exception e) {
                // fall back to the Lightning session id
            }
        }
        return cachedSid;
    }

    private static Map<String, Object> rest(String method, String path, Object body) {
        HttpRequest r = new HttpRequest();
        r.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/data/' + API_VERSION + path);
        r.setMethod(method);
        r.setTimeout(120000);
        r.setHeader('Authorization', 'Bearer ' + apiSessionId());
        r.setHeader('Content-Type', 'application/json');
        if (body != null) {
            r.setBody(JSON.serialize(body, true));
        }
        HttpResponse resp = new Http().send(r);
        Object parsed = String.isBlank(resp.getBody()) ? new Map<String, Object>() : JSON.deserializeUntyped(resp.getBody());
        Map<String, Object> out = (parsed instanceof Map<String, Object>) ? (Map<String, Object>) parsed : new Map<String, Object>{ 'raw' => parsed };
        out.put('_status', resp.getStatusCode());
        return out;
    }

    private static Map<String, Object> place(Object body, String label) {
        Map<String, Object> b = rest('POST', PLACE, body);
        Boolean ok = (b.get('isSuccess') == true) || ((Integer) b.get('_status') < 300 && b.get('isSuccess') == null);
        if (!ok) {
            throw new PsQuoteException('FAILED ' + label + ': HTTP ' + b.get('_status') + ' ' +
                JSON.serialize(b.containsKey('errorResponse') ? b.get('errorResponse') : b));
        }
        return b;
    }

    // ---------------------------------------------------------------------------------
    // Graph / record builders
    // ---------------------------------------------------------------------------------
    private static Map<String, Object> graph(String graphId, List<Object> records) {
        return new Map<String, Object>{
            'pricingPref' => 'System',
            'configurationPref' => new Map<String, Object>{ 'configurationMethod' => 'Skip' },
            'graph' => new Map<String, Object>{ 'graphId' => graphId, 'records' => records }
        };
    }

    // One $0 Term Monthly usage-anchor line per resource slot spanning the engagement. The negotiated
    // hourly rate is NOT on the line price; it is applied via QuoteLineRateCardEntry (see build()).
    private static Map<String, Object> lineRecord(String refId, String quoteId, Resource agg,
            String startDate, String endDate) {
        return new Map<String, Object>{
            'referenceId' => refId,
            'record' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineItem', 'method' => 'POST' },
                'QuoteId' => quoteId,
                'Product2Id' => agg.productId, 'PricebookEntryId' => agg.pbeId,
                'Quantity' => 1, 'UnitPrice' => 0,
                'BillingFrequency' => 'Monthly', 'PeriodBoundary' => 'Anniversary',
                'StartDate' => startDate, 'EndDate' => endDate
            }
        };
    }

    private static Map<String, Object> patchRef(String refId, String type, String recId) {
        return new Map<String, Object>{
            'referenceId' => refId,
            'record' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => type, 'method' => 'PATCH', 'id' => recId }
            }
        };
    }

    private static Map<String, Object> deleteRec(String refId, String type, Id recId) {
        return new Map<String, Object>{
            'referenceId' => refId,
            'record' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => type, 'method' => 'DELETE', 'id' => recId }
            }
        };
    }

    // The negotiated hourly rate as the usage rate override, created inline with the line so no
    // pricing-dirtying DML is needed for it. IsChosenRate is REST-only; one entry per line = the rate used.
    private static Map<String, Object> qlrceRec(String refId, String lineRef, Id rceId, Decimal negotiatedRate) {
        return new Map<String, Object>{
            'referenceId' => refId,
            'record' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'QuoteLineRateCardEntry', 'method' => 'POST' },
                'QuoteLineItemId' => lineRef, 'RateCardEntryId' => rceId, 'NegotiatedRate' => negotiatedRate
            }
        };
    }

    // ---------------------------------------------------------------------------------
    // Validation + summary
    // ---------------------------------------------------------------------------------
    private static void validate(PsQuoteController.QuoteRequest req) {
        if (req == null || String.isBlank(req.quoteId)) {
            throw new PsQuoteException('A quote is required. Open the builder from a Quote record.');
        }
        if (req.phases == null || req.phases.isEmpty()) {
            throw new PsQuoteException('Add at least one phase.');
        }
        for (PsQuoteController.PhaseInput p : req.phases) {
            if (String.isBlank(p.name) || String.isBlank(p.startDate) || p.weeks == null || p.weeks < 1) {
                throw new PsQuoteException('Each phase needs a name, start date, and at least one week.');
            }
            if (p.resources == null || p.resources.isEmpty()) {
                throw new PsQuoteException('Phase "' + p.name + '" needs at least one resource.');
            }
            for (PsQuoteController.ResourceInput r : p.resources) {
                if (String.isBlank(r.productId) || String.isBlank(r.pbeId) || r.hours == null || r.hours.size() != p.weeks) {
                    throw new PsQuoteException('Each resource in "' + p.name + '" needs a role and hours for every week.');
                }
            }
        }
    }

    private static PsQuoteController.BuildResult summarize(String quoteId, Integer lineCount, Integer segmentCount) {
        PsQuoteController.BuildResult res = new PsQuoteController.BuildResult();
        res.quoteId = quoteId;
        res.quoteUrl = URL.getOrgDomainUrl().toExternalForm() + '/' + quoteId;
        res.lineCount = lineCount;
        res.segmentCount = segmentCount;
        res.totalNet = 0;
        for (AggregateResult ar : [
            SELECT SUM(NetTotalPrice) total FROM QuoteLineItem WHERE QuoteId = :quoteId
        ]) {
            res.totalNet = (Decimal) ar.get('total');
        }
        if (res.totalNet == null) {
            res.totalNet = 0;
        }
        return res;
    }

    private static String slotKey(Id productId, Integer slot) {
        return productId + '|' + slot;
    }

    private static String iso(Date d) {
        return DateTime.newInstance(d.year(), d.month(), d.day()).format('yyyy-MM-dd');
    }
}
