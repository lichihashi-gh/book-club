trigger TitleTrigger on Title__c (before insert, before update) {
    BookClubTriggerHandler.preventDuplicateBookshelfTitles(Trigger.new, Trigger.oldMap);
}
