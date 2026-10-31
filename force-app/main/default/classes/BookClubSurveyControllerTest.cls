@IsTest
private class BookClubSurveyControllerTest {
    static final Date REVIEWED_ON = Date.newInstance(2026, 1, 15);

    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile minimum = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
            String suffix = UserInfo.getOrganizationId() + System.currentTimeMillis();
            List<User> users = new List<User>();
            for (String alias : new List<String>{ 'bcadmin', 'bcmem1', 'bcmem2' }) {
                users.add(new User(
                    Alias = alias,
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

        List<Title__c> titles = new List<Title__c>();
        for (String name : new List<String>{ 'Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo', 'Foxtrot' }) {
            titles.add(new Title__c(Name = name, Author__c = name + ' Author'));
        }
        titles.add(new Title__c(
            Name = 'Already Reviewed', Status__c = 'Reviewed', Reviewed_On__c = REVIEWED_ON, Overall_Score__c = 4.5
        ));
        insert titles;
    }

    static User user(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND Username LIKE '%.bookclub.test'];
    }

    static Title__c title(String name) {
        return [SELECT Id, Name, Status__c, Decided_On__c FROM Title__c WHERE Name = :name];
    }

    // Builds a survey the way the admin does in the UI: Draft, add titles, then Published.
    static Survey__c publishSurvey(List<String> titleNames) {
        Survey__c survey = new Survey__c(Name = 'typed by admin');
        insert survey;
        List<Survey_Option__c> options = new List<Survey_Option__c>();
        for (Title__c t : [SELECT Id FROM Title__c WHERE Name IN :titleNames]) {
            options.add(new Survey_Option__c(Survey__c = survey.Id, Title__c = t.Id));
        }
        insert options;
        survey.Status__c = 'Published';
        update survey;
        return survey;
    }

    static List<Id> optionIds(Id surveyId, List<String> titleNamesInRankOrder) {
        Map<String, Id> byTitle = new Map<String, Id>();
        for (Survey_Option__c o : [SELECT Id, Title__r.Name FROM Survey_Option__c WHERE Survey__c = :surveyId]) {
            byTitle.put(o.Title__r.Name, o.Id);
        }
        List<Id> ids = new List<Id>();
        for (String name : titleNamesInRankOrder) {
            ids.add(byTitle.get(name));
        }
        return ids;
    }

    static String dmlError(SObject record, Boolean isInsert) {
        try {
            if (isInsert) {
                insert record;
            } else {
                update record;
            }
        } catch (DmlException e) {
            return e.getDmlMessage(0);
        }
        return null;
    }

    @IsTest
    static void surveyNameAndDatesAreSetAutomatically() {
        Survey__c survey = new Survey__c(Name = 'typed by admin');
        insert survey;
        Survey__c saved = [SELECT Name, Published_On__c, Closed_On__c FROM Survey__c WHERE Id = :survey.Id];
        Assert.areEqual(BookClubTriggerHandler.defaultName(Date.today()), saved.Name);
        Assert.isTrue(saved.Name.startsWith('Next Read - '), saved.Name);
        Assert.isNull(saved.Published_On__c, 'Drafts are not published yet');

        update new Survey__c(Id = survey.Id, Name = 'Spring pick');
        Assert.areEqual('Spring pick', [SELECT Name FROM Survey__c WHERE Id = :survey.Id].Name,
            'Admins can rename after creation');

        insert new List<Survey_Option__c>{
            new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Alpha').Id),
            new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Bravo').Id)
        };
        update new Survey__c(Id = survey.Id, Status__c = 'Published');
        saved = [SELECT Published_On__c, Closed_On__c FROM Survey__c WHERE Id = :survey.Id];
        Assert.areEqual(Date.today(), saved.Published_On__c);
        Assert.isNull(saved.Closed_On__c);

        update new Survey__c(Id = survey.Id, Status__c = 'Closed', Selected_Title__c = title('Alpha').Id);
        Assert.areEqual(Date.today(), [SELECT Closed_On__c FROM Survey__c WHERE Id = :survey.Id].Closed_On__c);

        update new Survey__c(Id = survey.Id, Published_On__c = REVIEWED_ON, Closed_On__c = REVIEWED_ON);
        saved = [SELECT Published_On__c, Closed_On__c FROM Survey__c WHERE Id = :survey.Id];
        Assert.areEqual(Date.today(), saved.Published_On__c, 'Manual edits to Published On are ignored');
        Assert.areEqual(Date.today(), saved.Closed_On__c, 'Manual edits to Closed On are ignored');
        Survey__c backdated = new Survey__c(Name = 'x', Published_On__c = REVIEWED_ON);
        insert backdated;
        Assert.isNull([SELECT Published_On__c FROM Survey__c WHERE Id = :backdated.Id].Published_On__c);
        Assert.areEqual('Next Read - 01/15/2026', BookClubTriggerHandler.defaultName(REVIEWED_ON));
    }

    @IsTest
    static void surveyOptionRulesAreEnforced() {
        Survey__c survey = new Survey__c(Name = 'x');
        insert survey;
        Survey_Option__c first = new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Alpha').Id);
        insert first;

        String publishing = dmlError(new Survey__c(Id = survey.Id, Status__c = 'Published'), false);
        Assert.isTrue(publishing.contains('at least 2'), publishing);

        String duplicate = dmlError(new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Alpha').Id), true);
        Assert.areEqual(BookClubTriggerHandler.DUPLICATE_TITLE, duplicate);

        String alreadyReviewed = dmlError(new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Already Reviewed').Id), true);
        Assert.isTrue(alreadyReviewed.contains('already reviewed'), alreadyReviewed);

        insert new List<Survey_Option__c>{
            new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Bravo').Id),
            new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Charlie').Id),
            new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Delta').Id),
            new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Echo').Id)
        };
        String sixth = dmlError(new Survey_Option__c(Survey__c = survey.Id, Title__c = title('Foxtrot').Id), true);
        Assert.isTrue(sixth.contains('at most 5'), sixth);

        update new Survey__c(Id = survey.Id, Status__c = 'Published');
        String afterPublish = dmlError(new Survey_Option__c(Id = first.Id, Title__c = title('Foxtrot').Id), false);
        Assert.isTrue(afterPublish.contains('Draft'), afterPublish);
    }

    @IsTest
    static void reviewedTitlesNeedAReviewDate() {
        Title__c alpha = title('Alpha');
        String missingDate = dmlError(new Title__c(Id = alpha.Id, Status__c = 'Reviewed'), false);
        Assert.isTrue(missingDate.contains('Reviewed On'), missingDate);

        Assert.isNull(dmlError(new Title__c(Id = alpha.Id, Status__c = 'Reviewed', Reviewed_On__c = Date.today()), false));
    }

    @IsTest
    static void revotingReplacesTheMembersResponse() {
        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo', 'Charlie' });
        update new Title__c(Id = title('Charlie').Id, Notes__c = 'Short and haunting.');

        System.runAs(user('bcmem1')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo', 'Charlie' }));
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Charlie', 'Bravo', 'Alpha' }));

            BookClubSurveyController.SurveyView view = BookClubSurveyController.getSurvey(survey.Id);
            Assert.isTrue(view.hasVoted);
            Assert.areEqual('Charlie', view.options[0].titleName, 'Response is shown in the member\'s saved order');
            Assert.areEqual(1, view.options[0].rank);
            Assert.areEqual('Short and haunting.', view.options[0].notes, 'Voters see why each title was suggested');
        }

        Assert.areEqual(1, [SELECT COUNT() FROM Survey_Response__c WHERE Survey__c = :survey.Id]);
        Assert.areEqual(3, [SELECT COUNT() FROM Survey_Ranking__c]);
        Survey_Option__c charlie = [
            SELECT Total_Points__c, First_Choice_Votes__c FROM Survey_Option__c
            WHERE Survey__c = :survey.Id AND Title__r.Name = 'Charlie'
        ];
        Assert.areEqual(3, charlie.Total_Points__c);
        Assert.areEqual(1, charlie.First_Choice_Votes__c);
    }

    @IsTest
    static void incompleteOrDraftResponsesAreRejected() {
        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo', 'Charlie' });
        Survey__c draft = new Survey__c(Name = 'x');
        insert draft;

        System.runAs(user('bcmem1')) {
            try {
                BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo' }));
                Assert.fail('Expected an incomplete response to fail');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('exactly once'), e.getMessage());
            }
            try {
                BookClubSurveyController.submitRanking(draft.Id, new List<Id>());
                Assert.fail('Expected voting on a draft to fail');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not open'), e.getMessage());
            }
        }
    }

    @IsTest
    static void membersSeeOnlyTheirOwnResponses() {
        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo' });
        User member1 = user('bcmem1');
        System.runAs(member1) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo' }));
        }
        System.runAs(user('bcmem2')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Bravo', 'Alpha' }));
        }

        System.runAs(member1) {
            List<Survey_Response__c> visible = [SELECT OwnerId FROM Survey_Response__c];
            Assert.areEqual(1, visible.size(), 'Members see only their own response');
            Assert.areEqual(member1.Id, visible[0].OwnerId);
            Assert.areEqual(2, [SELECT COUNT() FROM Survey_Ranking__c], 'Only rankings on their own response');
            try {
                BookClubSurveyController.getResults(survey.Id);
                Assert.fail('Members cannot see results while voting is open');
            } catch (AuraHandledException e) {
                Assert.areEqual(BookClubSurveyController.RESULTS_HIDDEN, e.getMessage());
            }
        }
        System.runAs(user('bcadmin')) {
            Assert.areEqual(2, [SELECT COUNT() FROM Survey_Response__c], 'Admins see every response');
            Assert.areEqual(4, [SELECT COUNT() FROM Survey_Ranking__c]);
            Assert.areEqual(2, BookClubSurveyController.getResults(survey.Id).responseCount);
            BookClubSurveyController.closeSurvey(survey.Id, title('Alpha').Id);
        }
        System.runAs(member1) {
            Assert.areEqual(2, BookClubSurveyController.getResults(survey.Id).responseCount,
                'Once closed, members see results, and the response count includes everyone');
        }
    }

    // Members without a Salesforce license vote on the Book Club site as External Apps Login users.
    @IsTest
    static void siteMembersCanVote() {
        User owner = user('bcadmin');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole role = new UserRole(Name = 'Test Organizer', DeveloperName = 'Test_Book_Club_Organizer');
            insert role;
            owner.UserRoleId = role.Id;
            update owner;
        }
        Account club = new Account(Name = 'Book Club Members', OwnerId = owner.Id);
        insert club;
        Contact contact = new Contact(LastName = 'sitemem', AccountId = club.Id);
        insert contact;

        User siteMember;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            siteMember = new User(
                Alias = 'sitemem',
                LastName = 'sitemem',
                Email = 'sitemem@example.com',
                Username = 'sitemem@' + UserInfo.getOrganizationId() + '.bookclub.test',
                ProfileId = [SELECT Id FROM Profile WHERE Name = 'Book Club Site Member'].Id,
                ContactId = contact.Id,
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/Los_Angeles'
            );
            insert siteMember;
            insert new PermissionSetAssignment(
                AssigneeId = siteMember.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Book_Club_Site_Member'].Id
            );
        }

        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo' });
        System.runAs(user('bcmem1')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Bravo', 'Alpha' }));
        }
        System.runAs(siteMember) {
            BookClubSurveyController.SurveyList surveyList = BookClubSurveyController.getSurveys();
            Assert.isFalse(surveyList.isAdmin);
            Assert.areEqual(survey.Id, surveyList.surveys[0].id);

            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo' }));
            Assert.isTrue(BookClubSurveyController.getSurvey(survey.Id).hasVoted);
            Assert.areEqual(1, [SELECT COUNT() FROM Survey_Response__c], 'Site members see only their own response');
            try {
                BookClubSurveyController.getResults(survey.Id);
                Assert.fail('Site members cannot see results while voting is open');
            } catch (AuraHandledException e) {
                Assert.areEqual(BookClubSurveyController.RESULTS_HIDDEN, e.getMessage());
            }
        }
    }

    @IsTest
    static void resultsSuggestTheLeaderAndFlagTies() {
        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo' });
        System.runAs(user('bcmem1')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo' }));
        }
        System.runAs(user('bcmem2')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Bravo', 'Alpha' }));
        }
        System.runAs(user('bcadmin')) {
            BookClubSurveyController.SurveyResults tied = BookClubSurveyController.getResults(survey.Id);
            Assert.isTrue(tied.isTie);
            Assert.areEqual(2, tied.responseCount);

            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo' }));
            BookClubSurveyController.SurveyResults results = BookClubSurveyController.getResults(survey.Id);
            Assert.isFalse(results.isTie);
            Assert.areEqual(title('Alpha').Id, results.suggestedWinnerTitleId);
            Assert.areEqual(5, results.options[0].totalPoints);
            Assert.areEqual(4, results.options[1].totalPoints);
        }
    }

    @IsTest
    static void pointTiesAreBrokenByFirstChoiceVotes() {
        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo' });
        Survey__c loaded = [
            SELECT Id, Status__c, Selected_Title__c FROM Survey__c WHERE Id = :survey.Id
        ];
        Id alpha = title('Alpha').Id;
        Id bravo = title('Bravo').Id;
        BookClubSurveyController.SurveyResults results = new BookClubSurveyController.SurveyResults(loaded);
        results.responseCount = 3;
        results.options.add(new BookClubSurveyController.OptionResult(alpha, 'Alpha', 6, 1));
        results.options.add(new BookClubSurveyController.OptionResult(bravo, 'Bravo', 6, 2));

        BookClubSurveyController.rankResults(results);

        Assert.areEqual(bravo, results.suggestedWinnerTitleId);
        Assert.isFalse(results.isTie);
        Assert.isFalse(results.options[1].isLeader);
    }

    @IsTest
    static void adminConfirmsTheWinner() {
        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo' });

        System.runAs(user('bcmem1')) {
            try {
                BookClubSurveyController.closeSurvey(survey.Id, title('Alpha').Id);
                Assert.fail('Members cannot close surveys');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('admin'), e.getMessage());
            }
        }

        System.runAs(user('bcadmin')) {
            try {
                BookClubSurveyController.closeSurvey(survey.Id, title('Echo').Id);
                Assert.fail('Winner must be on the survey');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('survey\'s titles'), e.getMessage());
            }

            BookClubSurveyController.closeSurvey(survey.Id, title('Alpha').Id);

            BookClubSurveyController.SurveyList surveyList = BookClubSurveyController.getSurveys();
            Assert.isTrue(surveyList.isAdmin);
            Assert.areEqual('Closed', surveyList.surveys[0].status);
            Assert.areEqual('Alpha', surveyList.surveys[0].selectedTitleName);
        }

        Title__c alpha = title('Alpha');
        Assert.areEqual('Selected', alpha.Status__c);
        Assert.areEqual(Date.today(), alpha.Decided_On__c);
        Assert.areEqual('Suggested', title('Bravo').Status__c, 'Losing titles stay in the pool');

        System.runAs(user('bcmem1')) {
            try {
                BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo' }));
                Assert.fail('Closed surveys reject votes');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not open'), e.getMessage());
            }
        }
    }

    @IsTest
    static void adminBuildsASurveyInOneStep() {
        List<Id> picks = new List<Id>{ title('Charlie').Id, title('Alpha').Id };

        System.runAs(user('bcmem1')) {
            try {
                BookClubSurveyController.createSurvey(picks, true);
                Assert.fail('Members cannot create surveys');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('admin'), e.getMessage());
            }
        }

        System.runAs(user('bcadmin')) {
            List<BookClubSurveyController.CandidateTitle> candidates = BookClubSurveyController.getSuggestedTitles();
            Assert.areEqual(6, candidates.size(), 'Only Suggested titles are offered');
            Assert.areEqual('Alpha', candidates[0].name);

            for (List<Id> bad : new List<List<Id>>{
                new List<Id>{ title('Alpha').Id },
                new List<Id>{ title('Alpha').Id, title('Alpha').Id },
                new List<Id>{ title('Alpha').Id, title('Bravo').Id, title('Charlie').Id, title('Delta').Id, title('Echo').Id, title('Foxtrot').Id }
            }) {
                try {
                    BookClubSurveyController.createSurvey(bad, false);
                    Assert.fail('Expected 2 to 5 different titles');
                } catch (AuraHandledException e) {
                    Assert.isTrue(e.getMessage().contains('2 to 5'), e.getMessage());
                }
            }
            try {
                BookClubSurveyController.createSurvey(new List<Id>{ title('Alpha').Id, title('Already Reviewed').Id }, false);
                Assert.fail('Reviewed titles cannot go on a survey');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('already reviewed'), e.getMessage());
            }
            Assert.areEqual(0, [SELECT COUNT() FROM Survey__c], 'A failed save leaves no partial survey');

            Id draftId = BookClubSurveyController.createSurvey(picks, false);
            Id publishedId = BookClubSurveyController.createSurvey(picks, true);

            Survey__c draft = [SELECT Name, Status__c, Published_On__c FROM Survey__c WHERE Id = :draftId];
            Assert.areEqual(BookClubTriggerHandler.defaultName(Date.today()), draft.Name);
            Assert.areEqual('Draft', draft.Status__c);
            Assert.isNull(draft.Published_On__c);

            Survey__c published = [SELECT Status__c, Published_On__c FROM Survey__c WHERE Id = :publishedId];
            Assert.areEqual('Published', published.Status__c);
            Assert.areEqual(Date.today(), published.Published_On__c);

            List<Survey_Option__c> options = [
                SELECT Title__r.Name, Display_Order__c FROM Survey_Option__c
                WHERE Survey__c = :publishedId ORDER BY Display_Order__c
            ];
            Assert.areEqual('Charlie', options[0].Title__r.Name, 'Options keep the order they were picked in');
            Assert.areEqual(2, options[1].Display_Order__c);
        }
    }

    @IsTest
    static void closingInTheStandardUiSelectsTheLeader() {
        Survey__c survey = publishSurvey(new List<String>{ 'Alpha', 'Bravo', 'Charlie' });
        Survey__c closing = new Survey__c(Id = survey.Id, Status__c = 'Closed');
        Assert.areEqual(BookClubTriggerHandler.NO_RESPONSES, dmlError(closing, false));

        System.runAs(user('bcmem1')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Alpha', 'Bravo', 'Charlie' }));
        }
        System.runAs(user('bcmem2')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Bravo', 'Alpha', 'Charlie' }));
        }
        Assert.areEqual(BookClubTriggerHandler.TIED, dmlError(closing, false));
        Assert.areEqual(BookClubTriggerHandler.NOT_AN_OPTION,
            dmlError(new Survey__c(Id = survey.Id, Status__c = 'Closed', Selected_Title__c = title('Echo').Id), false));

        System.runAs(user('bcadmin')) {
            BookClubSurveyController.submitRanking(survey.Id, optionIds(survey.Id, new List<String>{ 'Bravo', 'Charlie', 'Alpha' }));
            update new Survey__c(Id = survey.Id, Status__c = 'Closed');
        }

        Assert.areEqual(title('Bravo').Id, [SELECT Selected_Title__c FROM Survey__c WHERE Id = :survey.Id].Selected_Title__c);
        Title__c bravo = title('Bravo');
        Assert.areEqual('Selected', bravo.Status__c);
        Assert.areEqual(Date.today(), bravo.Decided_On__c);
        Assert.areEqual('Suggested', title('Alpha').Status__c);
    }

    @IsTest
    static void surveyListShowsPublishedFirstAndHidesDrafts() {
        Survey__c closed = publishSurvey(new List<String>{ 'Charlie', 'Delta' });
        closed.Status__c = 'Closed';
        closed.Selected_Title__c = title('Charlie').Id;
        update closed;
        Survey__c open = publishSurvey(new List<String>{ 'Alpha', 'Bravo' });
        insert new Survey__c(Name = 'draft');

        System.runAs(user('bcmem1')) {
            BookClubSurveyController.SurveyList surveyList = BookClubSurveyController.getSurveys();
            Assert.isFalse(surveyList.isAdmin);
            Assert.isFalse(surveyList.isSite, 'Tests run outside the member site');
            Assert.areEqual(2, surveyList.surveys.size());
            Assert.areEqual(open.Id, surveyList.surveys[0].id);
            Assert.areEqual(closed.Id, surveyList.surveys[1].id);
            Assert.isFalse(BookClubSurveyController.getSurvey(open.Id).hasVoted);
        }
    }
}
