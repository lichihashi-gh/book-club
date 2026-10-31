import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTitles from '@salesforce/apex/BookClubReviewController.getTitles';
import getReviews from '@salesforce/apex/BookClubReviewController.getReviews';
import saveReview from '@salesforce/apex/BookClubReviewController.saveReview';
import suggestTitle from '@salesforce/apex/BookClubReviewController.suggestTitle';
import getOpenLibraryRating from '@salesforce/apex/BookClubReviewController.getOpenLibraryRating';
import { reduceErrors } from 'c/bookClubUtils';

const MAX_STARS = 5;
const RATING_WORDS = ['Not for me', 'It was okay', 'Liked it', 'Really liked it', 'Loved it!'];
const TYPE_OPTIONS = ['Book', 'Movie', 'Periodical', 'Other'].map((type) => ({ label: type, value: type }));
const EMPTY_SUGGESTION = { name: '', author: '', titleType: 'Book', notes: '' };

function stars(count) {
    const filled = Math.max(0, Math.min(MAX_STARS, Math.round(count ?? 0)));
    return '★'.repeat(filled) + '☆'.repeat(MAX_STARS - filled);
}

// "The Bookshelf": members browse every title, suggest new ones, rate any title
// 1–5 stars with a comment (one review each, editable), and read everyone's reviews.
export default class TitleReviews extends LightningElement {
    typeOptions = TYPE_OPTIONS;
    suggesting = false;
    suggestSaving = false;
    suggestion = { ...EMPTY_SUGGESTION };
    titles = [];
    openLibraryRating;
    loadingOpenLibrary = false;
    coverFailed = false;
    searchTerm = '';
    selectedId;
    reviews = [];
    draftRating = 0;
    draftComment = '';
    error;
    loaded = false;
    loadingReviews = false;
    saving = false;

    connectedCallback() {
        this.loadTitles();
    }

    async loadTitles() {
        try {
            this.titles = await getTitles();
            this.error = undefined;
        } catch (error) {
            this.error = reduceErrors(error);
        } finally {
            this.loaded = true;
        }
    }

    async loadReviews() {
        this.loadingReviews = true;
        try {
            this.reviews = await getReviews({ titleId: this.selectedId });
            const mine = this.reviews.find((review) => review.isMine);
            this.draftRating = mine?.rating ?? 0;
            this.draftComment = mine?.comment ?? '';
        } catch (error) {
            this.toast('Could not load reviews', reduceErrors(error), 'error');
        } finally {
            this.loadingReviews = false;
        }
    }

    // Open Library only covers books.
    async loadOpenLibrary() {
        const titleId = this.selectedId;
        this.openLibraryRating = undefined;
        this.coverFailed = false;
        if (!this.showOpenLibrary) {
            return;
        }
        this.loadingOpenLibrary = true;
        try {
            const rating = await getOpenLibraryRating({ titleId });
            if (titleId === this.selectedId) {
                this.openLibraryRating = rating;
            }
        } catch (error) {
            if (titleId === this.selectedId) {
                this.openLibraryRating = { found: false, unavailable: true };
            }
        } finally {
            if (titleId === this.selectedId) {
                this.loadingOpenLibrary = false;
            }
        }
    }

    get showOpenLibrary() {
        return this.selected?.titleType === 'Book';
    }

    get openLibrary() {
        const rating = this.openLibraryRating;
        if (!rating) {
            return null;
        }
        const count = rating.ratingCount ?? 0;
        const countLabel = `${count.toLocaleString()} rating${count === 1 ? '' : 's'} on Open Library`;
        const average = rating.rating == null ? null : Number(rating.rating).toFixed(1);
        return {
            ...rating,
            hasRating: rating.found && average !== null && count > 0,
            average,
            stars: stars(rating.rating),
            countLabel,
            label: `Open Library readers: ${average} out of 5 stars from ${countLabel}`,
            showCover: Boolean(rating.coverUrl) && !this.coverFailed
        };
    }

    handleCoverError() {
        this.coverFailed = true;
    }

    get filteredTitles() {
        const term = this.searchTerm.trim().toLowerCase();
        return this.titles
            .filter((title) => !term || `${title.name} ${title.author ?? ''}`.toLowerCase().includes(term))
            .map((title) => ({
                ...title,
                isSelected: title.id === this.selectedId,
                buttonClass: title.id === this.selectedId ? 'title-button title-button_selected' : 'title-button',
                averageStars: stars(title.averageRating),
                averageLabel: title.reviewCount
                    ? `Average ${title.averageRating} out of 5 stars from ${title.reviewCount} review${title.reviewCount === 1 ? '' : 's'}`
                    : 'No reviews yet',
                hasReviews: title.reviewCount > 0,
                statusClass: `status status_${(title.status ?? '').toLowerCase()}`,
                myStars: title.myRating ? stars(title.myRating) : null
            }));
    }

