// Deletes Book Club test data: surveys (with their options, responses and
// rankings), meetings (with their date options, responses and availability)
// and title reviews. Titles are kept.
//
// Run it from the project folder:
//   sf apex run --file scripts/apex/delete-test-data.apex
//
// With DRY_RUN = true it only counts what would be deleted. Set it to false to
// delete. Run it as a System Administrator: responses are private to the member
// who voted, and anonymous Apex runs with your own access.

Boolean DRY_RUN = true;

// Deleted directly, in this order: responses first, because their restrict-delete
// lookups block deleting a meeting or survey.
List<String> objectsInDeleteOrder = new List<String>{
    'Meeting_Response__c',
    'Book_Club_Meeting__c',
    'Survey_Response__c',
    'Survey__c',
    'Title_Review__c'
};

// Master-detail children, removed along with their parents above. Deleting them
// one by one would recalculate roll-ups and trip the survey's validation rules
// (a Published survey needs at least 2 options).
List<String> deletedWithParents = new List<String>{
    'Meeting_Availability__c',
    'Meeting_Date_Option__c',
    'Survey_Ranking__c',
    'Survey_Option__c'
};

for (String objectName : deletedWithParents) {
    Integer count = Database.countQuery('SELECT COUNT() FROM ' + objectName);
    System.debug(LoggingLevel.ERROR, (DRY_RUN ? 'Would delete ' : 'Deleting ') + count + ' ' + objectName + ' with their parents');
}

Savepoint savepoint = DRY_RUN ? null : Database.setSavepoint();
try {
    for (String objectName : objectsInDeleteOrder) {
        List<SObject> records = Database.query('SELECT Id FROM ' + objectName);
        if (DRY_RUN) {
            System.debug(LoggingLevel.ERROR, 'Would delete ' + records.size() + ' ' + objectName);
        } else if (!records.isEmpty()) {
            delete records;
            Database.emptyRecycleBin(records);
            System.debug(LoggingLevel.ERROR, 'Deleted ' + records.size() + ' ' + objectName);
        }
    }
    System.debug(LoggingLevel.ERROR, 'Titles kept: ' + [SELECT COUNT() FROM Title__c]);
} catch (Exception e) {
    // All or nothing: undo anything already deleted in this run.
    if (savepoint != null) {
        Database.rollback(savepoint);
    }
    System.debug(LoggingLevel.ERROR, 'Nothing was deleted: ' + e.getMessage());
    throw e;
}
