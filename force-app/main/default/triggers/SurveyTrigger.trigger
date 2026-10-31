trigger SurveyTrigger on Survey__c (before insert, before update, after update) {
    if (Trigger.isBefore) {
        BookClubTriggerHandler.applySurveyDefaults(Trigger.new, Trigger.oldMap);
    } else {
        BookClubTriggerHandler.markSelectedTitles(Trigger.new, Trigger.oldMap);
        BookClubMeetings.createForClosedSurveys(Trigger.new, Trigger.oldMap);
    }
}
