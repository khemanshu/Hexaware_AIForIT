/**
 * Selector class for Contact queries related to primary-contact/account reconciliation.
 * Encapsulates all SOQL for that feature; all methods return bulkified results and
 * enforce CRUD/FLS via WITH USER_MODE.
 */
public inherited sharing class ContactSelector {

    /**
     * Selects Contacts for the given Accounts, ordered by Primary_Marked_Date__c
     * descending (most recently marked primary first; never-marked Contacts sort last).
     * Grouping the results by AccountId preserves this per-account ordering, which
     * ContactPrimaryContactService relies on for both promotion-winner selection and
     * fallback-candidate selection.
     *
     * Secondary tie-break is Id DESC, not ASC: Salesforce persists DateTime fields at
     * whole-second precision, so Contacts marked primary within the same second (e.g.
     * several Contacts on one Account marked primary in a single bulk transaction, or two
     * separate updates that land in the same clock second) can end up with an identical
     * Primary_Marked_Date__c. Since record Ids are monotonically increasing with
     * insertion/update order, Id DESC deterministically favors the most-recently-touched
     * Contact on a tie, which Id ASC would get backwards.
     *
     * @param accountIds Set of Account Ids to query Contacts for
     * @return List of Contact records ordered by Primary_Marked_Date__c DESC
     */
    public static List<Contact> selectByAccountIdsOrderByPrimaryMarkedDateDesc(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return new List<Contact>();
        }

        return [
            SELECT Id, AccountId, Is_Primary__c, Primary_Marked_Date__c
            FROM Contact
            WHERE AccountId IN :accountIds
            WITH USER_MODE
            ORDER BY Primary_Marked_Date__c DESC NULLS LAST, Id DESC
        ];
    }
}
