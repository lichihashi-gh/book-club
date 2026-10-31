// Backs meetingPoll: members tick the suggested Sundays they can make, and the
// admin schedules the meeting (BookClubMeetings emails the date).
public with sharing class BookClubMeetingController {
    @TestVisible
    static final String STATUS_VOTING = 'Voting';
    @TestVisible
    static final String STATUS_SCHEDULED = 'Scheduled';

    @AuraEnabled
    public static MeetingList getMeetings() {
        MeetingList result = new MeetingList();
        result.isAdmin = BookClubSurveyController.isAdmin();
        result.isSite = Network.getNetworkId() != null;
        List<MeetingSummary> scheduled = new List<MeetingSummary>();
        for (Book_Club_Meeting__c meeting : [
            SELECT Id, Name, Status__c, Meeting_Date__c
            FROM Book_Club_Meeting__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ]) {
            MeetingSummary summary = new MeetingSummary(meeting);
            if (meeting.Status__c == STATUS_VOTING) {
                result.meetings.add(summary);
            } else {
                scheduled.add(summary);
            }
        }
        result.meetings.addAll(scheduled);
        return result;
    }

    @AuraEnabled
    public static MeetingView getMeeting(Id meetingId) {
        Book_Club_Meeting__c meeting = loadMeeting(meetingId);
        MeetingView view = new MeetingView(meeting);

        List<Meeting_Response__c> mine = [
            SELECT Submitted_On__c FROM Meeting_Response__c WHERE Unique_Key__c = :responseKey(meetingId) WITH USER_MODE
        ];
        view.hasResponded = !mine.isEmpty();
        view.submittedOn = view.hasResponded ? mine[0].Submitted_On__c : null;
        Set<Id> myDates = new Set<Id>();
        for (Meeting_Availability__c availability : [
            SELECT Meeting_Date_Option__c
            FROM Meeting_Availability__c
            WHERE Meeting_Response__r.Unique_Key__c = :responseKey(meetingId)
            WITH USER_MODE
        ]) {
            myDates.add(availability.Meeting_Date_Option__c);
        }

        // Like survey results, the tally is for admins only while voting is open.
        view.showTally = BookClubSurveyController.isAdmin();
        List<Meeting_Date_Option__c> options = loadOptions(meetingId);
        Date leader = BookClubMeetings.leadingDate(options);
        for (Meeting_Date_Option__c option : options) {
            DateOptionView optionView = new DateOptionView(option, myDates.contains(option.Id));
            if (view.showTally) {
                optionView.availableCount = (option.Available_Count__c ?? 0).intValue();
                optionView.isLeader = option.Option_Date__c == leader;
            }
            view.options.add(optionView);
        }
        if (view.showTally) {
            view.responseCount = new ResponseCounter().countFor(meetingId);
            view.suggestedDate = leader;
        }
        return view;
    }

    // An empty list is a valid answer: none of the dates work.
    @AuraEnabled
    public static void submitAvailability(Id meetingId, List<Id> optionIds) {
        Book_Club_Meeting__c meeting = loadMeeting(meetingId);
        if (meeting.Status__c != STATUS_VOTING) {
            throw error('This meeting has already been scheduled.');
        }
        Set<Id> picked = new Set<Id>(optionIds ?? new List<Id>());
        if (!new Map<Id, Meeting_Date_Option__c>(loadOptions(meetingId)).keySet().containsAll(picked)) {
            throw error('Pick from this meeting\'s dates.');
        }

        // Members only have read access to responses, so, as with survey
        // responses, they're written in system mode, scoped to the user's own key.
        String key = responseKey(meetingId);
        List<Meeting_Response__c> existing = [
            SELECT Id FROM Meeting_Response__c WHERE Unique_Key__c = :key WITH SYSTEM_MODE
        ];
        Meeting_Response__c response;
        if (existing.isEmpty()) {
            response = new Meeting_Response__c(
                Meeting__c = meetingId,
                Respondent__c = UserInfo.getUserId(),
                Unique_Key__c = key,
                Submitted_On__c = Datetime.now()
            );
            insert as system response;
        } else {
            response = new Meeting_Response__c(Id = existing[0].Id, Submitted_On__c = Datetime.now());
            update as system response;
            delete as system [
                SELECT Id FROM Meeting_Availability__c WHERE Meeting_Response__c = :response.Id WITH SYSTEM_MODE
            ];
        }

        List<Meeting_Availability__c> availabilities = new List<Meeting_Availability__c>();
        for (Id optionId : picked) {
            availabilities.add(new Meeting_Availability__c(Meeting_Response__c = response.Id, Meeting_Date_Option__c = optionId));
        }
        insert as system availabilities;
    }

    @AuraEnabled
    public static void scheduleMeeting(Id meetingId, Date meetingDate) {
        if (!BookClubSurveyController.isAdmin()) {
            throw error('Only a book club admin can schedule a meeting.');
        }
        if (meetingDate == null) {
            throw error('Pick the meeting date.');
        }
        if (loadMeeting(meetingId).Status__c != STATUS_VOTING) {
            throw error('This meeting has already been scheduled.');
        }
        // The trigger stamps Scheduled On and emails the members.
        try {
            update as user new Book_Club_Meeting__c(Id = meetingId, Status__c = STATUS_SCHEDULED, Meeting_Date__c = meetingDate);
        } catch (DmlException e) {
            throw error(e.getDmlMessage(0));
        }
    }

    private static Book_Club_Meeting__c loadMeeting(Id meetingId) {
        List<Book_Club_Meeting__c> meetings = [
            SELECT Id, Name, Status__c, Meeting_Date__c, Title__r.Name, Title__r.Author__c
            FROM Book_Club_Meeting__c
            WHERE Id = :meetingId
            WITH USER_MODE
        ];
        if (meetings.isEmpty()) {
            throw error('Meeting not found.');
        }
        return meetings[0];
    }

    private static List<Meeting_Date_Option__c> loadOptions(Id meetingId) {
        return [
            SELECT Id, Option_Date__c, Available_Count__c
            FROM Meeting_Date_Option__c
            WHERE Meeting__c = :meetingId
            WITH USER_MODE
            ORDER BY Option_Date__c
        ];
    }

    private static String responseKey(Id meetingId) {
        return meetingId + ':' + UserInfo.getUserId();
    }

    private static AuraHandledException error(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    // Responses are Private; admins see only how many there are.
    private without sharing class ResponseCounter {
        Integer countFor(Id meetingId) {
            return [SELECT COUNT() FROM Meeting_Response__c WHERE Meeting__c = :meetingId WITH SYSTEM_MODE];
        }
    }

    public class MeetingList {
        @AuraEnabled public Boolean isAdmin;
        @AuraEnabled public Boolean isSite;
        @AuraEnabled public List<MeetingSummary> meetings = new List<MeetingSummary>();
    }

    public class MeetingSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Date meetingDate;

        public MeetingSummary(Book_Club_Meeting__c meeting) {
            id = meeting.Id;
            name = meeting.Name;
            status = meeting.Status__c;
            meetingDate = meeting.Meeting_Date__c;
        }
    }

    public class MeetingView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String titleName;
        @AuraEnabled public String author;
        @AuraEnabled public Date meetingDate;
        @AuraEnabled public Boolean hasResponded = false;
        @AuraEnabled public Datetime submittedOn;
        @AuraEnabled public Boolean showTally = false;
        @AuraEnabled public Integer responseCount;
        @AuraEnabled public Date suggestedDate;
        @AuraEnabled public List<DateOptionView> options = new List<DateOptionView>();

        public MeetingView(Book_Club_Meeting__c meeting) {
            id = meeting.Id;
            name = meeting.Name;
            status = meeting.Status__c;
            titleName = meeting.Title__r?.Name;
            author = meeting.Title__r?.Author__c;
            meetingDate = meeting.Meeting_Date__c;
        }
    }

    public class DateOptionView {
        @AuraEnabled public Id id;
        @AuraEnabled public Date optionDate;
        @AuraEnabled public Boolean available;
        @AuraEnabled public Integer availableCount;
        @AuraEnabled public Boolean isLeader = false;

        public DateOptionView(Meeting_Date_Option__c option, Boolean available) {
            id = option.Id;
            optionDate = option.Option_Date__c;
            this.available = available;
        }
    }
}
