# CLAUDE.md

Salesforce DX project for the **Book Club**: an internal "Book Club Admin" Lightning app plus a members-only Experience Cloud site where members vote on the next read, pick a meeting date, and review titles. Apex, LWC, one Aura wrapper, API version 62.0, `sf` CLI. The git remote is `github.com/lichihashi-gh/book-club`.

The repo also holds `AccountApi`, a small Apex REST endpoint used by a separate Next.js app ("OSS LWC Fun"). That app is not in this repo.

## Commands

```bash
sf org login web --alias bookclub   # only if the bookclub alias isn't already authenticated
sf project deploy validate --source-dir force-app --test-level RunSpecifiedTests \
  --tests BookClubSurveyControllerTest --tests BookClubMeetingsTest --tests BookClubReviewControllerTest --tests OpenLibraryRatingsTest --tests AccountApiTest --wait 20   # check-only
sf project deploy start --source-dir force-app
sf apex run test --class-names BookClubSurveyControllerTest --class-names BookClubMeetingsTest --class-names BookClubReviewControllerTest --class-names OpenLibraryRatingsTest --class-names AccountApiTest --code-coverage --result-format human --wait 10
```

The default target org is `bookclub` (set in `.sf/config.json`). Don't change it unless asked. When you add a test class, add it to both test lists above and to the README.

`code-analyzer.yml` configures Salesforce Code Analyzer (`sf code-analyzer run`). It points at a user-local Temurin 21 JDK (this Mac has no system Java), and the Flow engine is disabled because the project has no Flows.

There is no Node/npm project, so there are no LWC Jest tests.

## Repo housekeeping

- `.gitignore` excludes `.sf/` and `.sfdx/` (local CLI state, including the target-org setting) and `.DS_Store`.
- `.forceignore` lists only `**/jsconfig.json` and `**/.eslintrc.json`. Add `**/__tests__/**` if LWC tests are ever added.
- `sourceApiVersion` is 62.0 in `sfdx-project.json`. New `-meta.xml` files should match.
- `manifest/package.xml` is a wildcard manifest covering Apex, Aura, LWC and static resources only. Deploy with `--source-dir force-app` so objects, permission sets, the site and so on are included.

## Layout

```
force-app/main/default/
  classes/
    AccountApi.cls                    @RestResource(urlMapping='/accounts/*'), GET only
    BookClubSurveyController.cls      @AuraEnabled backend for the survey LWCs; isAdmin()
    BookClubTriggerHandler.cls        survey naming/stamping, duplicate-option check, review defaults, marking selected titles
    BookClubMeetings.cls              meeting creation on survey close, date suggestions, invitation/confirmation emails
    BookClubMeetingController.cls     @AuraEnabled backend for meetingPoll
    BookClubReviewController.cls      @AuraEnabled backend for titleReviews (The Bookshelf)
    OpenLibraryRatings.cls            Open Library lookup + cache
    *Test.cls
  triggers/                           SurveyTrigger, SurveyOptionTrigger, TitleReviewTrigger, MeetingTrigger (no logic; delegate to classes)
  objects/                            Title__c, Survey__c, Survey_Option__c, Survey_Response__c, Survey_Ranking__c,
                                      Title_Review__c, Book_Club_Meeting__c, Meeting_Date_Option__c, Meeting_Response__c, Meeting_Availability__c
  lwc/
    bookClubSurvey                    container with tabs (see below)
    surveyResponse, surveyResults, surveyBuilder, meetingPoll, titleReviews, bookClubWelcome, bookClubUtils
  aura/bookClubNewSurvey/             wraps surveyBuilder to override New on Survey__c
  permissionsets/                     Book_Club_Admin, Book_Club_Member, Book_Club_Site_Member
  profiles/                           Admin, StandardAul (Book Club default app only), Book Club Site Member
  customPermissions/                  Book_Club_Admin (checked via FeatureManagement)
  networks/ sites/ experiences/       "Book Club" Experience Cloud site (experiences/Book_Club1)
  remoteSiteSettings/ cspTrustedSites/  Open_Library; Open_Library_Covers, Archive_Org_Covers
  settings/                           Communities (Digital Experiences on), ExperienceBundle metadata on
  applications/ tabs/ flexipages/ layouts/ navigationMenus/
config/project-scratch-def.json       Developer edition, no features
```

### UI surfaces

