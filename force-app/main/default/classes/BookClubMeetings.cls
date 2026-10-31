// Runs from triggers: when a survey closes it creates the meeting and emails
// everyone who voted; when the meeting is scheduled it emails them the date.
// Without sharing because responses are Private and the invite list is
// everyone who responded.
public without sharing class BookClubMeetings {
    @TestVisible
    static final Integer READING_DAYS = 28;
    @TestVisible
    static final Integer DATE_OPTIONS = 4;
    @TestVisible
    static final String NO_RESPONSES = 'No one has picked a date yet. Choose the Meeting Date to schedule this meeting.';
    @TestVisible
    static final String SITE_NAME = 'Book Club';
    @TestVisible
    static final String MEETING_PAGE = 'meeting';
    static final String NAME_PREFIX = 'Meeting - ';
    static final String STATUS_CLOSED = 'Closed';
    static final String STATUS_SCHEDULED = 'Scheduled';
    // Any known Sunday, to work out the weekday without depending on the user's locale.
    static final Date A_SUNDAY = Date.newInstance(1900, 1, 7);

    // Four weeks to read, then the next four Sundays from that day on
    // (a Sunday is itself included).
    public static List<Date> suggestedDates(Date decidedOn) {
        Date readBy = decidedOn.addDays(READING_DAYS);
        Integer daysPastSunday = Math.mod(A_SUNDAY.daysBetween(readBy), 7);
        Date firstSunday = daysPastSunday == 0 ? readBy : readBy.addDays(7 - daysPastSunday);
        List<Date> dates = new List<Date>();
        for (Integer i = 0; i < DATE_OPTIONS; i++) {
            dates.add(firstSunday.addDays(7 * i));
        }
        return dates;
    }

    // After update on Survey__c. One meeting per survey, even if it is reopened and closed again.
    public static void createForClosedSurveys(List<Survey__c> surveys, Map<Id, Survey__c> oldById) {
        Map<Id, Survey__c> closed = new Map<Id, Survey__c>();
        for (Survey__c survey : surveys) {
            Survey__c old = oldById.get(survey.Id);
            if (survey.Status__c == STATUS_CLOSED && old.Status__c != STATUS_CLOSED && survey.Selected_Title__c != null) {
                closed.put(survey.Id, survey);
            }
        }
        for (Book_Club_Meeting__c existing : [
            SELECT Survey__c FROM Book_Club_Meeting__c WHERE Survey__c IN :closed.keySet() WITH SYSTEM_MODE
        ]) {
            closed.remove(existing.Survey__c);
        }
        if (closed.isEmpty()) {
            return;
        }

        Set<Id> titleIds = new Set<Id>();
        for (Survey__c survey : closed.values()) {
            titleIds.add(survey.Selected_Title__c);
        }
        Map<Id, Title__c> titles = new Map<Id, Title__c>([
            SELECT Id, Name, Author__c FROM Title__c WHERE Id IN :titleIds WITH SYSTEM_MODE
        ]);

        List<Book_Club_Meeting__c> meetings = new List<Book_Club_Meeting__c>();
        for (Survey__c survey : closed.values()) {
            meetings.add(new Book_Club_Meeting__c(
                Name = (NAME_PREFIX + titles.get(survey.Selected_Title__c).Name).abbreviate(80),
                Survey__c = survey.Id,
                Title__c = survey.Selected_Title__c
            ));
        }
        insert as system meetings;

        List<Meeting_Date_Option__c> options = new List<Meeting_Date_Option__c>();
        Map<Id, List<Date>> datesByMeeting = new Map<Id, List<Date>>();
        for (Book_Club_Meeting__c meeting : meetings) {
            Survey__c survey = closed.get(meeting.Survey__c);
            List<Date> dates = suggestedDates(survey.Closed_On__c ?? Date.today());
            datesByMeeting.put(meeting.Id, dates);
            for (Date optionDate : dates) {
                options.add(new Meeting_Date_Option__c(Meeting__c = meeting.Id, Option_Date__c = optionDate));
            }
        }
        insert as system options;

        Map<Id, Set<Id>> invitees = inviteesBySurvey(closed.keySet());
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        for (Book_Club_Meeting__c meeting : meetings) {
            Title__c title = titles.get(meeting.Title__c);
            for (User member : activeUsers(invitees.get(meeting.Survey__c))) {
                emails.add(invitation(member, title, datesByMeeting.get(meeting.Id)));
            }
        }
        send(emails);
    }

    // Before update on Book_Club_Meeting__c. Scheduling without a Meeting Date
    // picks the date most members can make (ties go to the earliest).
    public static void applyMeetingDefaults(List<Book_Club_Meeting__c> meetings, Map<Id, Book_Club_Meeting__c> oldById) {
        Map<Id, Book_Club_Meeting__c> needDate = new Map<Id, Book_Club_Meeting__c>();
        for (Book_Club_Meeting__c meeting : meetings) {
            Book_Club_Meeting__c old = oldById?.get(meeting.Id);
            Boolean scheduling = meeting.Status__c == STATUS_SCHEDULED && (old == null || old.Status__c != STATUS_SCHEDULED);
            meeting.Scheduled_On__c = scheduling ? Date.today() : old?.Scheduled_On__c;
            if (scheduling && meeting.Meeting_Date__c == null) {
                needDate.put(meeting.Id, meeting);
            }
        }
        if (needDate.isEmpty()) {
            return;
        }

        Map<Id, List<Meeting_Date_Option__c>> optionsByMeeting = new Map<Id, List<Meeting_Date_Option__c>>();
        for (Meeting_Date_Option__c option : [
            SELECT Meeting__c, Option_Date__c, Available_Count__c
            FROM Meeting_Date_Option__c
            WHERE Meeting__c IN :needDate.keySet()
            WITH SYSTEM_MODE
            ORDER BY Option_Date__c
        ]) {
            if (!optionsByMeeting.containsKey(option.Meeting__c)) {
                optionsByMeeting.put(option.Meeting__c, new List<Meeting_Date_Option__c>());
            }
            optionsByMeeting.get(option.Meeting__c).add(option);
        }
        for (Book_Club_Meeting__c meeting : needDate.values()) {
            Date leader = leadingDate(optionsByMeeting.get(meeting.Id));
            if (leader == null) {
                meeting.addError(NO_RESPONSES);
            } else {
                meeting.Meeting_Date__c = leader;
            }
        }
    }

    // After update on Book_Club_Meeting__c: email the date when the meeting is
    // scheduled, and again if the date changes afterwards.
    public static void notifyScheduled(List<Book_Club_Meeting__c> meetings, Map<Id, Book_Club_Meeting__c> oldById) {
        List<Book_Club_Meeting__c> changed = new List<Book_Club_Meeting__c>();
        for (Book_Club_Meeting__c meeting : meetings) {
            Book_Club_Meeting__c old = oldById.get(meeting.Id);
            if (meeting.Status__c == STATUS_SCHEDULED && meeting.Meeting_Date__c != null
                && (old.Status__c != STATUS_SCHEDULED || old.Meeting_Date__c != meeting.Meeting_Date__c)) {
                changed.add(meeting);
            }
        }
        if (changed.isEmpty()) {
            return;
        }

        Map<Id, Book_Club_Meeting__c> withTitles = new Map<Id, Book_Club_Meeting__c>([
            SELECT Id, Survey__c, Title__r.Name, Title__r.Author__c
            FROM Book_Club_Meeting__c
            WHERE Id IN :changed
            WITH SYSTEM_MODE
        ]);
        Set<Id> surveyIds = new Set<Id>();
        for (Book_Club_Meeting__c meeting : withTitles.values()) {
            surveyIds.add(meeting.Survey__c);
        }
        Map<Id, Set<Id>> invitees = inviteesBySurvey(surveyIds);
        // Members who answered the date poll but didn't vote on the survey hear too.
        for (Meeting_Response__c response : [
            SELECT Meeting__r.Survey__c, OwnerId FROM Meeting_Response__c WHERE Meeting__c IN :changed WITH SYSTEM_MODE
        ]) {
            invitees.get(response.Meeting__r.Survey__c).add(response.OwnerId);
        }

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        for (Book_Club_Meeting__c meeting : changed) {
            Book_Club_Meeting__c full = withTitles.get(meeting.Id);
            Boolean rescheduled = oldById.get(meeting.Id).Status__c == STATUS_SCHEDULED;
            for (User member : activeUsers(invitees.get(full.Survey__c))) {
                emails.add(confirmation(member, full.Title__r, meeting.Meeting_Date__c, rescheduled));
            }
        }
        send(emails);
    }

    // Most members available wins; ties go to the earliest date. Null when no one is available.
    public static Date leadingDate(List<Meeting_Date_Option__c> options) {
        Meeting_Date_Option__c leader;
        for (Meeting_Date_Option__c option : options ?? new List<Meeting_Date_Option__c>()) {
            Decimal count = option.Available_Count__c ?? 0;
            if (count > 0 && (leader == null || count > leader.Available_Count__c
                || (count == leader.Available_Count__c && option.Option_Date__c < leader.Option_Date__c))) {
                leader = option;
            }
        }
        return leader?.Option_Date__c;
    }

    // e.g. "Sunday, November 29, 2026"
    public static String formatDate(Date value) {
        return Datetime.newInstanceGmt(value, Time.newInstance(12, 0, 0, 0)).formatGmt('EEEE, MMMM d, yyyy');
    }

    // The member site's meeting page, e.g. https://…/bookclub/s/meeting. Null if the site is missing.
    @TestVisible
    static String meetingPageUrl() {
        List<Network> sites = [SELECT Id FROM Network WHERE Name = :SITE_NAME WITH SYSTEM_MODE LIMIT 1];
        if (sites.isEmpty()) {
            return null;
        }
        String loginUrl = Network.getLoginUrl(sites[0].Id);
        if (String.isBlank(loginUrl) || !loginUrl.contains('/login')) {
            return null;
        }
        return loginUrl.substringBefore('/login') + '/' + MEETING_PAGE;
    }

    private static Map<Id, Set<Id>> inviteesBySurvey(Set<Id> surveyIds) {
        Map<Id, Set<Id>> invitees = new Map<Id, Set<Id>>();
        for (Id surveyId : surveyIds) {
            invitees.put(surveyId, new Set<Id>());
        }
        for (Survey_Response__c response : [
            SELECT Survey__c, OwnerId FROM Survey_Response__c WHERE Survey__c IN :surveyIds WITH SYSTEM_MODE
        ]) {
            invitees.get(response.Survey__c).add(response.OwnerId);
        }
        return invitees;
    }

    private static List<User> activeUsers(Set<Id> userIds) {
        return [SELECT Id, FirstName FROM User WHERE Id IN :userIds AND IsActive = TRUE WITH SYSTEM_MODE];
    }

    private static Messaging.SingleEmailMessage invitation(User member, Title__c title, List<Date> dates) {
        String url = meetingPageUrl();
        String reading = describe(title);
        List<String> dateLines = new List<String>();
        List<String> dateItems = new List<String>();
        for (Date optionDate : dates) {
            dateLines.add('  • ' + formatDate(optionDate));
            dateItems.add('<li>' + formatDate(optionDate) + '</li>');
        }

        String text = greeting(member) + '\n\n'
            + 'The votes are in: we\'re reading ' + reading + '. That gives us about a month to read it, '
            + 'so here are four Sundays we could meet:\n\n'
            + String.join(dateLines, '\n') + '\n\n'
            + 'Let us know which ones work for you'
            + (url == null ? ' on the Book Club site.' : ':\n' + url) + '\n\nHappy reading!';
        String html = '<p>' + greeting(member).escapeHtml4() + '</p>'
            + '<p>The votes are in: we\'re reading <strong>' + reading.escapeHtml4() + '</strong>. '
            + 'That gives us about a month to read it, so here are four Sundays we could meet:</p>'
            + '<ul>' + String.join(dateItems, '') + '</ul>'
            + (url == null
                ? '<p>Let us know which ones work for you on the Book Club site.</p>'
                : '<p><a href="' + url + '">Pick the dates you can make</a></p>')
            + '<p>Happy reading!</p>';
        return email(member, 'We\'re reading ' + title.Name + '. When can you meet?', text, html);
    }

    private static Messaging.SingleEmailMessage confirmation(User member, Title__c title, Date meetingDate, Boolean rescheduled) {
        String url = meetingPageUrl();
        String meetsOn = formatDate(meetingDate);
        String lead = rescheduled ? 'Our meeting has moved. ' : 'It\'s settled! ';
        String text = greeting(member) + '\n\n'
            + lead + 'We\'ll meet on ' + meetsOn + ' to talk about ' + describe(title) + '.'
            + (url == null ? '' : '\n\n' + url) + '\n\nSee you there!';
        String html = '<p>' + greeting(member).escapeHtml4() + '</p>'
            + '<p>' + lead.escapeHtml4() + 'We\'ll meet on <strong>' + meetsOn + '</strong> to talk about <strong>'
            + describe(title).escapeHtml4() + '</strong>.</p>'
            + (url == null ? '' : '<p><a href="' + url + '">See the meeting on the Book Club site</a></p>')
            + '<p>See you there!</p>';
        String subject = (rescheduled ? 'New date: book club meets ' : 'Book club meets ') + meetsOn;
        return email(member, subject, text, html);
    }

    private static String describe(Title__c title) {
        return title == null ? 'our next pick'
            : title.Name + (String.isBlank(title.Author__c) ? '' : ' by ' + title.Author__c);
    }

    private static String greeting(User member) {
        return String.isBlank(member.FirstName) ? 'Hello,' : 'Hi ' + member.FirstName + ',';
    }

    private static Messaging.SingleEmailMessage email(User member, String subject, String text, String html) {
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setTargetObjectId(member.Id);
        message.setSaveAsActivity(false);
        message.setSenderDisplayName('The Book Club');
        message.setSubject(subject);
        message.setPlainTextBody(text);
        message.setHtmlBody(html);
        return message;
    }

    // Email trouble (e.g. deliverability turned off) mustn't stop a survey
    // closing or a meeting being scheduled.
    private static void send(List<Messaging.SingleEmailMessage> emails) {
        if (emails.isEmpty()) {
            return;
        }
        try {
            for (Messaging.SendEmailResult result : Messaging.sendEmail(emails, false)) {
                if (!result.isSuccess()) {
                    System.debug(LoggingLevel.WARN, 'Book club email failed: ' + result.getErrors()[0].getMessage());
                }
            }
        } catch (EmailException e) {
            System.debug(LoggingLevel.WARN, 'Book club email failed: ' + e.getMessage());
        }
    }
}
