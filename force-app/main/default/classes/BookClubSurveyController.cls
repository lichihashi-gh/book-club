// Backs the Book Club LWCs: the admin builds a survey in surveyBuilder, members
// rank every title on a Published survey, and the admin confirms the winner.
public with sharing class BookClubSurveyController {
    @TestVisible
    static final String ADMIN_PERMISSION = 'Book_Club_Admin';
    @TestVisible
    static final Integer MAX_OPTIONS = 5;
    @TestVisible
    static final String RESULTS_HIDDEN = 'Results are hidden until the survey closes.';
    static final String STATUS_DRAFT = 'Draft';
    static final String STATUS_PUBLISHED = 'Published';
    static final String STATUS_CLOSED = 'Closed';
    static final String TITLE_SUGGESTED = 'Suggested';

    // Not cacheable: the builder should always show titles added moments ago.
    @AuraEnabled
    public static List<CandidateTitle> getSuggestedTitles() {
        List<CandidateTitle> titles = new List<CandidateTitle>();
        for (Title__c title : [
            SELECT Id, Name, Author__c, Title_Type__c, Suggested_By__r.Name, Suggested_On__c
            FROM Title__c
            WHERE Status__c = :TITLE_SUGGESTED
            WITH USER_MODE
            ORDER BY Name
        ]) {
            titles.add(new CandidateTitle(title));
        }
        return titles;
    }

    // Creates a survey with its options in one go. SurveyTrigger names it, and
    // publishing stamps Published On.
    @AuraEnabled
    public static Id createSurvey(List<Id> titleIds, Boolean publish) {
        if (!isAdmin()) {
            throw error('Only a book club admin can create a survey.');
        }
        List<Id> picked = titleIds == null ? new List<Id>() : titleIds;
        if (picked.size() < 2 || picked.size() > MAX_OPTIONS || new Set<Id>(picked).size() != picked.size()) {
            throw error('Pick 2 to ' + MAX_OPTIONS + ' different titles.');
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            Survey__c survey = new Survey__c();
            insert as user survey;
            List<Survey_Option__c> options = new List<Survey_Option__c>();
            for (Integer i = 0; i < picked.size(); i++) {
                options.add(new Survey_Option__c(Survey__c = survey.Id, Title__c = picked[i], Display_Order__c = i + 1));
            }
            insert as user options;
            if (publish == true) {
                survey.Status__c = STATUS_PUBLISHED;
                update as user survey;
            }
            return survey.Id;
        } catch (DmlException e) {
            Database.rollback(savepoint);
            throw error(e.getDmlMessage(0));
        }
    }

    @AuraEnabled(cacheable=true)
    public static SurveyList getSurveys() {
        SurveyList result = new SurveyList();
        result.isAdmin = isAdmin();
        result.isSite = Network.getNetworkId() != null;
        List<SurveySummary> closed = new List<SurveySummary>();
        for (Survey__c survey : [
            SELECT Id, Name, Status__c, Published_On__c, Selected_Title__r.Name
            FROM Survey__c
            WHERE Status__c != :STATUS_DRAFT
            WITH USER_MODE
            ORDER BY Published_On__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 50
        ]) {
            SurveySummary summary = new SurveySummary(survey);
            if (survey.Status__c == STATUS_PUBLISHED) {
                result.surveys.add(summary);
            } else {
                closed.add(summary);
            }
        }
        result.surveys.addAll(closed);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static SurveyView getSurvey(Id surveyId) {
        Survey__c survey = loadSurvey(surveyId);
        SurveyView view = new SurveyView(survey);

        Map<Id, Integer> rankByOption = new Map<Id, Integer>();
        for (Survey_Ranking__c ranking : [
            SELECT Survey_Option__c, Rank__c, Survey_Response__r.Submitted_On__c
            FROM Survey_Ranking__c
            WHERE Survey_Response__r.Unique_Key__c = :responseKey(surveyId)
            WITH USER_MODE
        ]) {
            rankByOption.put(ranking.Survey_Option__c, ranking.Rank__c.intValue());
            view.submittedOn = ranking.Survey_Response__r.Submitted_On__c;
        }
        view.hasVoted = !rankByOption.isEmpty();

        for (Survey_Option__c option : loadOptions(surveyId)) {
            view.options.add(new SurveyOptionView(option, rankByOption.get(option.Id)));
        }
        if (view.hasVoted) {
            view.options.sort();
        }
        return view;
    }

    @AuraEnabled
    public static void submitRanking(Id surveyId, List<Id> optionIdsInRankOrder) {
        Survey__c survey = loadSurvey(surveyId);
        if (survey.Status__c != STATUS_PUBLISHED) {
            throw error('Voting is not open for this survey.');
        }

        Set<Id> optionIds = new Map<Id, Survey_Option__c>(loadOptions(surveyId)).keySet();
        List<Id> ranked = optionIdsInRankOrder == null ? new List<Id>() : optionIdsInRankOrder;
        if (ranked.size() != optionIds.size() || !new Set<Id>(ranked).equals(optionIds)) {
            throw error('Rank every title on the survey exactly once.');
        }

        // Members only have read access to responses, so responses are written in
        // system mode, scoped to the running user's own response.
        String key = responseKey(surveyId);
        List<Survey_Response__c> existing = [
            SELECT Id FROM Survey_Response__c WHERE Unique_Key__c = :key WITH SYSTEM_MODE
        ];
        Survey_Response__c response;
        if (existing.isEmpty()) {
            response = new Survey_Response__c(
                Survey__c = surveyId,
                Respondent__c = UserInfo.getUserId(),
                Unique_Key__c = key,
                Submitted_On__c = Datetime.now()
            );
            insert as system response;
        } else {
            response = new Survey_Response__c(Id = existing[0].Id, Submitted_On__c = Datetime.now());
            update as system response;
            delete as system [
                SELECT Id FROM Survey_Ranking__c WHERE Survey_Response__c = :response.Id WITH SYSTEM_MODE
            ];
        }

        List<Survey_Ranking__c> rankings = new List<Survey_Ranking__c>();
        for (Integer i = 0; i < ranked.size(); i++) {
            rankings.add(new Survey_Ranking__c(
                Survey_Response__c = response.Id,
                Survey_Option__c = ranked[i],
                Rank__c = i + 1,
                Points__c = ranked.size() - i
            ));
        }
        insert as system rankings;
    }

    @AuraEnabled(cacheable=true)
    public static SurveyResults getResults(Id surveyId) {
        Survey__c survey = loadSurvey(surveyId);
        // Members shouldn't be swayed by other votes, so only admins see results while voting is open.
        if (survey.Status__c == STATUS_PUBLISHED && !isAdmin()) {
            throw error(RESULTS_HIDDEN);
        }
        SurveyResults results = new SurveyResults(survey);
        results.responseCount = new ResponseCounter().countFor(surveyId);
        for (Survey_Option__c option : loadOptions(surveyId)) {
            results.options.add(new OptionResult(option));
        }
        rankResults(results);
        return results;
    }

    @AuraEnabled
    public static void closeSurvey(Id surveyId, Id winningTitleId) {
        if (!isAdmin()) {
            throw error('Only a book club admin can close a survey.');
        }
        Survey__c survey = loadSurvey(surveyId);
        if (survey.Status__c != STATUS_PUBLISHED) {
            throw error('Only a published survey can be closed.');
        }
        Boolean onSurvey = false;
        for (Survey_Option__c option : loadOptions(surveyId)) {
            onSurvey |= option.Title__c == winningTitleId;
        }
        if (!onSurvey) {
            throw error('The winning title must be one of the survey\'s titles.');
        }

        // SurveyTrigger marks the winning title Selected.
        try {
            update as user new Survey__c(
                Id = surveyId,
                Status__c = STATUS_CLOSED,
                Selected_Title__c = winningTitleId
            );
        } catch (DmlException e) {
            throw error(e.getDmlMessage(0));
        }
    }

    // Most points wins; ties go to the most first-choice votes. Still tied → isTie.
    @TestVisible
    static void rankResults(SurveyResults results) {
        results.options.sort();
        if (results.options.isEmpty() || results.responseCount == 0) {
            return;
        }
        OptionResult leader = results.options[0];
        leader.isLeader = true;
        results.suggestedWinnerTitleId = leader.titleId;
        for (Integer i = 1; i < results.options.size(); i++) {
            if (results.options[i].compareTo(leader) == 0) {
                results.options[i].isLeader = true;
                results.isTie = true;
            }
        }
    }

    private static Survey__c loadSurvey(Id surveyId) {
        List<Survey__c> surveys = [
            SELECT Id, Name, Status__c, Published_On__c, Selected_Title__c, Selected_Title__r.Name
            FROM Survey__c
            WHERE Id = :surveyId
            WITH USER_MODE
        ];
        if (surveys.isEmpty()) {
            throw error('Survey not found.');
        }
        return surveys[0];
    }

    private static List<Survey_Option__c> loadOptions(Id surveyId) {
        return [
            SELECT Id, Title__c, Title__r.Name, Title__r.Author__c, Title__r.Title_Type__c, Title__r.Notes__c,
                Total_Points__c, First_Choice_Votes__c
            FROM Survey_Option__c
            WHERE Survey__c = :surveyId
            WITH USER_MODE
            ORDER BY Display_Order__c NULLS LAST, Name
        ];
    }

    private static String responseKey(Id surveyId) {
        return surveyId + ':' + UserInfo.getUserId();
    }

    // Admin tools (building and closing surveys) are internal only: on the
    // member site everyone, including the admin, gets the member view.
    public static Boolean isAdmin() {
        return FeatureManagement.checkPermission(ADMIN_PERMISSION) && Network.getNetworkId() == null;
    }

    private static AuraHandledException error(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    // Responses are Private, so members only see their own. The count of
    // responses (never their contents) is shown in results once the survey closes.
    private without sharing class ResponseCounter {
        Integer countFor(Id surveyId) {
            return [SELECT COUNT() FROM Survey_Response__c WHERE Survey__c = :surveyId WITH SYSTEM_MODE];
        }
    }

    public class CandidateTitle {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String author;
        @AuraEnabled public String titleType;
        @AuraEnabled public String suggestedBy;
        @AuraEnabled public Date suggestedOn;

        public CandidateTitle(Title__c title) {
            id = title.Id;
            name = title.Name;
            author = title.Author__c;
            titleType = title.Title_Type__c;
            suggestedBy = title.Suggested_By__r?.Name;
            suggestedOn = title.Suggested_On__c;
        }
    }

    public class SurveyList {
        @AuraEnabled public Boolean isAdmin;
        // True on the member site, where members vote.
        @AuraEnabled public Boolean isSite;
        @AuraEnabled public List<SurveySummary> surveys = new List<SurveySummary>();
    }

    public class SurveySummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String selectedTitleName;

        public SurveySummary(Survey__c survey) {
            id = survey.Id;
            name = survey.Name;
            status = survey.Status__c;
            selectedTitleName = survey.Selected_Title__r?.Name;
        }
    }

    public class SurveyView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String selectedTitleName;
        @AuraEnabled public Boolean hasVoted = false;
        @AuraEnabled public Datetime submittedOn;
        @AuraEnabled public List<SurveyOptionView> options = new List<SurveyOptionView>();

        public SurveyView(Survey__c survey) {
            id = survey.Id;
            name = survey.Name;
            status = survey.Status__c;
            selectedTitleName = survey.Selected_Title__r?.Name;
        }
    }

    public class SurveyOptionView implements Comparable {
        @AuraEnabled public Id id;
        @AuraEnabled public Id titleId;
        @AuraEnabled public String titleName;
        @AuraEnabled public String author;
        @AuraEnabled public String titleType;
        // The suggester's "why should we read it?" note.
        @AuraEnabled public String notes;
        @AuraEnabled public Integer rank;

        public SurveyOptionView(Survey_Option__c option, Integer rank) {
            id = option.Id;
            titleId = option.Title__c;
            titleName = option.Title__r.Name;
            author = option.Title__r.Author__c;
            titleType = option.Title__r.Title_Type__c;
            notes = option.Title__r.Notes__c;
            this.rank = rank;
        }

        public Integer compareTo(Object other) {
            Integer otherRank = ((SurveyOptionView) other).rank;
            return (rank == null ? 99 : rank) - (otherRank == null ? 99 : otherRank);
        }
    }

    public class SurveyResults {
        @AuraEnabled public Id surveyId;
        @AuraEnabled public String status;
        @AuraEnabled public Integer responseCount = 0;
        @AuraEnabled public Id selectedTitleId;
        @AuraEnabled public Id suggestedWinnerTitleId;
        @AuraEnabled public Boolean isTie = false;
        @AuraEnabled public List<OptionResult> options = new List<OptionResult>();

        public SurveyResults(Survey__c survey) {
            surveyId = survey.Id;
            status = survey.Status__c;
            selectedTitleId = survey.Selected_Title__c;
        }
    }

    public class OptionResult implements Comparable {
        @AuraEnabled public Id titleId;
        @AuraEnabled public String titleName;
        @AuraEnabled public String author;
        @AuraEnabled public Integer totalPoints;
        @AuraEnabled public Integer firstChoiceVotes;
        @AuraEnabled public Boolean isLeader = false;

        public OptionResult(Survey_Option__c option) {
            this(option.Title__c, option.Title__r.Name, option.Total_Points__c, option.First_Choice_Votes__c);
            author = option.Title__r.Author__c;
        }

        public OptionResult(Id titleId, String titleName, Decimal totalPoints, Decimal firstChoiceVotes) {
            this.titleId = titleId;
            this.titleName = titleName;
            this.totalPoints = totalPoints == null ? 0 : totalPoints.intValue();
            this.firstChoiceVotes = firstChoiceVotes == null ? 0 : firstChoiceVotes.intValue();
        }

        // Sorts best first; 0 means a true tie on points and first-choice votes.
        public Integer compareTo(Object other) {
            OptionResult that = (OptionResult) other;
            if (totalPoints != that.totalPoints) {
                return that.totalPoints - totalPoints;
            }
            return that.firstChoiceVotes - firstChoiceVotes;
        }
    }
}
