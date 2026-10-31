# Salesforce API

Salesforce DX project containing Apex classes and REST endpoints consumed by the sibling **OSS LWC Fun** Next.js application.

## Starter endpoint

The `AccountApi` Apex REST resource is exposed at:

```text
/services/apexrest/accounts
```

Optional query parameters:

- `search`: account-name search term
- `limit`: result count between 1 and 200; defaults to 20

Example:

```text
/services/apexrest/accounts?search=Acme&limit=10
```

## Development workflow

Authenticate the Salesforce CLI:

```bash
sf org login web
```

Deploy source to the authenticated org:

```bash
sf project deploy start --source-dir force-app
```

Run the Apex tests:

```bash
sf apex run test --class-names BookClubSurveyControllerTest --class-names BookClubMeetingsTest --class-names BookClubReviewControllerTest --class-names OpenLibraryRatingsTest --class-names AccountApiTest --code-coverage --result-format human --wait 10
```

## Book Club

The **Book Club Admin** Lightning app tracks every suggested title and runs selection surveys where members rank the candidates.

### Setup

1. Deploy (above).
2. Assign the **Book Club Admin** permission set to yourself. Members either log in to the member site (below; no Salesforce license needed) Voting happens only on the site, so every member needs a site login.

### Member site (no Salesforce license needed)

Members without a Salesforce license vote on the **Book Club** Experience Cloud site at
`https://orgfarm-8ff5c8baa2-dev-ed.develop.my.site.com/bookclub`. The site's home page has the seasonal banner and three tabs: **Vote for Our Next Read**, **Pick a Meeting Date** and **The Bookshelf**. Each tab is a large, separately colored button with a short hint underneath, so they are easy to tell apart. There's no Results tab on the site: members don't see results while a survey is open, so votes in progress can't sway them. Only members can log in; the site has no guest access or self-registration.

To add a site member:

1. Under the **Book Club Members** account, create a Contact for the member, with their email.
2. On the Contact, click **Enable as External User** (or **Enable Customer User**). Use the **External Apps Login** license and the **Book Club Site Member** profile.
3. Assign the **Book Club Site Member** permission set to the new user. It has the same access as Book Club Member, minus the Lightning app and tabs, which external licenses can't have.

The member gets a welcome email to set a password. The org has 40 External Apps Login licenses.

### The Bookshelf

On **The Bookshelf** tab, members browse every title, suggest new ones (**Suggest a title**: the title is added as Suggested, credited to them, and shows up in the survey builder), and rate any title (suggested, selected or reviewed): 1 to 5 stars plus an optional comment. For books, a **What Open Library readers think** section shows the book's rating on [Open Library](https://openlibrary.org), with its cover and a link. It's looked up by title and author, saved on the Title, and refreshed weekly. Each member can review a title once and edit that review any time. Everyone can read everyone's reviews, but only the author can change theirs. In the Book Club Admin app, a title's reviews appear in the **Reviews** related list on the Title page.

### Scheduling the meeting

When a survey closes, a **Book Club Meeting** is created for the selected title with four suggested dates: count four weeks from the day the book was chosen (time to read it), then take the next four Sundays from that day on. Everyone who voted on the survey gets an email listing the dates, with a link to the site's **Pick a Meeting Date** page (`/bookclub/s/meeting`).

1. On the site's **Pick a Meeting Date** page or tab, members tick every Sunday they can make (or none) and can change their answer until the date is set. As with surveys, members don't see each other's answers.
2. In the Book Club Admin app, the **Schedule the Meeting** tab next to Results (admins only) shows how many members can make each date, with the most popular date pre-selected (ties go to the earliest). Click **Schedule & email members**.
3. Everyone who voted on the survey or answered the date poll is emailed the date, and the site's Meeting page shows it.

You can also schedule from the **Book Club Meetings** tab: set Status to **Scheduled**, with or without a **Meeting Date** (if it's blank, the most popular date is filled in). Changing the Meeting Date afterwards emails members the new date. The four dates are records in the meeting's **Date Options** related list, so you can change one (for a holiday, say) before members answer.

### Running a survey

1. **Titles** tab: add suggestions (and historic titles you've already read, with their score and dates).
2. **Book Club Surveys** tab → **New** opens the survey builder: a list of every Suggested title. Check 2–5 of them, then click **Create & Publish**, or **Save as Draft** to publish later by setting Status to **Published**. The survey is named `Next Read - MM/dd/yyyy` (today's date) on save; you can rename it afterwards.
3. Once published, **Published On** is stamped with today's date (read-only) and the survey's titles are locked. **Closed On** is stamped the same way when it closes. While a survey is still Draft, you can change its titles in the **Survey Options** related list.
4. Members open the **Vote for Our Next Read** tab on the member site and rank every title, top choice first. They can change their ranking until the survey closes.
5. In the Book Club Admin app's **Results** tab (admins only), pick the survey and review the points (a title earns more the higher it's ranked; ties go to the most first-choice votes). Confirm the winner and close. The winning title becomes **Selected** with **Decided On** = today; the others stay Suggested for future surveys.
   You can also close by setting the survey's Status to **Closed** in the standard UI. If **Selected Title** is blank, the leader is filled in automatically. If no one has responded, or the vote is still tied, the save asks you to pick the Selected Title yourself.
   However it closes, closing creates the meeting and emails everyone who voted (see below).
6. Schedule the meeting (below).
7. After the club reviews it, set the title to **Reviewed**. **Reviewed On** is required for that status; also fill in **Overall Score** (1–5).
