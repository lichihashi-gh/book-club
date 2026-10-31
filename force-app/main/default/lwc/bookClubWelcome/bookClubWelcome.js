import { LightningElement, api } from 'lwc';

// Public-domain lines; one is shown per day.
const QUOTES = [
    { text: 'I declare after all there is no enjoyment like reading!', author: 'Jane Austen', work: 'Pride and Prejudice' },
    { text: 'There is no Frigate like a Book / To take us Lands away.', author: 'Emily Dickinson', work: 'Poem 1263' },
    { text: 'I\'m not afraid of storms, for I\'m learning how to sail my ship.', author: 'Louisa May Alcott', work: 'Little Women' },
    { text: 'Reader, I married him.', author: 'Charlotte Brontë', work: 'Jane Eyre' },
    { text: 'Whatever our souls are made of, his and mine are the same.', author: 'Emily Brontë', work: 'Wuthering Heights' },
    { text: 'It was the best of times, it was the worst of times.', author: 'Charles Dickens', work: 'A Tale of Two Cities' },
    { text: 'Some books are to be tasted, others to be swallowed, and some few to be chewed and digested.', author: 'Francis Bacon', work: 'Of Studies' },
    { text: 'A woman must have money and a room of her own if she is to write fiction.', author: 'Virginia Woolf', work: 'A Room of One\'s Own' },
    { text: 'So we beat on, boats against the current, borne back ceaselessly into the past.', author: 'F. Scott Fitzgerald', work: 'The Great Gatsby' },
    { text: 'It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.', author: 'Jane Austen', work: 'Pride and Prejudice' },
    { text: 'Hope is the thing with feathers / That perches in the soul.', author: 'Emily Dickinson', work: 'Poem 254' },
    { text: 'Isn\'t it nice to think that tomorrow is a new day with no mistakes in it yet?', author: 'L. M. Montgomery', work: 'Anne of Green Gables' }
];

// Messages for one day only (YYYY-MM-DD), by the viewer's local date.
const SPECIAL_DAYS = {
    '2026-10-31': {
        heading: 'Happy Birthday, Amy!',
        message: 'Wishing you a year full of wonderful books, and a spooky-sweet Halloween birthday from all of us at the book club.'
    }
};

// Every year on this date (MM-DD) the autumn garland swaps its acorns for pumpkins.
const HALLOWEEN = '10-31';

// Leaf outlines, drawn from the stem outwards (0,0 sits on the stem).
const LEAF_OVAL = 'M0 0 C 5 -8, 17 -8, 22 0 C 17 8, 5 8, 0 0 Z';
const LEAF_MAPLE =
    'M0 0 L4 -3 L6 -10 L9 -5 L14 -12 L14 -4 L21 -6 L17 0 L21 6 L14 4 L14 12 L9 5 L6 10 L4 3 Z';
const LEAF_HOLLY = 'M0 0 L4 -5 L7 -2 L10 -7 L13 -2 L17 -6 L22 0 L17 6 L13 2 L10 7 L7 2 L4 5 Z';

// Northern-hemisphere seasons, by month (0 = January).
const SEASONS = {
    spring: {
        label: 'Spring',
        months: [2, 3, 4],
        accent: '#c0607d',
        stem: '#7d9471',
        leafPath: LEAF_OVAL,
        leafColors: ['#8fb07a', '#6f9a5b'],
        flower: { kind: 'petals', petals: 5, rx: 4.5, ry: 7, offset: 6, colors: ['#f6cdd8', '#eeb0c1'], center: '#f2c94c' },
        extra: 'bud',
        extraColors: ['#f0a8bb', '#d97c97']
    },
    summer: {
        label: 'Summer',
        months: [5, 6, 7],
        accent: '#b5536b',
        stem: '#7d9471',
        leafPath: LEAF_OVAL,
        leafColors: ['#7d9471', '#8fa883'],
        flower: { kind: 'rose', colors: ['#e8b4bc', '#d47f93', '#b5536b'], center: '#8e3b5a' },
        extra: 'bud',
        extraColors: ['#e8b4bc', '#b5536b']
    },
    autumn: {
        label: 'Autumn',
        months: [8, 9, 10],
        accent: '#b5481f',
        stem: '#7a5230',
        leafPath: LEAF_MAPLE,
        leafColors: ['#c8552b', '#e08a2e', '#b8862f', '#8c2f1c'],
        flower: { kind: 'petals', petals: 12, rx: 2.4, ry: 7, offset: 5, colors: ['#d9822b', '#e9a23b'], center: '#5a3a1a' },
        extra: 'acorn',
        extraColors: ['#a0703a', '#6b4a2a']
    },
    winter: {
        label: 'Winter',
        months: [11, 0, 1],
        accent: '#9e2a35',
        stem: '#4f6b4a',
        leafPath: LEAF_HOLLY,
        leafColors: ['#2f5d3a', '#3f7a4a'],
        flower: { kind: 'petals', petals: 5, rx: 5, ry: 6.5, offset: 5.5, colors: ['#fbf8f2', '#efe7da'], center: '#d9b44a' },
        extra: 'berries',
        extraColors: ['#b3202f', '#d33a46']
    }
};

