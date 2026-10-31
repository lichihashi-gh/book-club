@IsTest
private class OpenLibraryRatingsTest {
    static final String FOUND = '{"numFound":1,"docs":[{"key":"/works/OL45804W","cover_i":8231856,'
        + '"ratings_average":4.123,"ratings_count":312}]}';

    class OpenLibraryMock implements HttpCalloutMock {
        Integer status;
        String body;
        Integer calls = 0;
        String lastEndpoint;

        OpenLibraryMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            lastEndpoint = request.getEndpoint();
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }

    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User member = new User(
                Alias = 'olmem',
                LastName = 'olmem',
                Email = 'olmem@example.com',
                Username = 'olmem@' + UserInfo.getOrganizationId() + System.currentTimeMillis() + '.bookclub.test',
                ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'].Id,
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/Los_Angeles'
            );
            insert member;
            insert new PermissionSetAssignment(
                AssigneeId = member.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Book_Club_Member'].Id
            );
        }
        insert new List<Title__c>{
            new Title__c(Name = 'Middlemarch', Author__c = 'George Eliot', Title_Type__c = 'Book'),
            new Title__c(Name = 'Little Women', Title_Type__c = 'Movie')
        };
    }

    static User member() {
        return [SELECT Id FROM User WHERE Alias = 'olmem' AND Username LIKE '%.bookclub.test'];
    }

    static Id title(String name) {
        return [SELECT Id FROM Title__c WHERE Name = :name].Id;
    }

    @IsTest
    static void ratingIsFetchedSavedAndReusedForAWeek() {
        OpenLibraryMock mock = new OpenLibraryMock(200, FOUND);
        Test.setMock(HttpCalloutMock.class, mock);
        Id middlemarch = title('Middlemarch');

        Test.startTest();
        System.runAs(member()) {
            OpenLibraryRatings.Rating rating = BookClubReviewController.getOpenLibraryRating(middlemarch);
            Assert.isTrue(rating.found);
            Assert.areEqual(4.12, rating.rating);
            Assert.areEqual(312, rating.ratingCount);
            Assert.areEqual('https://openlibrary.org/works/OL45804W', rating.url);
            Assert.areEqual('https://covers.openlibrary.org/b/id/8231856-M.jpg', rating.coverUrl);
            Assert.isTrue(mock.lastEndpoint.contains('title=Middlemarch'), mock.lastEndpoint);
            Assert.isTrue(mock.lastEndpoint.contains('author=George+Eliot'), mock.lastEndpoint);

            Assert.areEqual(4.12, BookClubReviewController.getOpenLibraryRating(middlemarch).rating);
        }
        Test.stopTest();

        Assert.areEqual(1, mock.calls, 'The saved rating is reused instead of calling again');
        Title__c saved = [SELECT Open_Library_Rating__c, Open_Library_Checked_On__c FROM Title__c WHERE Id = :middlemarch];
        Assert.areEqual(4.12, saved.Open_Library_Rating__c, 'Members can save the shared rating on any title');
        Assert.isNotNull(saved.Open_Library_Checked_On__c);
    }

    @IsTest
    static void unmatchedBooksAndOutagesAreHandled() {
        Id middlemarch = title('Middlemarch');
        Test.setMock(HttpCalloutMock.class, new OpenLibraryMock(200, '{"numFound":0,"docs":[]}'));
        Test.startTest();
        OpenLibraryRatings.Rating notFound = BookClubReviewController.getOpenLibraryRating(middlemarch);
        Test.stopTest();
        Assert.isFalse(notFound.found);
        Assert.isFalse(notFound.unavailable);

        Title__c stale = [SELECT Id, Name, Author__c, Open_Library_Key__c, Open_Library_Cover_Id__c,
            Open_Library_Rating__c, Open_Library_Rating_Count__c, Open_Library_Checked_On__c
            FROM Title__c WHERE Id = :middlemarch];
        stale.Open_Library_Checked_On__c = Datetime.now().addDays(-8);
        stale.Open_Library_Key__c = '/works/OL1W';
        stale.Open_Library_Rating__c = 3.5;
        Test.setMock(HttpCalloutMock.class, new OpenLibraryMock(503, 'down'));
        OpenLibraryRatings.Rating outage = OpenLibraryRatings.forTitle(stale);
        Assert.isTrue(outage.unavailable);
        Assert.areEqual(3.5, outage.rating, 'An outage still shows the last saved rating');
    }

    @IsTest
    static void onlyBooksAreLookedUp() {
        OpenLibraryMock mock = new OpenLibraryMock(200, FOUND);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Assert.isNull(BookClubReviewController.getOpenLibraryRating(title('Little Women')));
        Test.stopTest();
        Assert.areEqual(0, mock.calls);
    }
}