- **`bookClubSurvey`** is the container. On the site it shows the tabs Vote for Our Next Read, Pick a Meeting Date and The Bookshelf. Internally it shows Results (admins only), Schedule the Meeting (Pick a Meeting Date for non-admins) and The Bookshelf. The tabs are a custom, accessible tab list (big colored buttons with hints, arrow-key navigation), not `lightning-tabset`, because some members find the standard thin tabs hard to see. Tab labels live in constants at the top of `bookClubSurvey.js`; keep the site navigation menu and the `/meeting` page title in step with them. `isSite` comes from Apex (`Network.getNetworkId() != null` in `getSurveys`). **Don't import `@salesforce/community/*`** in these components; doing so blanked the internal page.
- **`bookClubWelcome`** is the seasonal site banner. The season is picked by month, or forced through its Season property in Experience Builder.
- **`titleReviews`** ("The Bookshelf") lets members browse, suggest and review titles.
- **`meetingPoll`**: on the site, members tick the Sundays they can make. Internally, admins see the tally and click **Schedule & email members**.
- **Site pages**: home (`c:bookClubWelcome` + `c:bookClubSurvey`), `/bookshelf` (titleReviews), and `/meeting` (meetingPoll, linked from the emails). Site colors are in `brandingSets/`, and serif headings are in the `themes/` custom CSS.
- **Internal app**: "Book Club Admin" (API name `Book_Club`; the member site is also called "Book Club"). It has the app pages "Results" (`Book_Club_Survey`) and "Bookshelf" (`Book_Club_Reviews`). **Voting is site-only.**

## Book Club domain

Terminology: a **survey** is one selection round, and a member's ranked vote on it is a **response**. Don't introduce other terms like "ballot".

### Data model

- `Title__c` is a book, movie or periodical. `Status__c` is Suggested / Selected / Reviewed, and Reviewed requires `Reviewed_On__c` (validation rule). Other fields: `Overall_Score__c` (1–5, validation rule), `Decided_On__c`, `Suggested_By__c` (lookup to User), author, and type. Historic titles are entered by hand.
- `Survey__c`: on insert, the trigger sets Name to `Next Read - MM/dd/yyyy` (creation date), replacing whatever was typed. Renaming afterwards is allowed. `Status__c` goes Draft → Published → Closed. The trigger stamps `Published_On__c` / `Closed_On__c` with today on those status changes. Both fields are read-only, but System Administrators bypass layout/FLS, so **the trigger reverts any manual change**. `Selected_Title__c` is the winner. There's a roll-up `Option_Count__c`, but no response-count roll-up (responses are a lookup); `getResults` counts responses in Apex.
- `Survey_Option__c`: master-detail to Survey, plus a required lookup to Title. The **lookup filter excludes Reviewed titles**. `Unique_Key__c` (surveyId:titleId, set by the trigger) blocks duplicates. The roll-ups `Total_Points__c` and `First_Choice_Votes__c` come from rankings.
- `Survey_Response__c`: one per member per survey, enforced by a unique `Unique_Key__c` = surveyId:userId. It has a **required lookup** (Restrict delete) to Survey, deliberately not master-detail, so the object can be **Private**. The voter owns it. Don't convert it back to master-detail or add a roll-up that needs it.
- `Survey_Ranking__c`: junction of Response × Option, with `Rank__c` (1 = top) and `Points__c` = optionCount − rank + 1.
- `Title_Review__c`: required lookup to Title (Restrict), `Rating__c` 1–5 (validation rule `Rating_Range`), and `Comment__c`. The trigger sets `Reviewer__c`, `Reviewer_Name__c` and `Unique_Key__c` (titleId:userId, unique), and keeps the reviewer from changing. `Reviewer_Name__c` is stored because site members can't always see other User records. OWD is Public Read Only (internal and external): everyone reads all reviews, and only the author edits. `suggestTitle` creates a Suggested Title credited to the member (`Suggested_By__c`) and refuses an exact title + author duplicate.
- **Open Library ratings** (Goodreads closed its API in 2020): `OpenLibraryRatings` (without sharing) calls `openlibrary.org/search.json` by title + author, for Books only. It caches the result on the Title in `Open_Library_*__c` fields (rating, count, work key, cover id, checked-on) for 7 days (`CACHE_DAYS`) and falls back to the cache on an outage. It requires the Remote Site Setting `Open_Library` and the CSP trusted sites `Open_Library_Covers` and `Archive_Org_Covers` (img-src). Those fields are read-only in every permission set. The Bookshelf shows the result as "What Open Library readers think".
- **Meetings mirror the survey model.**
  - `Book_Club_Meeting__c`: Public Read Only. Required lookup to Survey, lookup to Title, `Status__c` Voting / Scheduled, `Meeting_Date__c`, and `Scheduled_On__c` stamped by the trigger.
  - `Meeting_Date_Option__c`: master-detail to the meeting, with `Option_Date__c` and a roll-up `Available_Count__c`.
  - `Meeting_Response__c`: **Private**. Required lookup to Meeting, `Unique_Key__c` = meetingId:userId, written in system mode like survey responses.
  - `Meeting_Availability__c`: junction of Response × Date Option, one row per date the member can make. A response with none means "no date works".

### Meeting logic (`BookClubMeetings`, without sharing)

`BookClubMeetings` is called from `SurveyTrigger` (after update) and from `MeetingTrigger`.

