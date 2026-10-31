trigger TitleReviewTrigger on Title_Review__c (before insert, before update) {
    BookClubTriggerHandler.applyReviewDefaults(Trigger.new, Trigger.oldMap);
}