    get hasFilteredTitles() {
        return this.filteredTitles.length > 0;
    }

    get selected() {
        return this.filteredTitles.find((title) => title.isSelected) ?? this.titles.find((title) => title.id === this.selectedId);
    }

    // Members' average and a 5★–1★ breakdown, from the loaded reviews.
    get scoreSummary() {
        const count = this.reviews.length;
        if (!count) {
            return null;
        }
        const average = Math.round((this.reviews.reduce((sum, review) => sum + review.rating, 0) / count) * 10) / 10;
        const countLabel = `${count} review${count === 1 ? '' : 's'}`;
        return {
            average: average.toFixed(1),
            stars: stars(average),
            countLabel,
            label: `Members' average: ${average} out of 5 stars from ${countLabel}`,
            bars: [5, 4, 3, 2, 1].map((star) => {
                const matching = this.reviews.filter((review) => review.rating === star).length;
                return {
                    key: `bar${star}`,
                    label: `${star} ★`,
                    count: matching,
                    style: `width: ${Math.round((matching / count) * 100)}%;`,
                    srLabel: `${star} star${star === 1 ? '' : 's'}: ${matching}`
                };
            })
        };
    }

    // The admin's Overall Score on the Title, when set.
    get clubScore() {
        const score = this.selected?.clubScore;
        return score == null ? null : { value: Number(score).toFixed(1), stars: stars(score) };
    }

    get showScores() {
        return !this.loadingReviews && (this.scoreSummary || this.clubScore);
    }

    get starChoices() {
        return Array.from({ length: MAX_STARS }, (_, i) => {
            const value = i + 1;
            return {
                value: String(value),
                id: `star-${value}`,
                checked: value === this.draftRating,
                labelClass: value <= this.draftRating ? 'star star_filled' : 'star',
                label: `${value} star${value === 1 ? '' : 's'}: ${RATING_WORDS[i]}`
            };
        });
    }

    get ratingCaption() {
        return this.draftRating ? RATING_WORDS[this.draftRating - 1] : 'Choose 1 to 5 stars';
    }

    get hasMyReview() {
        return this.reviews.some((review) => review.isMine);
    }

    get reviewHeading() {
        return this.hasMyReview ? 'Your review' : 'Write your review';
    }

    get saveLabel() {
        return this.hasMyReview ? 'Update my review' : 'Post my review';
    }

    get cannotSave() {
        return this.saving || this.draftRating < 1;
    }

    get reviewRows() {
        return this.reviews.map((review) => ({
            ...review,
            stars: stars(review.rating),
            starsLabel: `${review.rating} out of 5 stars`,
            articleClass: review.isMine ? 'review review_mine' : 'review'
        }));
    }

    get hasReviews() {
        return this.reviews.length > 0;
    }

    handleStartSuggest() {
        this.suggestion = { ...EMPTY_SUGGESTION };
        this.suggesting = true;
    }

    handleCancelSuggest() {
        this.suggesting = false;
    }

    handleSuggestionChange(event) {
        this.suggestion = { ...this.suggestion, [event.target.name]: event.detail.value };
    }

    async handleSuggest() {
        if (!this.template.querySelector('[data-id="suggest-name"]').reportValidity()) {
            return;
        }
        this.suggestSaving = true;
        try {
            const titleId = await suggestTitle({ ...this.suggestion });
            this.toast('Added to the bookshelf', `"${this.suggestion.name.trim()}" is now a suggestion for a future survey.`, 'success');
            this.suggesting = false;
            this.searchTerm = '';
            await this.loadTitles();
            this.selectedId = titleId;
            this.reviews = [];
            this.loadReviews();
            this.loadOpenLibrary();
        } catch (error) {
            this.toast('Could not add the title', reduceErrors(error), 'error');
        } finally {
            this.suggestSaving = false;
        }
    }

    handleSearch(event) {
        this.searchTerm = event.target.value ?? '';
    }

    handleSelect(event) {
        this.selectedId = event.currentTarget.dataset.id;
        this.reviews = [];
        this.loadReviews();
        this.loadOpenLibrary();
    }

    handleRating(event) {
        this.draftRating = Number(event.target.value);
    }

    handleComment(event) {
        this.draftComment = event.target.value;
    }

    async handleSave() {
        this.saving = true;
        const wasUpdate = this.hasMyReview;
        try {
            await saveReview({ titleId: this.selectedId, rating: this.draftRating, comment: this.draftComment });
            this.toast(wasUpdate ? 'Review updated' : 'Review posted', 'Thanks for sharing your thoughts.', 'success');
            await Promise.all([this.loadTitles(), this.loadReviews()]);
        } catch (error) {
            this.toast('Could not save your review', reduceErrors(error), 'error');
        } finally {
            this.saving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
