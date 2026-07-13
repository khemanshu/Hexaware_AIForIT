/**
 * Domain class for Contact. Encapsulates field-level defaults and derivations for the
 * primary-contact/account-sync feature. Operates only on in-memory SObject data — no
 * SOQL or DML.
 */
public with sharing class ContactDomain {

    /**
     * Stamps Primary_Marked_Date__c = System.now() (in-memory) on every Contact whose
     * Is_Primary__c value transitions from false/null to true during this trigger
     * invocation. Applies a strictly increasing millisecond offset per qualifying record
     * so that, when multiple Contacts on the same Account are marked primary within a
     * single transaction, the last record in the trigger collection always carries the
     * latest timestamp — this is the deterministic tie-break
     * ContactPrimaryContactService relies on to pick a single winner.
     *
     * @param newContacts Trigger.new (before insert/update context)
     * @param oldMap Trigger.oldMap; pass null for a before-insert context
     */
    public static void stampPrimaryMarkedDate(List<Contact> newContacts, Map<Id, Contact> oldMap) {
        if (newContacts == null || newContacts.isEmpty()) {
            return;
        }

        Long baseTimestampMillis = System.now().getTime();
        Integer offsetMillis = 0;

        for (Contact newContact : newContacts) {
            Boolean wasPrimary = (oldMap != null && oldMap.containsKey(newContact.Id))
                ? oldMap.get(newContact.Id).Is_Primary__c
                : false;

            if (newContact.Is_Primary__c == true && wasPrimary != true) {
                newContact.Primary_Marked_Date__c = DateTime.newInstance(baseTimestampMillis + offsetMillis);
                offsetMillis++;
            }
        }
    }
}
