// Runs from triggers, so it must see every survey option to catch duplicates.
public without sharing class BookClubTriggerHandler {
    @TestVisible
    static final String DUPLICATE_TITLE = 'That title is already on this survey.';
    @TestVisible
    static final String NAME_PREFIX = 'Next Read - ';
    @TestVisible
    static final String NO_RESPONSES = 'No one has responded yet. Pick the Selected Title to close this survey.';
    @TestVisible
    static final String TIED = 'The vote is tied. Pick the Selected Title to close this survey.';
    @TestVisible
    static final String NOT_AN_OPTION = 'The Selected Title must be one of the survey\'s titles.';
    @TestVisible
    static final String ALREADY_REVIEWED = 'You\'ve already reviewed this title. Edit your review instead.';
    static final String STATUS_PUBLISHED = 'Published';
    static final String STATUS_CLOSED = 'Closed';
    static final String TITLE_SELECTED = 'Selected';

    // New surveys are named after the day they're created, e.g. "Next Read - 01/01/2026"
    // (admins can rename later). Published On and Closed On are stamped whenever
    // the status changes to Published or Closed, and are otherwise kept as they
    // were: System Administrators bypass read-only field access, so the trigger
    // is what keeps these dates read-only.
    public static void applySurveyDefaults(List<Survey__c> surveys, Map<Id, Survey__c> oldById) {
        List<Survey__c> closing = new List<Survey__c>();
        for (Survey__c survey : surveys) {
            Survey__c old = oldById == null ? null : oldById.get(survey.Id);
            if (old == null) {
                survey.Name = defaultName(Date.today());
            }
            survey.Published_On__c = statusChangedTo(survey, old, STATUS_PUBLISHED)
                ? Date.today()
                : old?.Published_On__c;
            survey.Closed_On__c = statusChangedTo(survey, old, STATUS_CLOSED)
                ? Date.today()
                : old?.Closed_On__c;
            if (old != null && statusChangedTo(survey, old, STATUS_CLOSED)) {
                closing.add(survey);
            }
        }
        if (!closing.isEmpty()) {
            selectWinners(closing);
        }
    }

    // After a survey closes, its Selected Title is marked Selected and decided today.
    public static void markSelectedTitles(List<Survey__c> surveys, Map<Id, Survey__c> oldById) {
        Map<Id, Title__c> winners = new Map<Id, Title__c>();
        for (Survey__c survey : surveys) {
            if (statusChangedTo(survey, oldById.get(survey.Id), STATUS_CLOSED) && survey.Selected_Title__c != null) {
                winners.put(survey.Selected_Title__c, new Title__c(
                    Id = survey.Selected_Title__c,
                    Status__c = TITLE_SELECTED,
                    Decided_On__c = Date.today()
                ));
            }
        }
        update winners.values();
    }

    // A survey closed without a Selected Title gets the leader: most points, ties
    // broken by first-choice votes. With no responses or a true tie, the admin
    // has to pick the Selected Title.
    private static void selectWinners(List<Survey__c> closing) {
        Map<Id, List<BookClubSurveyController.OptionResult>> resultsBySurvey =
            new Map<Id, List<BookClubSurveyController.OptionResult>>();
        for (Survey__c survey : closing) {
            resultsBySurvey.put(survey.Id, new List<BookClubSurveyController.OptionResult>());
        }
        for (Survey_Option__c option : [
            SELECT Survey__c, Title__c, Title__r.Name, Total_Points__c, First_Choice_Votes__c
            FROM Survey_Option__c
            WHERE Survey__c IN :resultsBySurvey.keySet()
            WITH SYSTEM_MODE
        ]) {
            resultsBySurvey.get(option.Survey__c).add(new BookClubSurveyController.OptionResult(
                option.Title__c, option.Title__r.Name, option.Total_Points__c, option.First_Choice_Votes__c
            ));
        }

        for (Survey__c survey : closing) {
            List<BookClubSurveyController.OptionResult> results = resultsBySurvey.get(survey.Id);
            if (survey.Selected_Title__c != null) {
                if (!isOption(results, survey.Selected_Title__c)) {
                    survey.Selected_Title__c.addError(NOT_AN_OPTION);
                }
                continue;
            }
            results.sort();
            // Every ranking earns at least 1 point, so a leader with 0 means no responses.
            if (results.isEmpty() || results[0].totalPoints == 0) {
                survey.addError(NO_RESPONSES);
            } else if (results.size() > 1 && results[0].compareTo(results[1]) == 0) {
                survey.addError(TIED);
            } else {
                survey.Selected_Title__c = results[0].titleId;
            }
        }
    }

    private static Boolean isOption(List<BookClubSurveyController.OptionResult> results, Id titleId) {
        for (BookClubSurveyController.OptionResult result : results) {
            if (result.titleId == titleId) {
                return true;
            }
        }
        return false;
    }

    // Stamps Unique_Key__c and reports a readable error when a title is
    // already on the survey (the unique field is the backstop).
    public static void preventDuplicateTitles(List<Survey_Option__c> options) {
        Map<String, Survey_Option__c> byKey = new Map<String, Survey_Option__c>();
        Set<Id> selfIds = new Set<Id>();

        for (Survey_Option__c option : options) {
            if (option.Survey__c == null || option.Title__c == null) {
                continue;
            }
            String key = optionKey(option.Survey__c, option.Title__c);
            option.Unique_Key__c = key;
            if (byKey.containsKey(key)) {
                option.Title__c.addError(DUPLICATE_TITLE);
            } else {
                byKey.put(key, option);
            }
            if (option.Id != null) {
                selfIds.add(option.Id);
            }
        }
        if (byKey.isEmpty()) {
            return;
        }

        for (Survey_Option__c existing : [
            SELECT Unique_Key__c FROM Survey_Option__c
            WHERE Unique_Key__c IN :byKey.keySet() AND Id NOT IN :selfIds WITH SYSTEM_MODE
        ]) {
            byKey.get(existing.Unique_Key__c).Title__c.addError(DUPLICATE_TITLE);
        }
    }

    // The reviewer is whoever creates the review and can't be changed later, so
    // each member has at most one review per title (Unique_Key__c is the backstop).
    public static void applyReviewDefaults(List<Title_Review__c> reviews, Map<Id, Title_Review__c> oldById) {
        Map<String, Title_Review__c> byKey = new Map<String, Title_Review__c>();
        Set<Id> selfIds = new Set<Id>();

        for (Title_Review__c review : reviews) {
            Title_Review__c old = oldById?.get(review.Id);
            if (old == null) {
                review.Reviewer__c = UserInfo.getUserId();
                review.Reviewer_Name__c = UserInfo.getName();
            } else {
                review.Reviewer__c = old.Reviewer__c;
                review.Reviewer_Name__c = old.Reviewer_Name__c;
                selfIds.add(review.Id);
            }
            if (review.Title__c == null || review.Reviewer__c == null) {
                continue;
            }
            String key = reviewKey(review.Title__c, review.Reviewer__c);
            review.Unique_Key__c = key;
            if (byKey.containsKey(key)) {
                review.addError(ALREADY_REVIEWED);
            } else {
                byKey.put(key, review);
            }
        }
        if (byKey.isEmpty()) {
            return;
        }

        for (Title_Review__c existing : [
            SELECT Unique_Key__c FROM Title_Review__c
            WHERE Unique_Key__c IN :byKey.keySet() AND Id NOT IN :selfIds
            WITH SYSTEM_MODE
        ]) {
            byKey.get(existing.Unique_Key__c).addError(ALREADY_REVIEWED);
        }
    }

    public static String reviewKey(Id titleId, Id userId) {
        return titleId + ':' + userId;
    }

    public static String optionKey(Id surveyId, Id titleId) {
        return surveyId + ':' + titleId;
    }

    @TestVisible
    static String defaultName(Date createdOn) {
        return NAME_PREFIX
            + Datetime.newInstance(createdOn.year(), createdOn.month(), createdOn.day()).format('MM/dd/yyyy');
    }

    private static Boolean statusChangedTo(Survey__c survey, Survey__c old, String status) {
        return survey.Status__c == status && (old == null || old.Status__c != status);
    }
}
