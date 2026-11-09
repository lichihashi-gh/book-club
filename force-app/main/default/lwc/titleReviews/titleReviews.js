import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTitles from '@salesforce/apex/BookClubReviewController.getTitles';
import getReviews from '@salesforce/apex/BookClubReviewController.getReviews';
import saveReview from '@salesforce/apex/BookClubReviewController.saveReview';
import suggestTitle from '@salesforce/apex/BookClubReviewController.suggestTitle';
import updateSuggestion from '@salesforce/apex/BookClubReviewController.updateSuggestion';
import checkOpenLibrary from '@salesforce/apex/BookClubReviewController.checkOpenLibrary';
import getOpenLibraryRating from '@salesforce/apex/BookClubReviewController.getOpenLibraryRating';
import { reduceErrors } from 'c/bookClubUtils';

const MAX_STARS = 5;
const RATING_WORDS = ['Not for me', 'It was okay', 'Liked it', 'Really liked it', 'Loved it!'];
const TYPE_OPTIONS = ['Book', 'Movie', 'Periodical', 'Other'].map((type) => ({ label: type, value: type }));
const EMPTY_SUGGESTION = { name: '', author: '', titleType: 'Book', notes: '' };

// Inline style for a row of stars (class "stars"): CSS fills them up to the rating, rounded to the nearest half star.
function stars(count) {
    const filled = Math.max(0, Math.min(MAX_STARS, Math.round((count ?? 0) * 2) / 2));
    return `--star-fill: ${(filled / MAX_STARS) * 100}%;`;
}

// 3.5 → "3½".
function starNumber(value) {
    const whole = Math.floor(value);
    return value > whole ? `${whole}½` : String(whole);
}

// 4 → "Really liked it"; 3.5 → "Between “Liked it” and “Really liked it”".
function ratingWords(value) {
    const whole = Math.floor(value);
    return value > whole ? `Between “${RATING_WORDS[whole - 1]}” and “${RATING_WORDS[whole]}”` : RATING_WORDS[whole - 1];
}

