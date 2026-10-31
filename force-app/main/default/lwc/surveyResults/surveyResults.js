import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getResults from '@salesforce/apex/BookClubSurveyController.getResults';
import closeSurvey from '@salesforce/apex/BookClubSurveyController.closeSurvey';
import { reduceErrors } from 'c/bookClubUtils';

export default class SurveyResults extends LightningElement {
    @api surveyId;
    @api isAdmin = false;

    results;
    winnerTitleId;
    error;
    closing = false;
    wiredResults;
    refreshedOnce = false;

    @wire(getResults, { surveyId: '$surveyId' })
    handleResults(result) {
        this.wiredResults = result;
        const { data, error } = result;
        if (data) {
            this.results = data;
            this.winnerTitleId = data.suggestedWinnerTitleId ?? data.options[0]?.titleId;
            this.error = undefined;
        } else if (error) {
            this.error = reduceErrors(error);
        }
        // Votes arrive from other members, so fetch fresh tallies once per instance.
        if (!this.refreshedOnce && (data || error)) {
            this.refreshedOnce = true;
            refreshApex(this.wiredResults);
        }
    }

    get rows() {
        return this.results.options.map((option, index) => ({
            ...option,
            place: index + 1,
            rowClass: option.isLeader ? 'slds-theme_success' : '',
            isSelected: option.titleId === this.results.selectedTitleId
        }));
    }

    get hasResponses() {
        return this.results?.responseCount > 0;
    }

    get canClose() {
        return this.isAdmin && this.results?.status === 'Published';
    }

    get winnerOptions() {
        return this.results.options.map((option) => ({ label: option.titleName, value: option.titleId }));
    }

    get winnerName() {
        return this.results.options.find((option) => option.titleId === this.winnerTitleId)?.titleName;
    }

    handleWinnerChange(event) {
        this.winnerTitleId = event.detail.value;
    }

    async handleClose() {
        const confirmed = await LightningConfirm.open({
            label: 'Confirm the winner',
            message: `Close this survey and select "${this.winnerName}"? Members won't be able to vote after this.`,
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.closing = true;
        try {
            await closeSurvey({ surveyId: this.surveyId, winningTitleId: this.winnerTitleId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Survey closed', message: `${this.winnerName} is the next pick.`, variant: 'success' })
            );
            await refreshApex(this.wiredResults);
            this.dispatchEvent(new CustomEvent('surveyclosed'));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not close the survey', message: reduceErrors(error), variant: 'error' })
            );
        } finally {
            this.closing = false;
        }
    }
}
