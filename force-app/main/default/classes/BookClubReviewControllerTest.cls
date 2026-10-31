@IsTest
private class BookClubReviewControllerTest {
    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile minimum = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'];
            Id memberPermSet = [SELECT Id FROM PermissionSet WHERE Name = 'Book_Club_Member'].Id;
            String suffix = UserInfo.getOrganizationId() + System.currentTimeMillis();
            List<User> users = new List<User>();
            for (String alias : new List<String>{ 'rvmem1', 'rvmem2' }) {
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
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = users[0].Id, PermissionSetId = memberPermSet),
                new PermissionSetAssignment(AssigneeId = users[1].Id, PermissionSetId = memberPermSet)
            };
        }
        insert new List<Title__c>{
            new Title__c(Name = 'Middlemarch', Author__c = 'George Eliot'),
            new Title__c(
                Name = 'Persuasion', Author__c = 'Jane Austen', Status__c = 'Reviewed', Reviewed_On__c = Date.today(), Overall_Score__c = 4.5
            )
        };
    }

    static User user(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND Username LIKE '%.bookclub.test'];
    }

    static Id title(String name) {
        return [SELECT Id FROM Title__c WHERE Name = :name].Id;
    }

    @IsTest
    static void membersReviewEachTitleOnceAndCanEditIt() {
        Id middlemarch = title('Middlemarch');
        System.runAs(user('rvmem1')) {
            BookClubReviewController.saveReview(middlemarch, 4, '  A slow, wise novel.  ');
            BookClubReviewController.saveReview(middlemarch, 5, 'Better on reflection.');

            List<BookClubReviewController.ReviewView> reviews = BookClubReviewController.getReviews(middlemarch);
            Assert.areEqual(1, reviews.size(), 'Saving again updates the member\'s review');
            Assert.areEqual(5, reviews[0].rating);
            Assert.areEqual('Better on reflection.', reviews[0].comment);
            Assert.areEqual('Reader rvmem1', reviews[0].reviewerName);
            Assert.isTrue(reviews[0].isMine);

            try {
                insert new Title_Review__c(Title__c = middlemarch, Rating__c = 3);
                Assert.fail('A second review of the same title is blocked');
            } catch (DmlException e) {
                Assert.areEqual(BookClubTriggerHandler.ALREADY_REVIEWED, e.getDmlMessage(0));
            }
        }
    }

    @IsTest
    static void membersSuggestNewTitles() {
        User member = user('rvmem1');
        System.runAs(member) {
            Id suggested = BookClubReviewController.suggestTitle('  Possession  ', ' A. S. Byatt ', null, 'A literary mystery.');
            Title__c title = [
                SELECT Name, Author__c, Title_Type__c, Status__c, Suggested_By__c, Suggested_On__c, Notes__c
                FROM Title__c WHERE Id = :suggested
            ];
            Assert.areEqual('Possession', title.Name);
            Assert.areEqual('A. S. Byatt', title.Author__c);
            Assert.areEqual('Book', title.Title_Type__c);
            Assert.areEqual('Suggested', title.Status__c);
            Assert.areEqual(member.Id, title.Suggested_By__c);
            Assert.areEqual(Date.today(), title.Suggested_On__c);
            Assert.areEqual('A literary mystery.', title.Notes__c);
            for (BookClubReviewController.TitleSummary summary : BookClubReviewController.getTitles()) {
                if (summary.id == suggested) {
                    Assert.areEqual('A literary mystery.', summary.notes, 'The Bookshelf shows why it was suggested');
                }
            }

            BookClubReviewController.suggestTitle('Middlemarch', 'Someone Else', 'Movie', null);

            for (List<String> bad : new List<List<String>>{
                new List<String>{ '   ', 'Anyone' },
                new List<String>{ 'possession', 'a. s. byatt' }
            }) {
                try {
                    BookClubReviewController.suggestTitle(bad[0], bad[1], 'Book', null);
                    Assert.fail('Expected ' + bad + ' to be refused');
                } catch (AuraHandledException e) {
                    Assert.isTrue(e.getMessage().contains('Enter the title') || e.getMessage().contains('already on the bookshelf'),
                        e.getMessage());
                }
            }
        }
        Assert.areEqual(2, [SELECT COUNT() FROM Title__c WHERE Name = 'Middlemarch'],
            'The same title by a different author is a different suggestion');
    }

    @IsTest
    static void ratingsMustBeOneToFiveStars() {
        System.runAs(user('rvmem1')) {
            for (Integer rating : new List<Integer>{ null, 0, 6 }) {
                try {
                    BookClubReviewController.saveReview(title('Middlemarch'), rating, null);
                    Assert.fail('Expected rating ' + rating + ' to be rejected');
                } catch (AuraHandledException e) {
                    Assert.isTrue(e.getMessage().contains('1 to 5'), e.getMessage());
                }
            }
        }
    }

    @IsTest
    static void membersSeeEveryonesReviewsAndTheAverage() {
        Id middlemarch = title('Middlemarch');
        Id persuasion = title('Persuasion');
        User member1 = user('rvmem1');
        User member2 = user('rvmem2');
        System.runAs(member1) {
            BookClubReviewController.saveReview(middlemarch, 5, 'Loved it.');
            BookClubReviewController.saveReview(persuasion, 4, null);
        }
        System.runAs(member2) {
            BookClubReviewController.saveReview(middlemarch, 2, 'Too long for me.');

            List<BookClubReviewController.ReviewView> reviews = BookClubReviewController.getReviews(middlemarch);
            Assert.areEqual(2, reviews.size(), 'Members read everyone\'s reviews');
            Assert.isTrue(reviews[0].isMine, 'The member\'s own review comes first');
            Assert.areEqual('Loved it.', reviews[1].comment);

            Map<String, BookClubReviewController.TitleSummary> byName = new Map<String, BookClubReviewController.TitleSummary>();
            for (BookClubReviewController.TitleSummary summary : BookClubReviewController.getTitles()) {
                byName.put(summary.name, summary);
            }
            Assert.areEqual(3.5, byName.get('Middlemarch').averageRating);
            Assert.areEqual(2, byName.get('Middlemarch').reviewCount);
            Assert.areEqual(2, byName.get('Middlemarch').myRating);
            Assert.areEqual(1, byName.get('Persuasion').reviewCount, 'Reviewed titles can be reviewed too');
            Assert.areEqual(4.5, byName.get('Persuasion').clubScore);
            Assert.isNull(byName.get('Middlemarch').clubScore);
            Assert.isNull(byName.get('Persuasion').myRating);

            Title_Review__c othersReview = [
                SELECT Id FROM Title_Review__c WHERE Title__c = :middlemarch AND Reviewer__c = :member1.Id
            ];
            try {
                update as user new Title_Review__c(Id = othersReview.Id, Rating__c = 1);
                Assert.fail('Members cannot edit someone else\'s review');
            } catch (DmlException e) {
                Assert.isTrue(e.getDmlType(0).name().startsWith('INSUFFICIENT_ACCESS'), e.getMessage());
            }
        }
        Assert.areEqual(5, [SELECT Rating__c FROM Title_Review__c WHERE Title__c = :middlemarch AND Reviewer__c = :member1.Id].Rating__c);
    }
}