// "The Bookshelf": members browse every title, suggest new ones (and edit their own while Suggested), rate any title
// 1–5 stars, in half stars, with a comment (one review each, editable), and read everyone's reviews.
export default class TitleReviews extends LightningElement {
    typeOptions = TYPE_OPTIONS;
    suggesting = false;
    suggestSaving = false;
    suggestion = { ...EMPTY_SUGGESTION };
    // Set when Open Library can't find the book being suggested or edited (see openLibraryKnows).
    suggestCheck;
    editCheck;
    editing = false;
    editSaving = false;
    edit = { ...EMPTY_SUGGESTION };
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
        } catch {
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
                myStars: title.myRating ? stars(title.myRating) : null,
                myRatingLabel: title.myRating ? `Your rating: ${title.myRating} out of 5 stars` : null
            }));
    }

    get hasFilteredTitles() {
        return this.filteredTitles.length > 0;
    }

    get selected() {
        return this.filteredTitles.find((title) => title.isSelected) ?? this.titles.find((title) => title.id === this.selectedId);
    }

    // Members' average and a 5★–1★ breakdown, from the loaded reviews. Half stars count toward the row below
    // (3½ in the 3★ row).
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
                const matching = this.reviews.filter((review) => Math.floor(review.rating) === star).length;
                return {
                    key: `bar${star}`,
                    label: `${star} ★`,
                    count: matching,
                    style: `width: ${Math.round((matching / count) * 100)}%;`,
                    srLabel: `${star === MAX_STARS ? '5 stars' : `${star} or ${star}½ stars`}: ${matching}`
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

    // Five stars, each split into a left half (x½) and a right half (x), except the first star, which is whole
    // because the lowest rating is 1. Every half is its own radio button, so arrow keys step by half stars.
    get starChoices() {
        return Array.from({ length: MAX_STARS }, (_, i) => {
            const whole = i + 1;
            const values = whole === 1 ? [1] : [whole - 0.5, whole];
            let starClass = 'star';
            if (this.draftRating >= whole) {
                starClass = 'star star_filled';
            } else if (this.draftRating === whole - 0.5) {
                starClass = 'star star_half';
            }
            return {
                key: `star-${whole}`,
                starClass,
                halves: values.map((value) => {
                    let side = 'star-half_right';
                    if (values.length === 1) {
                        side = 'star-half_whole';
                    } else if (value < whole) {
                        side = 'star-half_left';
                    }
                    return {
                        id: `star-${value}`,
                        labelKey: `label-${value}`,
                        value: String(value),
                        checked: value === this.draftRating,
                        labelClass: `star-half ${side}`,
                        label: `${starNumber(value)} star${value === 1 ? '' : 's'}: ${ratingWords(value)}`
                    };
                })
            };
        });
    }

    get ratingCaption() {
        return this.draftRating ? `${starNumber(this.draftRating)} stars · ${ratingWords(this.draftRating)}` : 'Choose 1 to 5 stars (half stars too)';
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
        this.suggestCheck = undefined;
        this.suggesting = true;
    }

    handleCancelSuggest() {
        this.suggesting = false;
    }

    handleSuggestionChange(event) {
        this.suggestion = { ...this.suggestion, [event.target.name]: event.detail.value };
        this.suggestCheck = undefined;
    }

    // Books only: true when Open Library knows the title and author, or can't be reached.
    // Otherwise sets a warning (with Open Library's best guess when it has one) and returns
    // false, so the member can fix a typo or go ahead anyway.
    async openLibraryKnows(values) {
        if (values.titleType !== 'Book') {
            return { ok: true };
        }
        try {
            const match = await checkOpenLibrary({ name: values.name, author: values.author });
            if (match.found || match.unavailable) {
                return { ok: true };
            }
            const author = values.author?.trim();
            return { ok: false, check: { ...match, entered: `"${values.name.trim()}"${author ? ` by ${author}` : ''}` } };
        } catch {
            return { ok: true };
        }
    }

    async handleSuggest() {
        if (!this.template.querySelector('[data-id="suggest-name"]').reportValidity()) {
            return;
        }
        this.suggestSaving = true;
        const { ok, check } = await this.openLibraryKnows(this.suggestion);
        this.suggestCheck = check;
        if (!ok) {
            this.suggestSaving = false;
            return;
        }
        await this.saveSuggestion();
    }

    handleSuggestAnyway() {
        this.suggestSaving = true;
        this.saveSuggestion();
    }

    handleUseSuggestion() {
        this.suggestion = { ...this.suggestion, name: this.suggestCheck.title, author: this.suggestCheck.author ?? this.suggestion.author };
        this.suggestCheck = undefined;
    }

    async saveSuggestion() {
        try {
            const titleId = await suggestTitle({ ...this.suggestion });
            this.toast('Added to the bookshelf', `"${this.suggestion.name.trim()}" is now a suggestion for a future survey.`, 'success');
            this.suggesting = false;
            this.suggestCheck = undefined;
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

    handleStartEdit() {
        const { name, author, titleType, notes } = this.selected;
        this.edit = { name, author: author ?? '', titleType: titleType ?? 'Book', notes: notes ?? '' };
        this.editCheck = undefined;
        this.editing = true;
        Promise.resolve().then(() => this.template.querySelector('[data-id="edit-name"]')?.focus());
    }

    handleCancelEdit() {
        this.editing = false;
    }

    handleEditChange(event) {
        this.edit = { ...this.edit, [event.target.name]: event.detail.value };
        this.editCheck = undefined;
    }

    async handleSaveEdit() {
        if (!this.template.querySelector('[data-id="edit-name"]').reportValidity()) {
            return;
        }
        this.editSaving = true;
        // Only a new name, author or type is checked; fixing the notes on a book Open Library lacks shouldn't nag.
        const before = this.selected;
        const renamed =
            this.edit.name.trim() !== before.name ||
            (this.edit.author.trim() || null) !== (before.author ?? null) ||
            this.edit.titleType !== before.titleType;
        if (renamed) {
            const { ok, check } = await this.openLibraryKnows(this.edit);
            this.editCheck = check;
            if (!ok) {
                this.editSaving = false;
                return;
            }
        }
        await this.saveEdit();
    }

    handleSaveEditAnyway() {
        this.editSaving = true;
        this.saveEdit();
    }

    handleUseEditSuggestion() {
        this.edit = { ...this.edit, name: this.editCheck.title, author: this.editCheck.author ?? this.edit.author };
        this.editCheck = undefined;
    }

    async saveEdit() {
        try {
            await updateSuggestion({ titleId: this.selectedId, ...this.edit });
            this.toast('Suggestion updated', `Your changes to "${this.edit.name.trim()}" are saved.`, 'success');
            this.editing = false;
            this.editCheck = undefined;
            await this.loadTitles();
            this.loadOpenLibrary();
        } catch (error) {
            this.toast('Could not save your changes', reduceErrors(error), 'error');
        } finally {
            this.editSaving = false;
        }
    }

    handleSearch(event) {
        this.searchTerm = event.target.value ?? '';
    }

    handleSelect(event) {
        this.selectedId = event.currentTarget.dataset.id;
        this.editing = false;
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
