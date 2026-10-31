// Backs the titleReviews LWC ("The Bookshelf"): members browse every title,
// suggest new ones, rate any title 1–5 stars with a comment (once per title),
// and read everyone's reviews.
public with sharing class BookClubReviewController {
    static final String TITLE_SUGGESTED = 'Suggested';

    // Adds a Suggested title, credited to the running user, so the admin can
    // put it on a survey. Exact duplicates (same title and author) are refused.
    @AuraEnabled
    public static Id suggestTitle(String name, String author, String titleType, String notes) {
        String trimmedName = name?.trim();
        String trimmedAuthor = String.isBlank(author) ? null : author.trim();
        if (String.isBlank(trimmedName)) {
            throw error('Enter the title.');
        }
        List<Title__c> existing = [
            SELECT Name, Status__c
            FROM Title__c
            WHERE Name = :trimmedName AND Author__c = :trimmedAuthor
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            throw error('"' + existing[0].Name + '" is already on the bookshelf (' + existing[0].Status__c + ').');
        }

        Title__c title = new Title__c(
            Name = trimmedName,
            Author__c = trimmedAuthor,
            Title_Type__c = String.isBlank(titleType) ? 'Book' : titleType,
            Notes__c = String.isBlank(notes) ? null : notes.trim(),
            Status__c = TITLE_SUGGESTED,
            Suggested_By__c = UserInfo.getUserId(),
            Suggested_On__c = Date.today()
        );
        try {
            insert as user title;
        } catch (DmlException e) {
            throw error(e.getDmlMessage(0));
        }
        return title.Id;
    }

    // Not cacheable: averages change as members review.
    @AuraEnabled
    public static List<TitleSummary> getTitles() {
        Map<Id, TitleSummary> byId = new Map<Id, TitleSummary>();
        for (Title__c title : [
            SELECT Id, Name, Author__c, Title_Type__c, Status__c, Overall_Score__c, Notes__c
            FROM Title__c
            WITH USER_MODE
            ORDER BY Name
        ]) {
            byId.put(title.Id, new TitleSummary(title));
        }

        for (AggregateResult row : [
            SELECT Title__c titleId, AVG(Rating__c) averageRating, COUNT(Id) reviewCount
            FROM Title_Review__c
            WITH USER_MODE
            GROUP BY Title__c
        ]) {
            TitleSummary summary = byId.get((Id) row.get('titleId'));
            if (summary != null) {
                summary.averageRating = ((Decimal) row.get('averageRating')).setScale(1);
                summary.reviewCount = (Integer) row.get('reviewCount');
            }
        }

        for (Title_Review__c mine : [
            SELECT Title__c, Rating__c
            FROM Title_Review__c
            WHERE Reviewer__c = :UserInfo.getUserId()
            WITH USER_MODE
        ]) {
            TitleSummary summary = byId.get(mine.Title__c);
            if (summary != null) {
                summary.myRating = mine.Rating__c.intValue();
            }
        }
        return byId.values();
    }

    // Open Library's reader rating for a book (null for movies and periodicals).
    @AuraEnabled
    public static OpenLibraryRatings.Rating getOpenLibraryRating(Id titleId) {
        Title__c title = [
            SELECT Id, Name, Author__c, Title_Type__c, Open_Library_Checked_On__c, Open_Library_Key__c,
                Open_Library_Cover_Id__c, Open_Library_Rating__c, Open_Library_Rating_Count__c
            FROM Title__c
            WHERE Id = :titleId
            WITH USER_MODE
        ];
        return title.Title_Type__c == 'Book' ? OpenLibraryRatings.forTitle(title) : null;
    }

    // Everyone's reviews of a title, the running user's first, then newest first.
    @AuraEnabled
    public static List<ReviewView> getReviews(Id titleId) {
        List<ReviewView> mine = new List<ReviewView>();
        List<ReviewView> others = new List<ReviewView>();
        for (Title_Review__c review : [
            SELECT Id, Rating__c, Comment__c, Reviewer__c, Reviewer_Name__c, LastModifiedDate
            FROM Title_Review__c
            WHERE Title__c = :titleId
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            ReviewView view = new ReviewView(review);
            (view.isMine ? mine : others).add(view);
        }
        mine.addAll(others);
        return mine;
    }

    // Creates the running user's review of a title, or updates it if they already have one.
    @AuraEnabled
    public static void saveReview(Id titleId, Integer rating, String comment) {
        List<Title_Review__c> existing = [
            SELECT Id
            FROM Title_Review__c
            WHERE Title__c = :titleId AND Reviewer__c = :UserInfo.getUserId()
            WITH USER_MODE
        ];
        Title_Review__c review = existing.isEmpty()
            ? new Title_Review__c(Title__c = titleId)
            : new Title_Review__c(Id = existing[0].Id);
        review.Rating__c = rating;
        review.Comment__c = String.isBlank(comment) ? null : comment.trim();
        try {
            upsert as user review;
        } catch (DmlException e) {
            throw error(e.getDmlMessage(0));
        }
    }

    private static AuraHandledException error(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    public class TitleSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String author;
        @AuraEnabled public String titleType;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal clubScore;
        // The suggester's "why should we read it?" note.
        @AuraEnabled public String notes;
        @AuraEnabled public Decimal averageRating;
        @AuraEnabled public Integer reviewCount = 0;
        @AuraEnabled public Integer myRating;

        public TitleSummary(Title__c title) {
            id = title.Id;
            name = title.Name;
            author = title.Author__c;
            titleType = title.Title_Type__c;
            status = title.Status__c;
            clubScore = title.Overall_Score__c;
            notes = title.Notes__c;
        }
    }

    public class ReviewView {
        @AuraEnabled public Id id;
        @AuraEnabled public Integer rating;
        @AuraEnabled public String comment;
        @AuraEnabled public String reviewerName;
        @AuraEnabled public Datetime reviewedOn;
        @AuraEnabled public Boolean isMine;

        public ReviewView(Title_Review__c review) {
            id = review.Id;
            rating = review.Rating__c.intValue();
            comment = review.Comment__c;
            reviewerName = review.Reviewer_Name__c;
            reviewedOn = review.LastModifiedDate;
            isMine = review.Reviewer__c == UserInfo.getUserId();
        }
    }
}
