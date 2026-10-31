import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getMeetings from '@salesforce/apex/BookClubMeetingController.getMeetings';
import getMeeting from '@salesforce/apex/BookClubMeetingController.getMeeting';
import submitAvailability from '@salesforce/apex/BookClubMeetingController.submitAvailability';
import scheduleMeeting from '@salesforce/apex/BookClubMeetingController.scheduleMeeting';
import { reduceErrors } from 'c/bookClubUtils';

// Apex Dates arrive as "yyyy-mm-dd". Build a local date so the day doesn't
// shift in time zones west of UTC.
function toLocalDate(isoDate) {
    const [year, month, day] = isoDate.split('-').map(Number);
    return new Date(year, month - 1, day);
}

function formatDate(isoDate, options) {
    return isoDate ? toLocalDate(isoDate).toLocaleDateString(undefined, options) : '';
}

const LONG_DATE = { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' };

// The meeting for the club's latest pick: members tick the suggested Sundays
// they can make, and the admin schedules it (members are emailed the date).
export default class MeetingPoll extends LightningElement {
    meetings = [];
    isAdmin = false;
    isSite = false;
    pickedMeetingId;
    meeting;
    pickedDateIds = [];
    scheduleDate;
    error;
    loaded = false;
    saving = false;
    scheduling = false;

    connectedCallback() {
        this.loadMeetings();
    }

    async loadMeetings() {
        try {
            const data = await getMeetings();
            this.meetings = data.meetings;
            this.isAdmin = data.isAdmin;
            this.isSite = data.isSite;
            await this.loadMeeting();
            this.error = undefined;
        } catch (error) {
            this.error = reduceErrors(error);
        } finally {
            this.loaded = true;
        }
    }

    async loadMeeting() {
        const meetingId = this.meetingId;
        if (!meetingId) {
            this.meeting = undefined;
            return;
        }
        const view = await getMeeting({ meetingId });
        if (meetingId !== this.meetingId) {
            return;
        }
        this.meeting = view;
        this.pickedDateIds = view.options.filter((option) => option.available).map((option) => option.id);
        this.scheduleDate = view.suggestedDate ?? view.options[0]?.optionDate;
    }

    get meetingId() {
        // Meetings still voting come first, newest first.
        return this.pickedMeetingId ?? this.meetings[0]?.id;
    }

    get showPicker() {
        return this.meetings.length > 1;
    }

    get meetingOptions() {
        return this.meetings.map((meeting) => ({ label: `${meeting.name} (${meeting.status})`, value: meeting.id }));
    }

    get isVoting() {
        return this.meeting?.status === 'Voting';
    }

    get isScheduled() {
        return this.meeting?.status === 'Scheduled';
    }

    get canRespond() {
        return this.isVoting && this.isSite;
    }

    get canSchedule() {
        return this.isVoting && this.isAdmin && this.meeting.showTally;
    }

    get scheduledDateLabel() {
        return formatDate(this.meeting.meetingDate, LONG_DATE);
    }

    get dateChoices() {
        return this.meeting.options.map((option) => {
            const checked = this.pickedDateIds.includes(option.id);
            return {
                id: option.id,
                checked,
                weekday: formatDate(option.optionDate, { weekday: 'long' }),
                day: formatDate(option.optionDate, { month: 'long', day: 'numeric', year: 'numeric' }),
                cardClass: checked ? 'date-card date-card_checked' : 'date-card'
            };
        });
    }

    get pickedSummary() {
        const picked = this.pickedDateIds.length;
        const total = this.meeting.options.length;
        if (picked === 0) {
            return 'None of these dates work for me.';
        }
        return picked === total ? 'Any of these dates work for me.' : `I can make ${picked} of the ${total} dates.`;
    }

    get submitLabel() {
        return this.meeting.hasResponded ? 'Update my answer' : 'Send my answer';
    }

    get responseSummary() {
        const count = this.meeting.responseCount ?? 0;
        return count === 0
            ? 'No one has answered yet. Members were emailed a link when the survey closed.'
            : `${count} member${count === 1 ? ' has' : 's have'} answered.`;
    }

    get tallyRows() {
        const responses = this.meeting.responseCount || 0;
        return this.meeting.options.map((option) => ({
            id: option.id,
            label: formatDate(option.optionDate, { weekday: 'short', month: 'short', day: 'numeric' }),
            countLabel: `${option.availableCount} of ${responses}`,
            barStyle: `width: ${responses ? Math.round((option.availableCount / responses) * 100) : 0}%;`,
            rowClass: option.isLeader ? 'tally-row tally-row_leader' : 'tally-row'
        }));
    }

    get scheduleOptions() {
        return this.meeting.options.map((option) => ({
            label: `${formatDate(option.optionDate, LONG_DATE)} (${option.availableCount} can make it)`,
            value: option.optionDate
        }));
    }

    handleMeetingChange(event) {
        this.pickedMeetingId = event.detail.value;
        this.loadMeeting().catch((error) => {
            this.error = reduceErrors(error);
        });
    }

    handleToggle(event) {
        const { id } = event.target.dataset;
        this.pickedDateIds = event.target.checked
            ? [...this.pickedDateIds, id]
            : this.pickedDateIds.filter((picked) => picked !== id);
    }

    async handleSubmit() {
        this.saving = true;
        try {
            await submitAvailability({ meetingId: this.meetingId, optionIds: this.pickedDateIds });
            this.toast('Thanks!', "We'll email you once the date is set.", 'success');
            await this.loadMeeting();
        } catch (error) {
            this.toast('Could not save your answer', reduceErrors(error), 'error');
        } finally {
            this.saving = false;
        }
    }

    handleScheduleChange(event) {
        this.scheduleDate = event.detail.value;
    }

    async handleSchedule() {
        const label = formatDate(this.scheduleDate, LONG_DATE);
        const confirmed = await LightningConfirm.open({
            label: 'Schedule the meeting',
            message: `Meet on ${label}? Everyone who voted will be emailed the date, and members can't change their answers after this.`,
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.scheduling = true;
        try {
            await scheduleMeeting({ meetingId: this.meetingId, meetingDate: this.scheduleDate });
            this.toast('Meeting scheduled', `Members have been emailed: we meet on ${label}.`, 'success');
            await this.loadMeetings();
        } catch (error) {
            this.toast('Could not schedule the meeting', reduceErrors(error), 'error');
        } finally {
            this.scheduling = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
