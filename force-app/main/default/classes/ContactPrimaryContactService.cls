/**
 * Service class that reconciles Account.Primary_Contact__c against the current state of
 * its Contacts whenever Contacts are inserted, updated, or deleted. Delegates all Contact
 * queries to ContactSelector. Queries Account directly (no AccountSelector exists yet in
 * this project; this single simple lookup is in-scope for this feature only).
 */
public with sharing class ContactPrimaryContactService {

    /**
     * Reconciles Account.Primary_Contact__c for every Account in affectedAccountIds
     * against the current (post-DML) state of its Contacts. Bulkified: issues exactly one
     * Contact query, one Account query, and at most one Account DML statement and one
     * Contact DML statement for the entire set — both issued outside all loops via
     * Database.update(records, false) for partial-success tolerance.
     *
     * Promotion: if one or more Contacts on an Account currently have Is_Primary__c =
     * true, the winner is the one with the latest Primary_Marked_Date__c; every other
     * Is_Primary__c = true Contact on that Account is queued for uncheck.
     *
     * Fallback: when there is no promoted winner and the Account's current
     * Primary_Contact__c no longer has Is_Primary__c = true (unchecked) or no longer
     * exists (deleted), the most recently marked remaining Contact is promoted
     * (Is_Primary__c re-checked, but Primary_Marked_Date__c is preserved — never
     * re-stamped). If no candidate remains, Primary_Contact__c is cleared.
     *
     * Contacts with AccountId == null never appear in affectedAccountIds upstream, so
     * they are inherently a no-op here.
     *
     * @param affectedAccountIds Ids of Accounts whose Contacts changed this transaction
     */
    public static void reconcile(Set<Id> affectedAccountIds) {
        reconcile(affectedAccountIds, new Map<Id, Id>());
    }

    /**
     * @param affectedAccountIds Ids of Accounts whose Contacts changed this transaction
     * @param deletedPrimaryContactIdByAccountId AccountId -> Id of a Contact deleted this
     *        transaction while still Is_Primary__c = true. Account.Primary_Contact__c has
     *        deleteConstraint=SetNull, so the platform clears that lookup before this
     *        method's own Account query runs; this map is the only remaining signal that a
     *        delete just orphaned an Account's primary Contact, and lets fallback()
     *        proceed even though acc.Primary_Contact__c already reads null.
     */
    public static void reconcile(Set<Id> affectedAccountIds, Map<Id, Id> deletedPrimaryContactIdByAccountId) {
        if (affectedAccountIds == null || affectedAccountIds.isEmpty()) {
            return;
        }
        if (deletedPrimaryContactIdByAccountId == null) {
            deletedPrimaryContactIdByAccountId = new Map<Id, Id>();
        }

        List<Contact> contactsOnAccounts = ContactSelector.selectByAccountIdsOrderByPrimaryMarkedDateDesc(affectedAccountIds);
        Map<Id, List<Contact>> contactsByAccountId = groupContactsByAccountId(contactsOnAccounts);

        Map<Id, Account> accountsById = new Map<Id, Account>(
            [SELECT Id, Primary_Contact__c FROM Account WHERE Id IN :affectedAccountIds WITH USER_MODE]
        );

        List<Account> accountsToUpdate = new List<Account>();
        List<Contact> contactsToUpdate = new List<Contact>();

        for (Id accountId : affectedAccountIds) {
            Account acc = accountsById.get(accountId);
            if (acc == null) {
                continue;
            }

            List<Contact> contactsForAccount = contactsByAccountId.containsKey(accountId)
                ? contactsByAccountId.get(accountId)
                : new List<Contact>();

            reconcileAccount(
                acc,
                contactsForAccount,
                accountsToUpdate,
                contactsToUpdate,
                deletedPrimaryContactIdByAccountId.get(accountId)
            );
        }

        if (!accountsToUpdate.isEmpty()) {
            Database.update(accountsToUpdate, false);
        }
        if (!contactsToUpdate.isEmpty()) {
            Database.update(contactsToUpdate, false);
        }
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    private static Map<Id, List<Contact>> groupContactsByAccountId(List<Contact> contacts) {
        Map<Id, List<Contact>> contactsByAccountId = new Map<Id, List<Contact>>();

        for (Contact con : contacts) {
            if (con.AccountId == null) {
                continue;
            }
            if (!contactsByAccountId.containsKey(con.AccountId)) {
                contactsByAccountId.put(con.AccountId, new List<Contact>());
            }
            contactsByAccountId.get(con.AccountId).add(con);
        }

        return contactsByAccountId;
    }

    private static void reconcileAccount(
        Account acc,
        List<Contact> contactsForAccount,
        List<Account> accountsToUpdate,
        List<Contact> contactsToUpdate,
        Id deletedPrimaryContactId
    ) {
        List<Contact> currentPrimaryContacts = new List<Contact>();
        for (Contact con : contactsForAccount) {
            if (con.Is_Primary__c == true) {
                currentPrimaryContacts.add(con);
            }
        }

        if (!currentPrimaryContacts.isEmpty()) {
            promote(acc, currentPrimaryContacts, accountsToUpdate, contactsToUpdate);
        } else {
            fallback(acc, contactsForAccount, accountsToUpdate, contactsToUpdate, deletedPrimaryContactId);
        }
    }

    /**
     * currentPrimaryContacts preserves the Primary_Marked_Date__c DESC order from the
     * selector, so the first entry is always the deterministic winner (latest stamp —
     * the last Contact processed by ContactDomain within the triggering transaction).
     */
    private static void promote(
        Account acc,
        List<Contact> currentPrimaryContacts,
        List<Account> accountsToUpdate,
        List<Contact> contactsToUpdate
    ) {
        Contact winner = currentPrimaryContacts[0];

        if (acc.Primary_Contact__c != winner.Id) {
            acc.Primary_Contact__c = winner.Id;
            accountsToUpdate.add(acc);
        }

        for (Integer i = 1; i < currentPrimaryContacts.size(); i++) {
            Contact loser = currentPrimaryContacts[i];
            loser.Is_Primary__c = false;
            contactsToUpdate.add(loser);
        }
    }

    /**
     * @param deletedPrimaryContactId Id of a Contact deleted this transaction while still
     *        Is_Primary__c = true, if any (see reconcile()'s doc for why this is needed
     *        in addition to acc.Primary_Contact__c, which SetNull may have already cleared).
     */
    private static void fallback(
        Account acc,
        List<Contact> contactsForAccount,
        List<Account> accountsToUpdate,
        List<Contact> contactsToUpdate,
        Id deletedPrimaryContactId
    ) {
        Id previousPrimaryContactId = acc.Primary_Contact__c != null ? acc.Primary_Contact__c : deletedPrimaryContactId;

        if (previousPrimaryContactId == null) {
            return;
        }

        if (isStillValidPrimary(previousPrimaryContactId, contactsForAccount)) {
            return;
        }

        Contact candidate = findFallbackCandidate(previousPrimaryContactId, contactsForAccount);

        if (candidate == null) {
            if (acc.Primary_Contact__c != null) {
                acc.Primary_Contact__c = null;
                accountsToUpdate.add(acc);
            }
            return;
        }

        acc.Primary_Contact__c = candidate.Id;
        accountsToUpdate.add(acc);

        if (candidate.Is_Primary__c != true) {
            candidate.Is_Primary__c = true;
            contactsToUpdate.add(candidate);
        }
    }

    private static Boolean isStillValidPrimary(Id primaryContactId, List<Contact> contactsForAccount) {
        for (Contact con : contactsForAccount) {
            if (con.Id == primaryContactId && con.Is_Primary__c == true) {
                return true;
            }
        }
        return false;
    }

    private static Contact findFallbackCandidate(Id excludedContactId, List<Contact> contactsForAccount) {
        for (Contact con : contactsForAccount) {
            if (con.Id != excludedContactId) {
                return con;
            }
        }
        return null;
    }
}