- **When a survey closes with a Selected Title**, it creates one meeting per survey (never a second). The dates come from `suggestedDates(closedOn)`: closedOn + 28 days, then the first Sunday on or after that, then the 3 Sundays after it. It emails every survey respondent via `setTargetObjectId`, with a link to `<site>/s/meeting` (from `Network.getLoginUrl` for the "Book Club" network).
- **Scheduling** (Status → Scheduled) fills a blank Meeting Date with `leadingDate` (most available; ties go to the earliest; error if no one is available). It then emails survey respondents plus meeting respondents. Changing the date while Scheduled emails again.
- Email failures are logged and never block the save.
- In `BookClubMeetingController`, the tally is admin-only (`BookClubSurveyController.isAdmin()`), like survey results.

### Rules

These are validation rules, so they also apply in the standard UI.

- At most 5 options per survey: validation rule `Max_Options`, `MAX_OPTIONS` in `BookClubSurveyController`, and `MAX_TITLES` in `surveyBuilder.js`. **Change all three together.**
- At least 2 options before a survey leaves Draft.
- Options can only be added or changed while the survey is Draft.

### Workflow

1. The admin clicks New on Book Club Surveys. That's overridden by the Aura `bookClubNewSurvey`, because LWCs can't override standard actions. It opens `surveyBuilder`, where the admin checks 2–5 Suggested titles and saves the survey as Draft or publishes it. `createSurvey` does this in one transaction and leaves the Name to the trigger. Options on a Draft can still be edited in the standard UI.
2. Members rank all the titles on the site and can re-vote until the survey closes.
3. In the Results tab the admin confirms the winner and closes the survey. The leader is pre-selected; ties are broken by first-choice votes, and a remaining tie is flagged.
4. The admin can also close by setting Status to Closed in the standard UI. In that case the trigger fills a blank `Selected_Title__c` with the leader, using the same ranking as `rankResults` (`OptionResult.compareTo`). It blocks the save when there are no responses, when there's a true tie, or when a manually chosen title isn't one of the survey's options.
5. However the survey closes, the after-update trigger sets the winning Title to Selected with `Decided_On__c` = today and creates the meeting. Losing titles stay Suggested.

### Security

- **Only admins see all responses.** Responses are Private (owner = voter), and rankings are controlled by their response, so members see only their own. Book_Club_Admin has View All.
- **Results are hidden from members while a survey is Published**, so votes in progress don't sway them. `getResults` throws `RESULTS_HIDDEN` for non-admins on open surveys, and the Results tab renders only for admins (never on the site). After a survey closes, the Vote for Our Next Read tab shows members the winner.
- Members (Book_Club_Member) can read surveys and options, read their own responses and rankings, and create/edit Titles.
- `submitRanking` writes the response and rankings in system mode, scoped to the running user's key. The response count uses a small `without sharing` inner class (count only). Everything else uses `WITH USER_MODE` / `as user`.
- Creating and closing surveys require the `Book_Club_Admin` custom permission and work only internally. `isAdmin()` = custom permission **and** `Network.getNetworkId() == null`, so the site never shows admin features, even to the admin.
- **Site members**: members without a Salesforce license use the Book Club site (`/bookclub`). Each one is set up as:
  - a Contact on the "Book Club Members" account;
  - an External Apps Login user with the `Book Club Site Member` profile;
  - the `Book_Club_Site_Member` permission set.

  That permission set is Book_Club_Member minus the app and tabs, which external licenses can't have. **Keep the two in sync.** The account owner needs a role (the admin has "Book Club Organizer"). The site has no guest access and no self-registration. Use the **Aura** template, not LWR, because the components use `ShowToastEvent`. The test `siteMembersCanVote` covers this path.
- Metadata deploys don't grant FLS to profiles, so users (including the admin) need one of the permission sets to see the fields.

### Tests

Tests create users with the `Minimum Access - Salesforce` profile plus a permission set, so they exercise the permission sets for real. Keep that pattern for new tests.

## AccountApi

`GET /services/apexrest/accounts?search=<term>&limit=<n>`

- `search` is optional and matched with `Name LIKE %term%`.
- `limit` is clamped to 1–200 and defaults to 20 when missing or non-numeric.
- Returns a bare JSON array of `AccountResponse { id, name, industry, phone }`, with lowercase keys and no `{ records: [...] }` wrapper.
- Runs `with sharing` and `WITH SECURITY_ENFORCED`.
- Known quirk: the search term goes through `String.escapeSingleQuotes` *and* is bound with `:escapedSearch`. Bind variables don't need escaping, so names with apostrophes (e.g. `O'Brien`) won't match.

## Apex conventions

- `global with sharing` for REST resources.
- Bind variables in dynamic SOQL.
- Response DTO inner classes rather than returning sObjects (`@AuraEnabled` fields for LWC controllers).
- Triggers contain no logic and delegate to handler classes.
- An `@IsTest` class per Apex class. REST tests set up `RestContext.request`/`response`.
