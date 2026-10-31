import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getSurveys from '@salesforce/apex/BookClubSurveyController.getSurveys';
import { reduceErrors } from 'c/bookClubUtils';

const VOTE = {
    id: 'vote',
    label: 'Vote for Our Next Read',
    hint: 'Rank the books, favorite first',
    icon: 'utility:like'
};
const RESULTS = {
    id: 'results',
    label: 'Results',
    hint: 'See the points and confirm the winner',
    icon: 'utility:chart'
};
const PICK_DATE = {
    id: 'meeting',
    label: 'Pick a Meeting Date',
    hint: 'Tick the Sundays you can make',
    icon: 'utility:event'
};
const SCHEDULE = {
    id: 'meeting',
    label: 'Schedule the Meeting',
    hint: 'See who can come and set the date',
    icon: 'utility:event'
};
const BOOKSHELF = {
    id: 'bookshelf',
    label: 'The Bookshelf',
    hint: 'Browse, suggest and review books',
    icon: 'utility:knowledge_base'
};

export default class BookClubSurvey extends LightningElement {
    // Set when placed on a Book Club Survey record page.
    @api recordId;

    surveys = [];
    isAdmin = false;
    isSite = false;
    pickedSurveyId;
    activeTabId;
    error;
    loaded = false;
    wiredSurveys;

    @wire(getSurveys)
    handleSurveys(result) {
        this.wiredSurveys = result;
        const { data, error } = result;
        if (data) {
            this.surveys = data.surveys;
            this.isAdmin = data.isAdmin;
            this.isSite = data.isSite;
            this.error = undefined;
            this.loaded = true;
        } else if (error) {
            this.error = reduceErrors(error);
            this.loaded = true;
        }
    }

    get surveyId() {
        // Surveys come back Published first, newest first, so the default is the newest published one.
        return this.recordId ?? this.pickedSurveyId ?? this.surveys[0]?.id;
    }

    get showPicker() {
        return !this.recordId && this.surveys.length > 0;
    }

    get surveyOptions() {
        return this.surveys.map((survey) => ({
            label: `${survey.name} (${survey.status})`,
            value: survey.id
        }));
    }

    get tabs() {
        const tabs = [];
        if (this.isSite) {
            tabs.push(VOTE);
        }
        if (this.isAdmin) {
            tabs.push(RESULTS);
        }
        tabs.push(this.isAdmin ? SCHEDULE : PICK_DATE, BOOKSHELF);

        const activeId = tabs.some((tab) => tab.id === this.activeTabId) ? this.activeTabId : tabs[0].id;
        return tabs.map((tab) => {
            const selected = tab.id === activeId;
            return {
                ...tab,
                selected,
                ariaSelected: String(selected),
                tabIndex: selected ? '0' : '-1',
                tabId: `tab-${tab.id}`,
                panelId: `panel-${tab.id}`,
                className: `tab color_${tab.id}${selected ? ' tab_selected' : ''}`
            };
        });
    }

    get activeTab() {
        return this.tabs.find((tab) => tab.selected);
    }

    get panelClass() {
        return `panel color_${this.activeTab.id}`;
    }

    get showVote() {
        return this.activeTab.id === 'vote';
    }

    get showResults() {
        return this.activeTab.id === 'results';
    }

    get showMeeting() {
        return this.activeTab.id === 'meeting';
    }

    get showBookshelf() {
        return this.activeTab.id === 'bookshelf';
    }

    handleTabClick(event) {
        this.activeTabId = event.currentTarget.dataset.id;
    }

    // Arrow keys, Home and End move between tabs, as in a standard tab list.
    handleTabKeydown(event) {
        const ids = this.tabs.map((tab) => tab.id);
        const current = ids.indexOf(this.activeTab.id);
        const next = {
            ArrowRight: (current + 1) % ids.length,
            ArrowDown: (current + 1) % ids.length,
            ArrowLeft: (current - 1 + ids.length) % ids.length,
            ArrowUp: (current - 1 + ids.length) % ids.length,
            Home: 0,
            End: ids.length - 1
        }[event.key];
        if (next === undefined) {
            return;
        }
        event.preventDefault();
        this.activeTabId = ids[next];
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => this.template.querySelector(`[data-id="${ids[next]}"]`)?.focus());
    }

    handleSurveyChange(event) {
        this.pickedSurveyId = event.detail.value;
    }

    handleClosed() {
        refreshApex(this.wiredSurveys);
    }
}
