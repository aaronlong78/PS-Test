/**
 * PsCostBook
 * ==========
 * Resolves the cost book and per-role hourly costs at runtime so the package is portable across
 * orgs (CostBook / CostBookEntry are data, so their Ids differ per org and are never hardcoded).
 *
 * Resolution order:
 *   1. PS_Quote_Settings__mdt.Default.Cost_Book_Name__c (a CostBook Name; CMDT cannot hold a lookup).
 *   2. The org's default cost book (CostBook.IsDefault = true).
 *   3. None -> no costs; the builder shows "no cost book" and margin fields stay blank.
 *
 * CostBookEntry.Cost is treated as an HOURLY cost, matching the hourly usage rate.
 */
public without sharing class PsCostBook {

    private static final String SETTINGS_RECORD = 'Default';
    private static final Decimal DEFAULT_TARGET_MARGIN = 40;

    @TestVisible private static PS_Quote_Settings__mdt settingsOverride;

    public class Book {
        public Id id;
        public String name;
    }

    private static PS_Quote_Settings__mdt settings() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        return PS_Quote_Settings__mdt.getInstance(SETTINGS_RECORD);
    }

    public static Decimal targetMargin() {
        PS_Quote_Settings__mdt s = settings();
        return (s != null && s.Target_Margin_Pct__c != null) ? s.Target_Margin_Pct__c : DEFAULT_TARGET_MARGIN;
    }

    /** The cost book to use, or null when none is configured. */
    public static Book resolve() {
        PS_Quote_Settings__mdt s = settings();
        String configured = (s == null) ? null : s.Cost_Book_Name__c;
        List<CostBook> books = String.isNotBlank(configured)
            ? [SELECT Id, Name FROM CostBook WHERE Name = :configured LIMIT 1]
            : [SELECT Id, Name FROM CostBook WHERE IsDefault = true LIMIT 1];
        if (books.isEmpty()) {
            return null;
        }
        Book b = new Book();
        b.id = books[0].Id;
        b.name = books[0].Name;
        return b;
    }

    /** productId -> hourly cost from entries effective now; the latest EffectiveFrom wins. */
    public static Map<Id, Decimal> costsByProduct(Id costBookId, Set<Id> productIds) {
        Map<Id, Decimal> costs = new Map<Id, Decimal>();
        if (costBookId == null) {
            return costs;
        }
        Datetime now = Datetime.now();
        List<CostBookEntry> entries = (productIds == null)
            ? [
                SELECT ProductId, Cost FROM CostBookEntry
                WHERE CostBookId = :costBookId
                  AND EffectiveFrom <= :now
                  AND (EffectiveTo = null OR EffectiveTo >= :now)
                ORDER BY EffectiveFrom ASC
              ]
            : [
                SELECT ProductId, Cost FROM CostBookEntry
                WHERE CostBookId = :costBookId
                  AND ProductId IN :productIds
                  AND EffectiveFrom <= :now
                  AND (EffectiveTo = null OR EffectiveTo >= :now)
                ORDER BY EffectiveFrom ASC
              ];
        for (CostBookEntry e : entries) {
            if (e.Cost != null) {
                costs.put(e.ProductId, e.Cost);
            }
        }
        return costs;
    }
}
