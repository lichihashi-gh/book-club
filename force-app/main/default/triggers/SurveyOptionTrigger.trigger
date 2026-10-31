trigger SurveyOptionTrigger on Survey_Option__c (before insert, before update) {
    BookClubTriggerHandler.preventDuplicateTitles(Trigger.new);
}
