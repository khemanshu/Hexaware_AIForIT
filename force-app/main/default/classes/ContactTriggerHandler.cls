/**
 * Trigger handler for Contact. Routes each trigger context to the appropriate
 * before/after logic and guards the after-context dispatch against recursion caused
 * by ContactPrimaryContactService's own compensating DML.
 */
public with sharing class ContactTriggerHandler {

    // Recursion guard: also gates before-context field stamping so that the
    // compensating DML issued by ContactPrimaryContactService.reconcile() does not
    // re-derive Primary_Marked_Date__c on records it re-checks during fallback.
    @TestVisible
    private static Boolean isReconciling = false;

    /**
     * @param newContacts Trigger.new in a before-insert context
     */
    public void beforeInsert(List<Contact> newContacts) {
        if (isReconciling) {
            return;
        }
        ContactDomain.stampPrimaryMarkedDate(newContacts, null);
    }

    /**
     * @param newContacts Trigger.new in a before-update context
     * @param oldMap Trigger.oldMap in a before-update context
     */
    public void beforeUpdate(List<Contact> newContacts, Map<Id, Contact> oldMap) {
        if (isReconciling) {
            return;
        }
        ContactDomain.stampPrimaryMarkedDate(newContacts, oldMap);
    }

    /**
     * @param newContacts Trigger.new in an after-insert context
     */
    public void afterInsert(List<Contact> newContacts) {
        dispatchReconciliation(collectAccountIds(newContacts));
    }

    /**
     * @param newContacts Trigger.new in an after-update context
     */
    public void afterUpdate(List<Contact> newContacts) {
        dispatchReconciliation(collectAccountIds(newContacts));
    }

    /**
     * @param oldContacts Trigger.old in an after-delete context
     */
    public void afterDelete(List<Contact> oldContacts) {
        dispatchReconciliation(collectAccountIds(oldContacts), collectDeletedPrimaryContactIds(oldContacts));
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    private void dispatchReconciliation(Set<Id> affectedAccountIds) {
        dispatchReconciliation(affectedAccountIds, new Map<Id, Id>());
    }

    /**
     * @param affectedAccountIds Ids of Accounts whose Contacts changed this transaction
     * @param deletedPrimaryContactIdByAccountId AccountId -> Id of the Contact that was
     *        deleted this transaction while still Is_Primary__c = true. Needed because
     *        Account.Primary_Contact__c has deleteConstraint=SetNull: the platform clears
     *        that lookup before reconcile() ever queries it, so this is the only way
     *        reconcile() can know a delete just orphaned an Account's primary Contact.
     */
    private void dispatchReconciliation(Set<Id> affectedAccountIds, Map<Id, Id> deletedPrimaryContactIdByAccountId) {
        if (isReconciling || affectedAccountIds.isEmpty()) {
            return;
        }

        isReconciling = true;
        try {
            ContactPrimaryContactService.reconcile(affectedAccountIds, deletedPrimaryContactIdByAccountId);
        } finally {
            isReconciling = false;
        }
    }

    /**
     * Identifies, for each affected Account, the Id of a Contact that was deleted this
     * transaction while still marked Is_Primary__c = true (Trigger.old retains that value
     * even though the Contact and the Account's lookup to it are both already gone).
     */
    private Map<Id, Id> collectDeletedPrimaryContactIds(List<Contact> oldContacts) {
        Map<Id, Id> deletedPrimaryContactIdByAccountId = new Map<Id, Id>();
        if (oldContacts == null) {
            return deletedPrimaryContactIdByAccountId;
        }

        for (Contact con : oldContacts) {
            if (con.AccountId != null && con.Is_Primary__c == true) {
                deletedPrimaryContactIdByAccountId.put(con.AccountId, con.Id);
            }
        }

        return deletedPrimaryContactIdByAccountId;
    }

    private Set<Id> collectAccountIds(List<Contact> contacts) {
        Set<Id> accountIds = new Set<Id>();
        if (contacts == null) {
            return accountIds;
        }

        for (Contact con : contacts) {
            if (con.AccountId != null) {
                accountIds.add(con.AccountId);
            }
        }

        return accountIds;
    }
}