// Garland layout, in viewBox units (600 × 52).
const FLOWERS = [
    { x: 46, y: 28, scale: 0.75 },
    { x: 170, y: 24, scale: 0.9 },
    { x: 300, y: 28, scale: 1.05 },
    { x: 430, y: 24, scale: 0.9 },
    { x: 554, y: 28, scale: 0.75 }
];
const LEAVES = [
    { x: 80, y: 30, angle: 25 },
    { x: 118, y: 22, angle: -30 },
    { x: 214, y: 30, angle: 25 },
    { x: 250, y: 20, angle: -25 },
    { x: 340, y: 30, angle: 155 },
    { x: 386, y: 22, angle: -150 },
    { x: 470, y: 30, angle: 160 },
    { x: 508, y: 22, angle: -155 }
];
const EXTRAS = [
    { x: 100, y: 12 },
    { x: 236, y: 40 },
    { x: 364, y: 40 },
    { x: 498, y: 12 }
];

export default class BookClubWelcome extends LightningElement {
    // "auto" follows the calendar; set a season in Experience Builder to preview it.
    @api season = 'auto';

    get seasonKey() {
        if (SEASONS[this.season]) {
            return this.season;
        }
        const month = new Date().getMonth();
        return Object.keys(SEASONS).find((key) => SEASONS[key].months.includes(month));
    }

    get theme() {
        return SEASONS[this.seasonKey];
    }

    get todayKey() {
        const now = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    }

    get isHalloween() {
        return this.todayKey.endsWith(HALLOWEEN);
    }

    get specialDay() {
        return SPECIAL_DAYS[this.todayKey];
    }

    get bannerStyle() {
        return `--bc-accent: ${this.theme.accent};`;
    }

    get eyebrow() {
        const today = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'long', day: 'numeric' }).format(new Date());
        return `${this.isHalloween ? 'Happy Halloween' : this.theme.label} · ${today}`;
    }

    get stemColor() {
        return this.theme.stem;
    }

    get leaves() {
        const { leafPath, leafColors } = this.theme;
        return LEAVES.map((leaf, i) => ({
            key: `leaf${i}`,
            path: leafPath,
            fill: leafColors[i % leafColors.length],
            transform: `translate(${leaf.x} ${leaf.y}) rotate(${leaf.angle})`
        }));
    }

    get flowers() {
        const { flower } = this.theme;
        return FLOWERS.map((spot, i) => ({
            key: `flower${i}`,
            transform: `translate(${spot.x} ${spot.y}) scale(${spot.scale})`,
            isRose: flower.kind === 'rose',
            center: flower.center,
            rings: flower.kind === 'rose'
                ? flower.colors.map((fill, ring) => ({ key: `ring${ring}`, fill, r: 13 - ring * 4 }))
                : [],
            petals: flower.kind === 'petals'
                ? Array.from({ length: flower.petals }, (_, p) => ({
                    key: `petal${p}`,
                    rx: flower.rx,
                    ry: flower.ry,
                    cy: -flower.offset,
                    fill: flower.colors[p % flower.colors.length],
                    transform: `rotate(${(360 / flower.petals) * p})`
                }))
                : []
        }));
    }

    get extras() {
        const { extra, extraColors } = this.isHalloween ? { extra: 'pumpkin', extraColors: ['#e07b24', '#4f6b2a'] } : this.theme;
        return EXTRAS.map((spot, i) => ({
            key: `extra${i}`,
            transform: `translate(${spot.x} ${spot.y})`,
            isBud: extra === 'bud',
            isAcorn: extra === 'acorn',
            isBerries: extra === 'berries',
            isPumpkin: extra === 'pumpkin',
            primary: extraColors[0],
            secondary: extraColors[1]
        }));
    }

    get quote() {
        const now = new Date();
        const dayOfYear = Math.floor((now - new Date(now.getFullYear(), 0, 0)) / 86400000);
        return QUOTES[dayOfYear % QUOTES.length];
    }
}
