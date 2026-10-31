trigger MeetingTrigger on Book_Club_Meeting__c (before insert, before update, after update) {
    if (Trigger.isBefore) {
        BookClubMeetings.applyMeetingDefaults(Trigger.new, Trigger.oldMap);
    } else {
        BookClubMeetings.notifyScheduled(Trigger.new, Trigger.oldMap);
    }
}
