@IsTest
private class PsQuoteControllerTest {

    @IsTest
    static void searchRolesRunsWithoutError() {
        Test.startTest();
        List<PsQuoteController.RoleOption> searched = PsQuoteController.searchRoles('Eng');
        Test.stopTest();
        System.assertNotEquals(null, searched, 'searchRoles should always return a list');
    }

    @IsTest
    static void buildQuoteValidatesInput() {
        // No quote / no phases -> AuraHandledException from validation.
        PsQuoteController.QuoteRequest req = new PsQuoteController.QuoteRequest();
        Boolean threw = false;
        Test.startTest();
        try {
            PsQuoteController.buildQuote(JSON.serialize(req));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Expected validation to reject a request with no quote/phases');
    }

    @IsTest
    static void buildQuoteConsolidatesAndPersistsEstimate() {
        // The same resource (product) appears in two phases to prove it consolidates into one line
        // and that the full weekly ramp is persisted as estimate rows. (The negotiated-rate override
        // path requires the RLM rate-card chain, which is validated live, not in this unit test.)
        Pricebook2 standardPb = new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        update standardPb;
        Product2 p = new Product2(Name = 'Solutions Architect', ProductCode = 'QB-SRV-SAT', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = standardPb.Id, Product2Id = p.Id, UnitPrice = 0, IsActive = true);
        insert pbe;
        Opportunity o = new Opportunity(Name = 'Build Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(Name = 'Existing Quote', OpportunityId = o.Id, Pricebook2Id = standardPb.Id);
        insert q;

        Test.setMock(HttpCalloutMock.class, new ConnectMock(q.Id));

        PsQuoteController.ResourceInput r1 = resource(p.Id, pbe.Id, 300, new List<Decimal>{ 20, 20 });
        PsQuoteController.ResourceInput r2 = resource(p.Id, pbe.Id, 300, new List<Decimal>{ 40, 40 });
        PsQuoteController.PhaseInput ph1 = phase('Discovery', Date.today(), 2, new List<PsQuoteController.ResourceInput>{ r1 });
        PsQuoteController.PhaseInput ph2 = phase('Delivery', Date.today().addDays(14), 2, new List<PsQuoteController.ResourceInput>{ r2 });
        PsQuoteController.QuoteRequest req = new PsQuoteController.QuoteRequest();
        req.quoteId = q.Id;
        req.phases = new List<PsQuoteController.PhaseInput>{ ph1, ph2 };

        Test.startTest();
        PsQuoteController.BuildResult result = PsQuoteController.buildQuote(JSON.serialize(req));
        Test.stopTest();

        System.assertEquals(q.Id, result.quoteId, 'Build operates on the existing quote');
        System.assertEquals(1, result.lineCount, 'The same role slot across two phases should consolidate to one line');
        System.assertEquals(4, result.segmentCount, '2 phases x 1 resource x 2 weeks = 4 estimate rows');
        System.assertEquals(4, [SELECT COUNT() FROM PS_Estimate_Segment__c WHERE Quote__c = :q.Id]);
    }

    @IsTest
    static void buildQuoteCreatesOneLinePerResourceSlot() {
        // PM in Design and UAT is one person (one line); 4 engineers in Build are 4 people (4 lines).
        Pricebook2 standardPb = new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        update standardPb;
        Product2 pm = new Product2(Name = 'Project Manager', ProductCode = 'QB-SRV-PMN', IsActive = true);
        Product2 eng = new Product2(Name = 'Implementation Engineer', ProductCode = 'QB-SRV-IMP', IsActive = true);
        insert new List<Product2>{ pm, eng };
        PricebookEntry pmPbe = new PricebookEntry(Pricebook2Id = standardPb.Id, Product2Id = pm.Id, UnitPrice = 0, IsActive = true);
        PricebookEntry engPbe = new PricebookEntry(Pricebook2Id = standardPb.Id, Product2Id = eng.Id, UnitPrice = 0, IsActive = true);
        insert new List<PricebookEntry>{ pmPbe, engPbe };
        Opportunity o = new Opportunity(Name = 'Slot Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(Name = 'Slot Quote', OpportunityId = o.Id, Pricebook2Id = standardPb.Id);
        insert q;
        Test.setMock(HttpCalloutMock.class, new ConnectMock(q.Id));

        List<PsQuoteController.ResourceInput> buildRes = new List<PsQuoteController.ResourceInput>();
        for (Integer i = 1; i <= 4; i++) {
            buildRes.add(resource(eng.Id, engPbe.Id, 150, new List<Decimal>{ 10 * i }));
        }
        PsQuoteController.QuoteRequest req = new PsQuoteController.QuoteRequest();
        req.quoteId = q.Id;
        req.phases = new List<PsQuoteController.PhaseInput>{
            phase('Design', Date.today(), 1, new List<PsQuoteController.ResourceInput>{
                resource(pm.Id, pmPbe.Id, 200, new List<Decimal>{ 20 })
            }),
            phase('Build', Date.today().addDays(7), 1, buildRes),
            phase('UAT', Date.today().addDays(14), 1, new List<PsQuoteController.ResourceInput>{
                resource(pm.Id, pmPbe.Id, 200, new List<Decimal>{ 20 })
            })
        };

        Test.startTest();
        PsQuoteController.BuildResult result = PsQuoteController.buildQuote(JSON.serialize(req));
        Test.stopTest();

        System.assertEquals(5, result.lineCount, '1 PM line across Design + UAT, plus 4 engineer lines');
        System.assertEquals(6, result.segmentCount);
        Map<Integer, Decimal> engHoursBySlot = new Map<Integer, Decimal>();
        for (PS_Estimate_Segment__c s : [
            SELECT Product__c, Resource_Slot__c, Hours__c FROM PS_Estimate_Segment__c WHERE Quote__c = :q.Id
        ]) {
            if (s.Product__c == pm.Id) {
                System.assertEquals(1, s.Resource_Slot__c, 'PM is the same slot in both phases');
            } else {
                engHoursBySlot.put((Integer) s.Resource_Slot__c, s.Hours__c);
            }
        }
        System.assertEquals(new Set<Integer>{ 1, 2, 3, 4 }, engHoursBySlot.keySet());
        System.assertEquals(30, engHoursBySlot.get(3), 'Each engineer keeps its own hours');
    }

    @IsTest
    static void buildQuoteStampsCostAndMargin() {
        Pricebook2 standardPb = new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        update standardPb;
        Product2 costed = new Product2(Name = 'Project Manager', ProductCode = 'QB-SRV-PMN', IsActive = true);
        Product2 uncosted = new Product2(Name = 'Solutions Architect', ProductCode = 'QB-SRV-SAT', IsActive = true);
        insert new List<Product2>{ costed, uncosted };
        PricebookEntry pbe1 = new PricebookEntry(Pricebook2Id = standardPb.Id, Product2Id = costed.Id, UnitPrice = 0, IsActive = true);
        PricebookEntry pbe2 = new PricebookEntry(Pricebook2Id = standardPb.Id, Product2Id = uncosted.Id, UnitPrice = 0, IsActive = true);
        insert new List<PricebookEntry>{ pbe1, pbe2 };
        CostBook book = defaultBook('Standard Cost Book');
        insert entry(book.Id, costed.Id, 75, Datetime.now().addDays(-30), null);

        Opportunity o = new Opportunity(Name = 'Margin Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(Name = 'Margin Quote', OpportunityId = o.Id, Pricebook2Id = standardPb.Id);
        insert q;
        Test.setMock(HttpCalloutMock.class, new ConnectMock(q.Id));

        PsQuoteController.QuoteRequest req = new PsQuoteController.QuoteRequest();
        req.quoteId = q.Id;
        req.phases = new List<PsQuoteController.PhaseInput>{
            phase('Delivery', Date.today(), 2, new List<PsQuoteController.ResourceInput>{
                resource(costed.Id, pbe1.Id, 100, new List<Decimal>{ 40, 40 }),
                resource(uncosted.Id, pbe2.Id, 250, new List<Decimal>{ 10, 10 })
            })
        };

        Test.startTest();
        PsQuoteController.BuildResult result = PsQuoteController.buildQuote(JSON.serialize(req));
        Test.stopTest();

        // Revenue covers every role; cost and margin cover only the costed role (80h x 100 vs 80h x 75).
        System.assertEquals(13000, result.estimatedRevenue);
        System.assertEquals(6000, result.estimatedCost);
        System.assertEquals(2000, result.marginAmount);
        System.assertEquals(25, result.marginPct);

        Quote saved = [
            SELECT PS_Estimated_Revenue__c, PS_Estimated_Cost__c, PS_Estimated_Margin__c,
                   PS_Estimated_Margin_Pct__c, PS_Cost_Book_Name__c
            FROM Quote WHERE Id = :q.Id
        ];
        System.assertEquals(13000, saved.PS_Estimated_Revenue__c);
        System.assertEquals(6000, saved.PS_Estimated_Cost__c);
        System.assertEquals(2000, saved.PS_Estimated_Margin__c);
        System.assertEquals(25, saved.PS_Estimated_Margin_Pct__c);
        System.assertEquals('Standard Cost Book', saved.PS_Cost_Book_Name__c);

        for (PS_Estimate_Segment__c s : [SELECT Product__c, Cost__c FROM PS_Estimate_Segment__c WHERE Quote__c = :q.Id]) {
            System.assertEquals(s.Product__c == costed.Id ? 75 : null, s.Cost__c, 'Cost snapshot per segment');
        }
    }

    @IsTest
    static void costBookUsesDefaultAndEffectiveDating() {
        Product2 p = new Product2(Name = 'Project Manager', IsActive = true);
        insert p;
        CostBook book = defaultBook('Standard Cost Book');
        insert new List<CostBookEntry>{
            entry(book.Id, p.Id, 50, Datetime.now().addDays(-60), Datetime.now().addDays(-31)),
            entry(book.Id, p.Id, 75, Datetime.now().addDays(-30), null),
            entry(book.Id, p.Id, 90, Datetime.now().addDays(30), null)
        };

        Test.startTest();
        PsCostBook.Book resolved = PsCostBook.resolve();
        Map<Id, Decimal> costs = PsCostBook.costsByProduct(resolved.id, new Set<Id>{ p.Id });
        Test.stopTest();

        System.assertEquals(book.Id, resolved.id, 'Falls back to the default cost book');
        System.assertEquals(75, costs.get(p.Id), 'Only the currently effective entry applies');
    }

    @IsTest
    static void costBookHonorsConfiguredName() {
        defaultBook('Standard Cost Book');
        CostBook named = new CostBook(Name = 'Partner Cost Book', IsDefault = false, EffectiveFrom = Datetime.now().addDays(-1));
        insert named;
        PsCostBook.settingsOverride = new PS_Quote_Settings__mdt(Cost_Book_Name__c = 'Partner Cost Book', Target_Margin_Pct__c = 30);

        Test.startTest();
        PsCostBook.Book resolved = PsCostBook.resolve();
        Decimal target = PsCostBook.targetMargin();
        Test.stopTest();

        System.assertEquals(named.Id, resolved.id, 'The configured cost book name wins over the default');
        System.assertEquals(30, target);
    }

    @IsTest
    static void roleEconomicsWithoutCostBook() {
        PsCostBook.settingsOverride = new PS_Quote_Settings__mdt();

        Test.startTest();
        PsQuoteController.RoleEconomics econ = PsQuoteController.getRoleEconomics();
        Test.stopTest();

        System.assertEquals(null, econ.costBookName, 'No cost book configured in this org');
        System.assertEquals(40, econ.targetMargin, 'Default target margin');
        System.assertNotEquals(null, econ.roles);
    }

    @IsTest
    static void getQuoteEstimateRebuildsPhases() {
        Opportunity o = new Opportunity(Name = 'Reload Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(Name = 'Reload Quote', OpportunityId = o.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert q;
        Product2 p = new Product2(Name = 'Project Manager', IsActive = true);
        insert p;

        Date start = Date.today();
        List<PS_Estimate_Segment__c> segs = new List<PS_Estimate_Segment__c>();
        for (Integer w = 0; w < 2; w++) {
            segs.add(new PS_Estimate_Segment__c(
                Quote__c = q.Id, Product__c = p.Id, Phase__c = 'Discovery',
                PhaseStartDate__c = start, WeekIndex__c = w, Hours__c = 40, Rate__c = 120
            ));
        }
        insert segs;

        Test.startTest();
        PsQuoteController.EstimateLoad load = PsQuoteController.getQuoteEstimate(q.Id);
        Test.stopTest();

        System.assertEquals('Reload Quote', load.quoteName);
        System.assertEquals(o.Id, load.opportunityId);
        System.assertEquals(1, load.phases.size(), 'One phase');
        System.assertEquals('Discovery', load.phases[0].name);
        System.assertEquals(2, load.phases[0].weeks, 'Two weeks reconstructed');
        System.assertEquals(1, load.phases[0].resources.size(), 'One resource');
        System.assertEquals(40, load.phases[0].resources[0].hours[0]);
        System.assertEquals(40, load.phases[0].resources[0].hours[1]);
        System.assertEquals(120, load.phases[0].resources[0].rate);
    }

    @IsTest
    static void getQuoteEstimateKeepsEachResourceSlot() {
        Opportunity o = new Opportunity(Name = 'Reload Slot Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(Name = 'Reload Slot Quote', OpportunityId = o.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert q;
        Product2 p = new Product2(Name = 'Implementation Engineer', IsActive = true);
        insert p;

        List<PS_Estimate_Segment__c> segs = new List<PS_Estimate_Segment__c>();
        for (Integer slot = 1; slot <= 4; slot++) {
            for (Integer w = 0; w < 2; w++) {
                segs.add(new PS_Estimate_Segment__c(
                    Quote__c = q.Id, Product__c = p.Id, Phase__c = 'Build', Resource_Slot__c = slot,
                    PhaseStartDate__c = Date.today(), WeekIndex__c = w, Hours__c = 10 * slot, Rate__c = 150
                ));
            }
        }
        insert segs;

        Test.startTest();
        PsQuoteController.EstimateLoad load = PsQuoteController.getQuoteEstimate(q.Id);
        Test.stopTest();

        System.assertEquals(1, load.phases.size());
        System.assertEquals(4, load.phases[0].resources.size(), 'Four engineers reload as four rows');
        for (Integer i = 0; i < 4; i++) {
            System.assertEquals(10 * (i + 1), load.phases[0].resources[i].hours[0]);
            System.assertEquals(10 * (i + 1), load.phases[0].resources[i].hours[1]);
        }
    }

    // ---- helpers --------------------------------------------------------------------
    private static CostBook defaultBook(String name) {
        CostBook b = new CostBook(Name = name, IsDefault = true, EffectiveFrom = Datetime.now().addDays(-365));
        insert b;
        return b;
    }

    private static CostBookEntry entry(Id bookId, Id productId, Decimal cost, Datetime fromDt, Datetime toDt) {
        return new CostBookEntry(CostBookId = bookId, ProductId = productId, Cost = cost,
            EffectiveFrom = fromDt, EffectiveTo = toDt);
    }

    private static PsQuoteController.ResourceInput resource(Id productId, Id pbeId, Decimal rate, List<Decimal> hours) {
        PsQuoteController.ResourceInput r = new PsQuoteController.ResourceInput();
        r.productId = productId;
        r.pbeId = pbeId;
        r.rate = rate;
        r.hours = hours;
        return r;
    }

    private static PsQuoteController.PhaseInput phase(String name, Date startDate, Integer weeks, List<PsQuoteController.ResourceInput> resources) {
        PsQuoteController.PhaseInput ph = new PsQuoteController.PhaseInput();
        ph.name = name;
        ph.startDate = String.valueOf(startDate);
        ph.weeks = weeks;
        ph.resources = resources;
        return ph;
    }

    /** Minimal mock for the Connect place endpoint. */
    private class ConnectMock implements HttpCalloutMock {
        private Id quoteId;
        ConnectMock(Id quoteId) { this.quoteId = quoteId; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"isSuccess":true,"salesTransactionId":"' + quoteId + '"}');
            return res;
        }
    }
}
