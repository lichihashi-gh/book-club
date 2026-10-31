import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSuggestedTitles from '@salesforce/apex/BookClubSurveyController.getSuggestedTitles';
import createSurvey from '@salesforce/apex/BookClubSurveyController.createSurvey';
import { reduceErrors } from 'c/bookClubUtils';

const MAX_TITLES = 5;
const MIN_TITLES = 2;

const COLUMNS = [
    { label: 'Title', fieldName: 'name', wrapText: true },
    { label: 'Author', fieldName: 'author' },
    { label: 'Type', fieldName: 'titleType', initialWidth: 120 },
    { label: 'Suggested By', fieldName: 'suggestedBy' },
    {
        label: 'Suggested On',
        fieldName: 'suggestedOn',
        type: 'date-local',
        typeAttributes: { month: '2-digit', day: '2-digit', year: 'numeric' },
        initialWidth: 140
    }
];

// Replaces the standard New page for Book Club Surveys: pick 2–5 Suggested
// titles and save the survey as Draft or publish it straight away.
export default class SurveyBuilder extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    maxTitles = MAX_TITLES;
    titles = [];
    selectedIds = [];
    error;
    loaded = false;
    saving = false;

    async connectedCallback() {
        try {
            this.titles = await getSuggestedTitles();
        } catch (error) {
            this.error = reduceErrors(error);
        } finally {
            this.loaded = true;
        }
    }

    get hasTitles() {
        return this.titles.length > 0;
    }

    get selectionSummary() {
        return `${this.selectedIds.length} of ${MAX_TITLES} selected. Pick ${MIN_TITLES} to ${MAX_TITLES} titles.`;
    }

    get cannotSave() {
        return this.saving || this.selectedIds.length < MIN_TITLES;
    }

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((row) => row.id);
    }

    handleSaveDraft() {
        this.save(false);
    }

    handlePublish() {
        this.save(true);
    }

    handleCancel() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Survey__c', actionName: 'home' }
        });
    }

    async save(publish) {
        this.saving = true;
        try {
            const surveyId = await createSurvey({ titleIds: this.selectedIds, publish });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: publish ? 'Survey published' : 'Draft survey saved',
                    message: publish ? 'Members can vote on the site now.' : 'Publish it when you\'re ready.',
                    variant: 'success'
                })
            );
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: surveyId, objectApiName: 'Survey__c', actionName: 'view' }
            });
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not save the survey', message: reduceErrors(error), variant: 'error' })
            );
        } finally {
            this.saving = false;
        }
    }
}
