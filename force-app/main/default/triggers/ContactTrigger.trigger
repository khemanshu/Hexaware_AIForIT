/**
 * Contact Trigger
 * Routes all events to ContactTriggerHandler. Contains no business logic.
 */
trigger ContactTrigger on Contact (
    before insert,
    before update,
    after insert,
    after update,
    after delete
) {
    ContactTriggerHandler handler = new ContactTriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            handler.beforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.beforeUpdate(Trigger.new, Trigger.oldMap);
        }
    } else if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            handler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.afterUpdate(Trigger.new);
        } else if (Trigger.isDelete) {
            handler.afterDelete(Trigger.old);
        }
        // Note: Account.Primary_Contact__c has deleteConstraint=SetNull, so by the time
        // afterDelete's reconcile() query runs, the platform has already cleared the
        // lookup on any Account whose primary Contact was just deleted. afterDelete
        // passes Trigger.old (which still has Is_Primary__c) so the handler can detect
        // that case independently of the (already-cleared) Account field.
    }
}
