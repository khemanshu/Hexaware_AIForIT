/**
 * Test class for ContactPrimaryContactService (exercised end-to-end through
 * ContactTrigger/ContactTriggerHandler/ContactDomain, plus direct reconcile() calls
 * where noted). Covers promotion, fallback, bulk, recursion-guard, and partial-DML
 * tolerance scenarios from the KAN-24 TDD.
 */
@isTest
private class ContactPrimaryContactServiceTest {

    private static final String TEST_USER_LAST_NAME = 'KAN24PrimaryContactTestUser';

    /**
     * ContactSelector and ContactPrimaryContactService enforce FLS via WITH USER_MODE, so
     * every test runs as a dedicated user with the Primary_Contact_Management permission
     * set assigned. Assigning the permission set to the currently-running (deploying) user
     * within the same transaction does not reliably refresh that user's cached FLS state,
     * so System.runAs against a fresh user is required to exercise the trigger path.
     */
    @testSetup
    static void setup() {
        Profile stdUserProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User testUser = new User(
            Alias = 'kan24tu',
            Email = 'kan24.primarycontact.testuser@example.com.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = TEST_USER_LAST_NAME,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = stdUserProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'kan24.primarycontact.testuser' + Crypto.getRandomInteger() + '@example.com.invalid'
        );
        insert testUser;

        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Primary_Contact_Management' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = testUser.Id, PermissionSetId = ps.Id);
    }

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE LastName = :TEST_USER_LAST_NAME LIMIT 1];
    }

    @isTest
    static void shouldSetPrimaryContactAndStampDate_WhenContactMarkedPrimary() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact con = TestDataFactory.createContact(acc.Id, true);

            // When
            Test.startTest();
            con.Is_Primary__c = true;
            update con;
            Test.stopTest();

            // Then
            Account updatedAcc = [SELECT Primary_Contact__c FROM Account WHERE Id = :acc.Id];
            Contact updatedCon = [SELECT Primary_Marked_Date__c FROM Contact WHERE Id = :con.Id];

            Assert.areEqual(con.Id, updatedAcc.Primary_Contact__c, 'Account should point to the newly marked primary Contact');
            Assert.isNotNull(updatedCon.Primary_Marked_Date__c, 'Primary_Marked_Date__c should be stamped when a Contact is marked primary');
        }
    }

    @isTest
    static void shouldUncheckPreviousPrimary_WhenSecondContactMarkedPrimary() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact first = TestDataFactory.createContact(acc.Id, true);
            first.Is_Primary__c = true;
            update first;

            Contact second = TestDataFactory.createContact(acc.Id, true);

            // When
            Test.startTest();
            second.Is_Primary__c = true;
            update second;
            Test.stopTest();

            // Then
            Map<Id, Contact> contactsById = new Map<Id, Contact>(
                [SELECT Is_Primary__c FROM Contact WHERE Id IN (:first.Id, :second.Id)]
            );
            Account updatedAcc = [SELECT Primary_Contact__c FROM Account WHERE Id = :acc.Id];

            Assert.isFalse(contactsById.get(first.Id).Is_Primary__c, 'First Contact should be auto-unchecked once a second Contact is marked primary');
            Assert.isTrue(contactsById.get(second.Id).Is_Primary__c, 'Second Contact should remain marked primary');
            Assert.areEqual(second.Id, updatedAcc.Primary_Contact__c, 'Account should point to the second, newly-marked Contact');
        }
    }

    @isTest
    static void shouldRefreshTimestamp_WhenContactReMarkedPrimary() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact con = TestDataFactory.createContact(acc.Id, true);
            con.Is_Primary__c = true;
            update con;
            Contact firstMark = [SELECT Primary_Marked_Date__c FROM Contact WHERE Id = :con.Id];

            con.Is_Primary__c = false;
            update con;

            // When
            Test.startTest();
            con.Is_Primary__c = true;
            update con;
            Test.stopTest();

            // Then
            Contact secondMark = [SELECT Primary_Marked_Date__c FROM Contact WHERE Id = :con.Id];

            Assert.isTrue(
                secondMark.Primary_Marked_Date__c >= firstMark.Primary_Marked_Date__c,
                'Re-marking primary should refresh (never move backward) the stamped timestamp'
            );
        }
    }

    @isTest
    static void shouldFallBackToNextMostRecent_WhenCurrentPrimaryUnchecked() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact older = TestDataFactory.createContact(acc.Id, true);
            older.Is_Primary__c = true;
            update older;
            Contact olderAfterFirstMark = [SELECT Primary_Marked_Date__c FROM Contact WHERE Id = :older.Id];

            Contact newer = TestDataFactory.createContact(acc.Id, true);
            newer.Is_Primary__c = true;
            update newer;

            // When
            Test.startTest();
            newer.Is_Primary__c = false;
            update newer;
            Test.stopTest();

            // Then
            Account updatedAcc = [SELECT Primary_Contact__c FROM Account WHERE Id = :acc.Id];
            Contact olderAfterFallback = [SELECT Is_Primary__c, Primary_Marked_Date__c FROM Contact WHERE Id = :older.Id];

            Assert.areEqual(older.Id, updatedAcc.Primary_Contact__c, 'Account should fall back to the next most recently marked Contact');
            Assert.isTrue(olderAfterFallback.Is_Primary__c, 'Fallback Contact should be re-checked as primary');
            Assert.areEqual(
                olderAfterFirstMark.Primary_Marked_Date__c,
                olderAfterFallback.Primary_Marked_Date__c,
                'Fallback promotion must preserve the original Primary_Marked_Date__c, not re-stamp it'
            );
        }
    }

    @isTest
    static void shouldClearAccountPrimaryContact_WhenLastPrimaryUncheckedWithNoOtherCandidate() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact con = TestDataFactory.createContact(acc.Id, true);
            con.Is_Primary__c = true;
            update con;

            // When
            Test.startTest();
            con.Is_Primary__c = false;
            update con;
            Test.stopTest();

            // Then
            Account updatedAcc = [SELECT Primary_Contact__c FROM Account WHERE Id = :acc.Id];
            Assert.isNull(updatedAcc.Primary_Contact__c, 'Account Primary_Contact__c should be cleared when the only primary Contact is unchecked');
        }
    }

    @isTest
    static void shouldFallBackToNextMostRecent_WhenCurrentPrimaryDeleted() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact older = TestDataFactory.createContact(acc.Id, true);
            older.Is_Primary__c = true;
            update older;

            Contact newer = TestDataFactory.createContact(acc.Id, true);
            newer.Is_Primary__c = true;
            update newer;

            // When
            Test.startTest();
            delete newer;
            Test.stopTest();

            // Then
            Account updatedAcc = [SELECT Primary_Contact__c FROM Account WHERE Id = :acc.Id];
            Contact updatedOlder = [SELECT Is_Primary__c FROM Contact WHERE Id = :older.Id];

            Assert.areEqual(older.Id, updatedAcc.Primary_Contact__c, 'Account should fall back to the remaining Contact after the primary Contact is deleted');
            Assert.isTrue(updatedOlder.Is_Primary__c, 'Remaining Contact should be re-checked as primary after fallback');
        }
    }

    @isTest
    static void shouldClearAccountPrimaryContact_WhenOnlyPrimaryContactDeleted() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact con = TestDataFactory.createContact(acc.Id, true);
            con.Is_Primary__c = true;
            update con;

            // When
            Test.startTest();
            delete con;
            Test.stopTest();

            // Then
            Account updatedAcc = [SELECT Primary_Contact__c FROM Account WHERE Id = :acc.Id];
            Assert.isNull(updatedAcc.Primary_Contact__c, 'Account Primary_Contact__c should be cleared when the only primary Contact is deleted with no fallback candidate');
        }
    }

    @isTest
    static void shouldSetCorrectPrimaryPerAccount_WhenBulkMarkingAcrossManyAccounts() {
        System.runAs(getTestUser()) {
            // Given
            List<Account> accounts = TestDataFactory.createAccounts(50, true);
            List<Contact> contacts = TestDataFactory.createContacts(accounts, 1, true);

            for (Contact con : contacts) {
                con.Is_Primary__c = true;
            }

            // When
            Test.startTest();
            update contacts;
            Test.stopTest();

            // Then
            Map<Id, Id> expectedContactIdByAccountId = new Map<Id, Id>();
            for (Contact con : contacts) {
                expectedContactIdByAccountId.put(con.AccountId, con.Id);
            }

            List<Account> updatedAccounts = [SELECT Id, Primary_Contact__c FROM Account WHERE Id IN :accounts];
            Assert.areEqual(50, updatedAccounts.size(), 'All 50 Accounts should be queried back');

            for (Account acc : updatedAccounts) {
                Assert.areEqual(
                    expectedContactIdByAccountId.get(acc.Id),
                    acc.Primary_Contact__c,
                    'Each Account should point only to its own Contact — no cross-account leakage'
                );
            }
        }
    }

    @isTest
    static void shouldReconcileEachAccountIndependently_WhenBulkMixOfUnchecksAndDeletes() {
        System.runAs(getTestUser()) {
            // Given: 4 Accounts, each with an older (first-marked) and a newer (currently
            // primary) Contact, except Accounts 2 and 3 which have only a single Contact.
            List<Account> accounts = TestDataFactory.createAccounts(4, true);

            Contact acc0Older = TestDataFactory.createContact(accounts[0].Id, true);
            acc0Older.Is_Primary__c = true;
            update acc0Older;
            Contact acc0Newer = TestDataFactory.createContact(accounts[0].Id, true);
            acc0Newer.Is_Primary__c = true;
            update acc0Newer;

            Contact acc1Older = TestDataFactory.createContact(accounts[1].Id, true);
            acc1Older.Is_Primary__c = true;
            update acc1Older;
            Contact acc1Newer = TestDataFactory.createContact(accounts[1].Id, true);
            acc1Newer.Is_Primary__c = true;
            update acc1Newer;

            Contact acc2Only = TestDataFactory.createContact(accounts[2].Id, true);
            acc2Only.Is_Primary__c = true;
            update acc2Only;

            Contact acc3Only = TestDataFactory.createContact(accounts[3].Id, true);
            acc3Only.Is_Primary__c = true;
            update acc3Only;

            // When: Account 0 unchecks its primary, Account 1 deletes its primary, Account 2
            // unchecks its only Contact, Account 3 deletes its only Contact.
            Test.startTest();
            acc0Newer.Is_Primary__c = false;
            update acc0Newer;
            delete acc1Newer;
            acc2Only.Is_Primary__c = false;
            update acc2Only;
            delete acc3Only;
            Test.stopTest();

            // Then
            Map<Id, Account> updatedAccounts = new Map<Id, Account>(
                [SELECT Primary_Contact__c FROM Account WHERE Id IN :accounts]
            );

            Assert.areEqual(acc0Older.Id, updatedAccounts.get(accounts[0].Id).Primary_Contact__c, 'Account 0 should fall back to its older Contact after uncheck');
            Assert.areEqual(acc1Older.Id, updatedAccounts.get(accounts[1].Id).Primary_Contact__c, 'Account 1 should fall back to its older Contact after delete');
            Assert.isNull(updatedAccounts.get(accounts[2].Id).Primary_Contact__c, 'Account 2 should be cleared — no fallback candidate after uncheck');
            Assert.isNull(updatedAccounts.get(accounts[3].Id).Primary_Contact__c, 'Account 3 should be cleared — no fallback candidate after delete');
        }
    }

    @isTest
    static void shouldPickLastContactAsWinner_WhenMultipleContactsMarkedPrimaryInSameTransaction() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            List<Contact> contacts = TestDataFactory.createContacts(new List<Account>{ acc }, 3, true);

            for (Contact con : contacts) {
                con.Is_Primary__c = true;
            }

            // When
            Test.startTest();
            update contacts;
            Test.stopTest();

            // Then
            Contact expectedWinner = contacts[contacts.size() - 1];
            Account updatedAcc = [SELECT Primary_Contact__c FROM Account WHERE Id = :acc.Id];
            Assert.areEqual(
                expectedWinner.Id,
                updatedAcc.Primary_Contact__c,
                'The last Contact in the trigger collection should deterministically win when multiple are marked primary in one transaction'
            );

            List<Contact> updatedContacts = [SELECT Is_Primary__c FROM Contact WHERE Id IN :contacts];
            Integer primaryCount = 0;
            for (Contact con : updatedContacts) {
                if (con.Is_Primary__c) {
                    primaryCount++;
                }
            }
            Assert.areEqual(1, primaryCount, 'Only one Contact should remain marked primary after reconciliation');
        }
    }

    @isTest
    static void shouldNoOp_WhenContactHasNullAccountId() {
        System.runAs(getTestUser()) {
            // Given
            Contact orphan = TestDataFactory.createContact((Id) null, true);

            // When
            Test.startTest();
            orphan.Is_Primary__c = true;
            update orphan;
            Test.stopTest();

            // Then
            Contact updatedOrphan = [SELECT Is_Primary__c, AccountId FROM Contact WHERE Id = :orphan.Id];
            Assert.isTrue(updatedOrphan.Is_Primary__c, 'Is_Primary__c should still be settable directly on an orphan Contact');
            Assert.isNull(updatedOrphan.AccountId, 'Orphan Contact should remain without an Account — no reconciliation attempted, no error');
        }
    }

    @isTest
    static void shouldBoundDmlStatementCount_WhenReconciliationTriggersRecursively() {
        System.runAs(getTestUser()) {
            // Given
            Account acc = TestDataFactory.createAccount(true);
            Contact older = TestDataFactory.createContact(acc.Id, true);
            older.Is_Primary__c = true;
            update older;

            Contact newer = TestDataFactory.createContact(acc.Id, true);

            // When: marking newer primary causes reconcile() to update the Account and
            // uncheck older via Database.update — that Contact DML re-fires ContactTrigger,
            // which must be short-circuited by the recursion guard rather than reconciling again.
            Test.startTest();
            Integer dmlBefore = Limits.getDmlStatements();
            newer.Is_Primary__c = true;
            update newer;
            Integer dmlAfter = Limits.getDmlStatements();
            Test.stopTest();

            // Then: 1 for `update newer` itself, plus at most 1 Account update and 1 Contact
            // update from reconcile(). Without the guard, the recursive Contact update would
            // trigger further reconcile passes and grow this count unboundedly.
            Assert.isTrue(
                (dmlAfter - dmlBefore) <= 3,
                'DML statement count should stay bounded by the recursion guard: expected <= 3, got ' + (dmlAfter - dmlBefore)
            );
            Assert.isFalse(ContactTriggerHandler.isReconciling, 'Recursion guard flag should be reset to false once reconciliation completes');
        }
    }

    @isTest
    static void shouldReconcileValidAccount_WhenBatchAlsoContainsNonExistentAccountId() {
        System.runAs(getTestUser()) {
            // This schema has no validation rules to force a genuine Database.SaveResult
            // failure deterministically across orgs, so this test exercises the same
            // tolerance guarantee behind Database.update(records, false) — issued outside all
            // loops — by proving that one missing/invalid Account Id in the batch does not
            // block reconciliation of the other, valid Account.
            Account validAccount = TestDataFactory.createAccount(true);
            Contact con = TestDataFactory.createContact(validAccount.Id, true);
            con.Is_Primary__c = true;
            update con;

            Account deletedAccount = TestDataFactory.createAccount(true);
            Id nonExistentAccountId = deletedAccount.Id;
            delete deletedAccount;

            // When
            Test.startTest();
            ContactPrimaryContactService.reconcile(new Set<Id>{ validAccount.Id, nonExistentAccountId });
            Test.stopTest();

            // Then
            Account updatedAccount = [SELECT Primary_Contact__c FROM Account WHERE Id = :validAccount.Id];
            Assert.areEqual(
                con.Id,
                updatedAccount.Primary_Contact__c,
                'Valid Account should still be correctly reconciled despite a non-existent Account Id in the same batch'
            );
        }
    }
}
