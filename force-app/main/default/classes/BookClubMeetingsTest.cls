@IsTest
private class BookClubMeetingsTest {
    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile minimum = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
            String suffix = UserInfo.getOrganizationId() + System.currentTimeMillis();
            List<User> users = new List<User>();
            for (String alias : new List<String>{ 'bcadmin', 'bcmem1', 'bcmem2' }) {
                users.add(new User(
                    Alias = alias,
                    FirstName = 'Reader',
                    LastName = alias,
                    Email = alias + '@example.com',
                    Username = alias + '@' + suffix + '.bookclub.test',
                    ProfileId = minimum.Id,
                    EmailEncodingKey = 'UTF-8',
                    LanguageLocaleKey = 'en_US',
                    LocaleSidKey = 'en_US',
                    TimeZoneSidKey = 'America/Los_Angeles'
                ));
            }
            insert users;

            Map<String, Id> permSets = new Map<String, Id>();
            for (PermissionSet ps : [
                SELECT Id, Name FROM PermissionSet WHERE Name IN ('Book_Club_Admin', 'Book_Club_Member')
            ]) {
                permSets.put(ps.Name, ps.Id);
            }
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = users[0].Id, PermissionSetId = permSets.get('Book_Club_Admin')),
                new PermissionSetAssignment(AssigneeId = users[1].Id, PermissionSetId = permSets.get('Book_Club_Member')),
                new PermissionSetAssignment(AssigneeId = users[2].Id, PermissionSetId = permSets.get('Book_Club_Member'))
            };
        }

        insert new List<Title__c>{
            new Title__c(Name = 'Alpha', Author__c = 'Ann Author'),
            new Title__c(Name = 'Bravo', Author__c = 'Bob Author')
        };
    }

    static User user(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND Username LIKE '%.bookclub.test'];
    }

    // A published Alpha/Bravo survey that both members voted on.
    static Survey__c votedSurvey() {
        Survey__c survey = new Survey__c(Name = 'x');
        insert survey;
        List<Survey_Option__c> options = new List<Survey_Option__c>();
        for (Title__c t : [SELECT Id FROM Title__c ORDER BY Name]) {
            options.add(new Survey_Option__c(Survey__c = survey.Id, Title__c = t.Id));
        }
        insert options;
        update new Survey__c(Id = survey.Id, Status__c = 'Published');

        List<Id> ranking = new List<Id>{ options[0].Id, options[1].Id };
        for (String alias : new List<String>{ 'bcmem1', 'bcmem2' }) {
            System.runAs(user(alias)) {
                BookClubSurveyController.submitRanking(survey.Id, ranking);
            }
        }
        return survey;
    }

    static Book_Club_Meeting__c closeAndGetMeeting(Survey__c survey) {
        update new Survey__c(Id = survey.Id, Status__c = 'Closed');
        return [
            SELECT Id, Name, Status__c, Title__r.Name, Meeting_Date__c, Scheduled_On__c, Date_Option_Count__c
            FROM Book_Club_Meeting__c
            WHERE Survey__c = :survey.Id
        ];
    }

    static List<Id> optionIds(Id meetingId) {
        return new List<Id>(new Map<Id, Meeting_Date_Option__c>([
            SELECT Id FROM Meeting_Date_Option__c WHERE Meeting__c = :meetingId ORDER BY Option_Date__c
        ]).keySet());
    }

    @IsTest
    static void meetingDatesAreTheFourSundaysAfterFourWeeksOfReading() {
        List<Date> fromFriday = new List<Date>{
            Date.newInstance(2026, 11, 29), Date.newInstance(2026, 12, 6),
            Date.newInstance(2026, 12, 13), Date.newInstance(2026, 12, 20)
        };
        Assert.areEqual(fromFriday, BookClubMeetings.suggestedDates(Date.newInstance(2026, 10, 30)), 'Friday');
        Assert.areEqual(fromFriday, BookClubMeetings.suggestedDates(Date.newInstance(2026, 11, 1)),
            'Four weeks after a Sunday is a Sunday, which counts');
        Assert.areEqual(Date.newInstance(2026, 12, 6), BookClubMeetings.suggestedDates(Date.newInstance(2026, 11, 2))[0],
            'Monday');
        Assert.areEqual('Sunday, November 29, 2026', BookClubMeetings.formatDate(fromFriday[0]));
    }

    @IsTest
    static void closingASurveyCreatesTheMeetingAndEmailsVoters() {
        Survey__c survey = votedSurvey();

        Test.startTest();
        Book_Club_Meeting__c meeting = closeAndGetMeeting(survey);
        Integer emailCalls = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual('Meeting - Alpha', meeting.Name);
        Assert.areEqual('Alpha', meeting.Title__r.Name);
        Assert.areEqual('Voting', meeting.Status__c);
        Assert.areEqual(1, emailCalls, 'Voters are emailed the dates');
        List<Date> dates = new List<Date>();
        for (Meeting_Date_Option__c option : [
            SELECT Option_Date__c FROM Meeting_Date_Option__c WHERE Meeting__c = :meeting.Id ORDER BY Option_Date__c
        ]) {
            dates.add(option.Option_Date__c);
        }
        Assert.areEqual(BookClubMeetings.suggestedDates(Date.today()), dates);

        update new Survey__c(Id = survey.Id, Status__c = 'Published');
        update new Survey__c(Id = survey.Id, Status__c = 'Closed');
        Assert.areEqual(1, [SELECT COUNT() FROM Book_Club_Meeting__c WHERE Survey__c = :survey.Id],
            'Closing again does not create a second meeting');

        String url = BookClubMeetings.meetingPageUrl();
        Assert.isTrue(url == null || url.endsWith('/' + BookClubMeetings.MEETING_PAGE), url);
    }

    @IsTest
    static void membersPickDatesAndOnlyAdminsSeeTheTally() {
        Book_Club_Meeting__c meeting = closeAndGetMeeting(votedSurvey());
        List<Id> dates = optionIds(meeting.Id);

        System.runAs(user('bcmem1')) {
            BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ dates[0], dates[1] });
            BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ dates[0] });
            BookClubMeetingController.MeetingView view = BookClubMeetingController.getMeeting(meeting.Id);
            Assert.isTrue(view.hasResponded);
            Assert.isTrue(view.options[0].available);
            Assert.isFalse(view.options[1].available, 'Responding again replaces the earlier answer');
            Assert.isFalse(view.showTally, 'Members don\'t see the tally');
            Assert.isNull(view.options[0].availableCount);
            Assert.isNull(view.responseCount);

            try {
                BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ meeting.Id });
                Assert.fail('Only the meeting\'s dates can be picked');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('this meeting'), e.getMessage());
            }
        }
        System.runAs(user('bcmem2')) {
            BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ dates[1], dates[2] });
            Assert.areEqual(1, [SELECT COUNT() FROM Meeting_Response__c], 'Members see only their own response');
            BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>());
            Assert.isTrue(BookClubMeetingController.getMeeting(meeting.Id).hasResponded,
                'Saying no date works still counts as a response');
            BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ dates[1] });
        }

        System.runAs(user('bcadmin')) {
            BookClubMeetingController.MeetingView view = BookClubMeetingController.getMeeting(meeting.Id);
            Assert.isTrue(view.showTally);
            Assert.areEqual(2, view.responseCount);
            Assert.areEqual(1, view.options[0].availableCount);
            Assert.areEqual(1, view.options[1].availableCount);
            Assert.areEqual(0, view.options[2].availableCount);
            Assert.areEqual(view.options[0].optionDate, view.suggestedDate, 'Ties go to the earliest date');
            Assert.isTrue(view.options[0].isLeader);
            Assert.isFalse(view.options[1].isLeader);

            BookClubMeetingController.MeetingList meetings = BookClubMeetingController.getMeetings();
            Assert.isTrue(meetings.isAdmin);
            Assert.isFalse(meetings.isSite);
            Assert.areEqual(meeting.Id, meetings.meetings[0].id);
        }
    }

    @IsTest
    static void adminSchedulesTheMeetingAndMembersAreEmailed() {
        Book_Club_Meeting__c meeting = closeAndGetMeeting(votedSurvey());
        List<Id> dates = optionIds(meeting.Id);
        Date chosen = [SELECT Option_Date__c FROM Meeting_Date_Option__c WHERE Id = :dates[1]].Option_Date__c;

        System.runAs(user('bcmem1')) {
            try {
                BookClubMeetingController.scheduleMeeting(meeting.Id, chosen);
                Assert.fail('Members can\'t schedule');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('admin'), e.getMessage());
            }
        }

        Integer emailCalls;
        System.runAs(user('bcadmin')) {
            Test.startTest();
            BookClubMeetingController.scheduleMeeting(meeting.Id, chosen);
            emailCalls = Limits.getEmailInvocations();
            Test.stopTest();
        }
        Book_Club_Meeting__c saved = [
            SELECT Status__c, Meeting_Date__c, Scheduled_On__c FROM Book_Club_Meeting__c WHERE Id = :meeting.Id
        ];
        Assert.areEqual('Scheduled', saved.Status__c);
        Assert.areEqual(chosen, saved.Meeting_Date__c);
        Assert.areEqual(Date.today(), saved.Scheduled_On__c);
        Assert.areEqual(1, emailCalls, 'Members are emailed the date');

        System.runAs(user('bcmem1')) {
            try {
                BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ dates[0] });
                Assert.fail('No more answers once scheduled');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('already been scheduled'), e.getMessage());
            }
            BookClubMeetingController.MeetingView view = BookClubMeetingController.getMeeting(meeting.Id);
            Assert.areEqual('Scheduled', view.status);
            Assert.areEqual(chosen, view.meetingDate);
            Assert.isFalse(BookClubMeetingController.getMeetings().isAdmin);
        }
    }

    @IsTest
    static void schedulingInTheStandardUiPicksTheMostPopularDate() {
        Book_Club_Meeting__c meeting = closeAndGetMeeting(votedSurvey());
        List<Id> dates = optionIds(meeting.Id);

        try {
            update new Book_Club_Meeting__c(Id = meeting.Id, Status__c = 'Scheduled');
            Assert.fail('Nothing to pick from without responses');
        } catch (DmlException e) {
            Assert.areEqual(BookClubMeetings.NO_RESPONSES, e.getDmlMessage(0));
        }

        System.runAs(user('bcmem1')) {
            BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ dates[2], dates[3] });
        }
        System.runAs(user('bcmem2')) {
            BookClubMeetingController.submitAvailability(meeting.Id, new List<Id>{ dates[3] });
        }
        update new Book_Club_Meeting__c(Id = meeting.Id, Status__c = 'Scheduled');
        Date fourth = [SELECT Option_Date__c FROM Meeting_Date_Option__c WHERE Id = :dates[3]].Option_Date__c;
        Assert.areEqual(fourth, [SELECT Meeting_Date__c FROM Book_Club_Meeting__c WHERE Id = :meeting.Id].Meeting_Date__c);

        Test.startTest();
        update new Book_Club_Meeting__c(Id = meeting.Id, Meeting_Date__c = fourth.addDays(7), Scheduled_On__c = fourth);
        Integer emailCalls = Limits.getEmailInvocations();
        Test.stopTest();
        Assert.areEqual(1, emailCalls, 'Members hear about a new date');
        Assert.areEqual(Date.today(), [SELECT Scheduled_On__c FROM Book_Club_Meeting__c WHERE Id = :meeting.Id].Scheduled_On__c,
            'Scheduled On is kept as it was');
    }
}
