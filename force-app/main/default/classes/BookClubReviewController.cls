// Backs the titleReviews LWC ("The Bookshelf"): members browse every title,
// suggest new ones (and fix their own while still Suggested), rate any title
// 1–5 stars with a comment (once per title), and read everyone's reviews.
public with sharing class BookClubReviewController {
    static final String TITLE_SUGGESTED = 'Suggested';
    @TestVisible static final String NOT_YOUR_SUGGESTION = 'Only the member who suggested this title can edit it.';
    @TestVisible static final String NO_LONGER_SUGGESTED = 'This title has already been chosen, so it can\'t be edited anymore.';

    // Adds a Suggested title, credited to the running user, so the admin can
    // put it on a survey. Exact duplicates (same title and author) are refused.
    @AuraEnabled
    public static Id suggestTitle(String name, String author, String titleType, String notes) {
        String trimmedName = name?.trim();
        String trimmedAuthor = String.isBlank(author) ? null : author.trim();
        checkNameAndDuplicates(trimmedName, trimmedAuthor, null);

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

    // Lets the member who entered a title fix a mistake or add notes while it's
    // still Suggested. Only the name, author, type and notes can change.
    @AuraEnabled
    public static void updateSuggestion(Id titleId, String name, String author, String titleType, String notes) {
        Title__c current = [
            SELECT OwnerId, Status__c, Name, Author__c, Title_Type__c FROM Title__c WHERE Id = :titleId WITH USER_MODE
        ];
        if (current.OwnerId != UserInfo.getUserId()) {
            throw error(NOT_YOUR_SUGGESTION);
        }
        if (current.Status__c != TITLE_SUGGESTED) {
            throw error(NO_LONGER_SUGGESTED);
        }
        String trimmedName = name?.trim();
        String trimmedAuthor = String.isBlank(author) ? null : author.trim();
        checkNameAndDuplicates(trimmedName, trimmedAuthor, titleId);

        Title__c title = new Title__c(
            Id = titleId,
            Name = trimmedName,
            Author__c = trimmedAuthor,
            Title_Type__c = String.isBlank(titleType) ? 'Book' : titleType,
            Notes__c = String.isBlank(notes) ? null : notes.trim()
        );
        try {
            update as user title;
        } catch (DmlException e) {
            throw error(e.getDmlMessage(0));
        }

        // The cached Open Library rating was looked up by the old name, author and type.
        // Members can't edit those read-only fields, so clear them in system mode.
        if (title.Name != current.Name || title.Author__c != current.Author__c || title.Title_Type__c != current.Title_Type__c) {
            update as system new Title__c(
                Id = titleId,
                Open_Library_Checked_On__c = null,
                Open_Library_Key__c = null,
                Open_Library_Cover_Id__c = null,
                Open_Library_Rating__c = null,
                Open_Library_Rating_Count__c = null
            );
        }
    }

    // Exact duplicates (same title and author) are refused; excludeId is the title being edited.
    private static void checkNameAndDuplicates(String trimmedName, String trimmedAuthor, Id excludeId) {
        if (String.isBlank(trimmedName)) {
            throw error('Enter the title.');
        }
        List<Title__c> existing = [
            SELECT Name, Status__c
            FROM Title__c
            WHERE Name = :trimmedName AND Author__c = :trimmedAuthor AND Id != :excludeId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            throw error('"' + existing[0].Name + '" is already on the bookshelf (' + existing[0].Status__c + ').');
        }
    }

    // Not cacheable: averages change as members review.
    @AuraEnabled
    public static List<TitleSummary> getTitles() {
        Map<Id, TitleSummary> byId = new Map<Id, TitleSummary>();
        for (Title__c title : [
            SELECT Id, Name, Author__c, Title_Type__c, Status__c, Overall_Score__c, Notes__c, OwnerId
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
        // The running user entered it and it's still Suggested (see updateSuggestion).
        @AuraEnabled public Boolean canEdit;

        public TitleSummary(Title__c title) {
            id = title.Id;
            name = title.Name;
            author = title.Author__c;
            titleType = title.Title_Type__c;
            status = title.Status__c;
            clubScore = title.Overall_Score__c;
            notes = title.Notes__c;
            canEdit = title.OwnerId == UserInfo.getUserId() && title.Status__c == TITLE_SUGGESTED;
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
