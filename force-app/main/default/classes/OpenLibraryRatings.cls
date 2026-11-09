// Looks up a book's reader rating on Open Library (openlibrary.org) and keeps it
// on the Title for a week, so The Bookshelf doesn't call out on every view.
// Without sharing: members can read every Title but can't edit other people's,
// and the saved rating is shared data rather than the member's own edit.
public without sharing class OpenLibraryRatings {
    @TestVisible
    static final String ENDPOINT = 'https://openlibrary.org/search.json';
    static final Integer CACHE_DAYS = 7;

    public static Rating forTitle(Title__c title) {
        if (title.Open_Library_Checked_On__c != null
            && title.Open_Library_Checked_On__c > Datetime.now().addDays(-CACHE_DAYS)) {
            return new Rating(title);
        }

        Title__c fresh;
        try {
            fresh = lookUp(title);
        } catch (CalloutException e) {
            // Open Library is unreachable: show whatever was saved last time.
            Rating cached = new Rating(title);
            cached.unavailable = true;
            return cached;
        }
        try {
            update as system fresh;
        } catch (DmlException e) {
            // Saving is only a cache; the rating is still worth showing.
            System.debug(LoggingLevel.WARN, 'Could not save the Open Library rating: ' + e.getDmlMessage(0));
        }
        return new Rating(fresh);
    }

    // Before a book is saved: does Open Library know this title and author? When it
    // doesn't, Open Library's best match for the title alone comes back as a suggestion,
    // so a member can fix a typo. Open Library doesn't have every book, so callers only warn.
    public static Match check(String name, String author) {
        Match match = new Match();
        if (String.isBlank(name)) {
            return match;
        }
        try {
            Map<String, Object> doc = firstDoc(name, author, MATCH_FIELDS);
            match.found = doc != null;
            if (doc == null && String.isNotBlank(author)) {
                doc = firstDoc(name, null, MATCH_FIELDS);
            }
            match.fill(doc);
        } catch (CalloutException e) {
            match.unavailable = true;
        }
        return match;
    }

    static final String MATCH_FIELDS = 'key,title,author_name,cover_i';

    // Open Library's top search result for a title (and author), or null when there's none.
    private static Map<String, Object> firstDoc(String name, String author, String fields) {
        String url = ENDPOINT
            + '?limit=1&fields=' + fields
            + '&title=' + EncodingUtil.urlEncode(name, 'UTF-8');
        if (String.isNotBlank(author)) {
            url += '&author=' + EncodingUtil.urlEncode(author, 'UTF-8');
        }
        HttpRequest request = new HttpRequest();
        request.setEndpoint(url);
        request.setMethod('GET');
        request.setTimeout(10000);
        request.setHeader('User-Agent', 'BookClubSalesforce/1.0');
        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() != 200) {
            throw new CalloutException('Open Library returned ' + response.getStatusCode());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        List<Object> docs = (List<Object>) body.get('docs');
        return docs == null || docs.isEmpty() ? null : (Map<String, Object>) docs[0];
    }

    private static Title__c lookUp(Title__c title) {
        Map<String, Object> doc = firstDoc(title.Name, title.Author__c, 'key,cover_i,ratings_average,ratings_count');

        Title__c result = new Title__c(
            Id = title.Id,
            Open_Library_Checked_On__c = Datetime.now(),
            Open_Library_Key__c = null,
            Open_Library_Cover_Id__c = null,
            Open_Library_Rating__c = null,
            Open_Library_Rating_Count__c = null
        );
        if (doc != null) {
            result.Open_Library_Key__c = (String) doc.get('key');
            result.Open_Library_Cover_Id__c = doc.get('cover_i') == null ? null : String.valueOf(doc.get('cover_i'));
            if (doc.get('ratings_average') != null) {
                result.Open_Library_Rating__c = Decimal.valueOf(String.valueOf(doc.get('ratings_average'))).setScale(2);
                result.Open_Library_Rating_Count__c = doc.get('ratings_count') == null
                    ? 0
                    : Integer.valueOf(doc.get('ratings_count'));
            }
        }
        return result;
    }

    // What check() found: found = the title and author matched; otherwise title and
    // author (when set) are Open Library's best guess for the title alone.
    public class Match {
        @AuraEnabled public Boolean found = false;
        @AuraEnabled public Boolean unavailable = false;
        @AuraEnabled public String title;
        @AuraEnabled public String author;
        @AuraEnabled public String url;
        @AuraEnabled public String coverUrl;

        void fill(Map<String, Object> doc) {
            if (doc == null) {
                return;
            }
            title = (String) doc.get('title');
            List<Object> authors = (List<Object>) doc.get('author_name');
            author = authors == null || authors.isEmpty() ? null : (String) authors[0];
            url = doc.get('key') == null ? null : 'https://openlibrary.org' + doc.get('key');
            coverUrl = doc.get('cover_i') == null ? null : 'https://covers.openlibrary.org/b/id/' + doc.get('cover_i') + '-S.jpg';
        }
    }

    public class Rating {
        @AuraEnabled public Boolean found = false;
        @AuraEnabled public Boolean unavailable = false;
        @AuraEnabled public Decimal rating;
        @AuraEnabled public Integer ratingCount;
        @AuraEnabled public String url;
        @AuraEnabled public String coverUrl;
        @AuraEnabled public Datetime checkedOn;

        public Rating(Title__c title) {
            checkedOn = title.Open_Library_Checked_On__c;
            if (title.Open_Library_Key__c != null) {
                found = true;
                url = 'https://openlibrary.org' + title.Open_Library_Key__c;
                rating = title.Open_Library_Rating__c;
                ratingCount = title.Open_Library_Rating_Count__c?.intValue();
                if (title.Open_Library_Cover_Id__c != null) {
                    coverUrl = 'https://covers.openlibrary.org/b/id/' + title.Open_Library_Cover_Id__c + '-M.jpg';
                }
            }
        }
    }
}
