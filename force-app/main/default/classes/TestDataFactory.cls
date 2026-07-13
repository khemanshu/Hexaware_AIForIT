/**
 * @description Centralized factory for creating test data with sensible defaults.
 *              All methods accept a doInsert flag for flexibility.
 *              Bulk methods create multiple records; single-record methods delegate to bulk.
 */
@isTest
public class TestDataFactory {

    private static Integer contactCounter = 0;

    // ─── Accounts ─────────────────────────────────────────────────────────

    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(
                Name = 'Test Account ' + i
            ));
        }
        if (doInsert) {
            insert accounts;
        }
        return accounts;
    }

    public static Account createAccount(Boolean doInsert) {
        return createAccounts(1, doInsert)[0];
    }

    // ─── Contacts ─────────────────────────────────────────────────────────

    /**
     * Creates Contacts distributed evenly across the given Accounts.
     * @param accounts Accounts to attach Contacts to
     * @param countPerAccount Number of Contacts to create per Account
     * @param doInsert Whether to insert the records immediately
     */
    public static List<Contact> createContacts(List<Account> accounts, Integer countPerAccount, Boolean doInsert) {
        List<Contact> contacts = new List<Contact>();
        for (Account acc : accounts) {
            for (Integer i = 0; i < countPerAccount; i++) {
                contacts.add(new Contact(
                    FirstName = 'Test',
                    LastName = 'Contact ' + nextContactSuffix(),
                    AccountId = acc.Id
                ));
            }
        }
        if (doInsert) {
            insert contacts;
        }
        return contacts;
    }

    /**
     * Creates a single Contact linked to the given Account (pass null to create an
     * orphan Contact with no Account, e.g. to test AccountId == null no-op behavior).
     * @param accountId Account to link the Contact to, or null
     * @param doInsert Whether to insert the record immediately
     */
    public static Contact createContact(Id accountId, Boolean doInsert) {
        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'Contact ' + nextContactSuffix(),
            AccountId = accountId
        );
        if (doInsert) {
            insert con;
        }
        return con;
    }

    /**
     * Creates a Contact with explicit field overrides (e.g. Is_Primary__c,
     * Primary_Marked_Date__c, AccountId).
     * @param fieldOverrides Map of field API name to value
     * @param doInsert Whether to insert the record immediately
     */
    public static Contact createContact(Map<String, Object> fieldOverrides, Boolean doInsert) {
        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'Contact ' + nextContactSuffix()
        );
        for (String fieldName : fieldOverrides.keySet()) {
            con.put(fieldName, fieldOverrides.get(fieldName));
        }
        if (doInsert) {
            insert con;
        }
        return con;
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    private static Integer nextContactSuffix() {
        contactCounter++;
        return contactCounter;
    }

    // ─── Custom Objects ───────────────────────────────────────────────────
    // Add methods for additional custom objects following the same pattern.
}
