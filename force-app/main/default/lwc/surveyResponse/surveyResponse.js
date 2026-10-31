import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSurvey from '@salesforce/apex/BookClubSurveyController.getSurvey';
import submitRanking from '@salesforce/apex/BookClubSurveyController.submitRanking';
import { reduceErrors } from 'c/bookClubUtils';

export default class SurveyResponse extends LightningElement {
    @api surveyId;

    survey;
    ranked = [];
    error;
    saving = false;
    wiredSurvey;
    refreshedOnce = false;

    @wire(getSurvey, { surveyId: '$surveyId' })
    handleSurvey(result) {
        this.wiredSurvey = result;
        const { data, error } = result;
        if (data) {
            this.survey = data;
            this.ranked = data.options.map((option) => ({ ...option }));
            this.error = undefined;
        } else if (error) {
            this.error = reduceErrors(error);
        }
        // Tabs re-create this component, so fetch fresh data once per instance
        // in case the survey was closed or re-voted elsewhere.
        if (!this.refreshedOnce && (data || error)) {
            this.refreshedOnce = true;
            refreshApex(this.wiredSurvey);
        }
    }

    get isOpen() {
        return this.survey?.status === 'Published';
    }

    get isClosed() {
        return this.survey?.status === 'Closed';
    }

    get submitLabel() {
        return this.survey?.hasVoted ? 'Update my ranking' : 'Submit my ranking';
    }

    get rows() {
        const last = this.ranked.length - 1;
        return this.ranked.map((option, index) => ({
            ...option,
            index,
            position: index + 1,
            isFirst: index === 0,
            isLast: index === last,
            upLabel: `Move ${option.titleName} up`,
            downLabel: `Move ${option.titleName} down`,
            topLabel: `Move ${option.titleName} to the top`,
            bottomLabel: `Move ${option.titleName} to the bottom`
        }));
    }

    moveUp(event) {
        this.swap(Number(event.currentTarget.dataset.index), -1);
    }

    moveDown(event) {
        this.swap(Number(event.currentTarget.dataset.index), 1);
    }

    moveToTop(event) {
        this.moveTo(Number(event.currentTarget.dataset.index), 0);
    }

    moveToBottom(event) {
        this.moveTo(Number(event.currentTarget.dataset.index), this.ranked.length - 1);
    }

    // Takes the title out and puts it back at target; the others shift to make room.
    moveTo(index, target) {
        if (index === target) {
            return;
        }
        const next = [...this.ranked];
        const [moved] = next.splice(index, 1);
        next.splice(target, 0, moved);
        this.ranked = next;
    }

    swap(index, offset) {
        const target = index + offset;
        if (target < 0 || target >= this.ranked.length) {
            return;
        }
        const next = [...this.ranked];
        [next[index], next[target]] = [next[target], next[index]];
        this.ranked = next;
    }

    async handleSubmit() {
        this.saving = true;
        try {
            await submitRanking({
                surveyId: this.surveyId,
                optionIdsInRankOrder: this.ranked.map((option) => option.id)
            });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Ranking saved', message: 'Thanks for voting!', variant: 'success' })
            );
            await refreshApex(this.wiredSurvey);
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not save your ranking', message: reduceErrors(error), variant: 'error' })
            );
        } finally {
            this.saving = false;
        }
    }
}
