import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getSuggestedTitles from '@salesforce/apex/BookClubSurveyController.getSuggestedTitles';
import createSurvey from '@salesforce/apex/BookClubSurveyController.createSurvey';
import getSurveyForEdit from '@salesforce/apex/BookClubSurveyController.getSurveyForEdit';
import updateSurvey from '@salesforce/apex/BookClubSurveyController.updateSurvey';
import unpublishSurvey from '@salesforce/apex/BookClubSurveyController.unpublishSurvey';
import { reduceErrors } from 'c/bookClubUtils';

const MAX_TITLES = 5;
const MIN_TITLES = 2;
const STATUS_DRAFT = 'Draft';
const STATUS_PUBLISHED = 'Published';

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

// Replaces the standard New and Edit pages for Book Club Surveys (through the
// bookClubNewSurvey and bookClubEditSurvey Aura wrappers). New: pick 2–5 Suggested
// titles and save as Draft or publish. Edit (recordId set): a Draft can change its
// titles and name and be published; a Published survey can be renamed or moved back
// to Draft (clearing any votes); a Closed survey can only be renamed.
export default class SurveyBuilder extends NavigationMixin(LightningElement) {
    // Set by bookClubEditSurvey when editing an existing survey.
    @api recordId;

    columns = COLUMNS;
    maxTitles = MAX_TITLES;
    titles = [];
    selectedIds = [];
    name = '';
    status;
    responseCount = 0;
    error;
    loaded = false;
    saving = false;

    async connectedCallback() {
        try {
            const suggested = await getSuggestedTitles();
            if (this.isEdit) {
                const survey = await getSurveyForEdit({ surveyId: this.recordId });
                this.name = survey.name;
                this.status = survey.status;
                this.responseCount = survey.responseCount;
                this.selectedIds = survey.titleIds;
                // The survey's own titles first, then other Suggested titles to swap in.
                const own = new Set(survey.titleIds);
                this.titles = [...survey.titles, ...suggested.filter((title) => !own.has(title.id))];
            } else {
                this.titles = suggested;
            }
        } catch (error) {
            this.error = reduceErrors(error);
        } finally {
            this.loaded = true;
        }
    }

    get isEdit() {
        return Boolean(this.recordId);
    }

    get cardTitle() {
        return this.isEdit ? 'Edit Book Club Survey' : 'New Book Club Survey';
    }

    get titlesLocked() {
        return this.isEdit && Boolean(this.status) && this.status !== STATUS_DRAFT;
    }

    get lockedTitles() {
        const picked = new Set(this.selectedIds);
        return this.titles.filter((title) => picked.has(title.id));
    }

    get canUnpublish() {
        return this.isEdit && this.status === STATUS_PUBLISHED;
    }

    get unpublishHint() {
        if (!this.responseCount) {
            return 'No one has voted yet.';
        }
        return `${this.responseCount} ${this.responseCount === 1 ? 'member has' : 'members have'} voted; moving back clears their votes.`;
    }

    get publishLabel() {
        return this.isEdit ? 'Save & Publish' : 'Create & Publish';
    }

    get hasTitles() {
        return this.titles.length > 0;
    }

    get selectionSummary() {
        return `${this.selectedIds.length} of ${MAX_TITLES} selected. Pick ${MIN_TITLES} to ${MAX_TITLES} titles.`;
    }

    get randomCount() {
        return Math.min(MAX_TITLES, this.titles.length);
    }

    get randomLabel() {
        return `Pick ${this.randomCount} at random`;
    }

    get cannotSave() {
        return this.saving || this.selectedIds.length < MIN_TITLES;
    }

    handleNameChange(event) {
        this.name = event.detail.value;
    }

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((row) => row.id);
    }

    // Replaces the current picks with random Suggested titles (Fisher–Yates shuffle).
    handlePickRandom() {
        const ids = this.titles.map((title) => title.id);
        for (let i = ids.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [ids[i], ids[j]] = [ids[j], ids[i]];
        }
        this.selectedIds = ids.slice(0, this.randomCount);
    }

    async handleUnpublish() {
        if (this.responseCount) {
            const votes = `${this.responseCount} ${this.responseCount === 1 ? 'vote' : 'votes'}`;
            const confirmed = await LightningConfirm.open({
                label: 'Move back to Draft?',
                message: `This clears ${votes} on this survey. Members will need to vote again after you republish it.`,
                theme: 'warning'
            });
            if (!confirmed) {
                return;
            }
        }
        this.saving = true;
        try {
            await unpublishSurvey({ surveyId: this.recordId });
            this.status = STATUS_DRAFT;
            this.responseCount = 0;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Survey moved back to Draft',
                    message: 'Change its titles, then save it or publish it again.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not move the survey back to Draft', message: reduceErrors(error), variant: 'error' })
            );
        } finally {
            this.saving = false;
        }
    }

    handleSaveDraft() {
        this.save(false);
    }

    handlePublish() {
        this.save(true);
    }

    handleCancel() {
        if (this.isEdit) {
            this.navigateToSurvey(this.recordId);
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Survey__c', actionName: 'home' }
        });
    }

    navigateToSurvey(surveyId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: surveyId, objectApiName: 'Survey__c', actionName: 'view' }
        });
    }

    async save(publish) {
        this.saving = true;
        try {
            let surveyId = this.recordId;
            if (this.isEdit) {
                await updateSurvey({ surveyId, name: this.name, titleIds: this.selectedIds, publish });
            } else {
                surveyId = await createSurvey({ titleIds: this.selectedIds, publish });
            }
            this.dispatchEvent(
                new ShowToastEvent({
                    title: this.toastTitle(publish),
                    message: this.toastMessage(publish),
                    variant: 'success'
                })
            );
            this.navigateToSurvey(surveyId);
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not save the survey', message: reduceErrors(error), variant: 'error' })
            );
        } finally {
            this.saving = false;
        }
    }

    toastTitle(publish) {
        if (publish) {
            return 'Survey published';
        }
        return this.isEdit ? 'Survey saved' : 'Draft survey saved';
    }

    toastMessage(publish) {
        if (publish) {
            return 'Members can vote on the site now.';
        }
        return this.titlesLocked ? 'Your changes are saved.' : 'Publish it when you\'re ready.';
    }
}
