import { LightningElement, api } from 'lwc';
import { isHalloween } from 'c/bookClubUtils';

export default class BookClubLogo extends LightningElement {
    // "auto" shows the Halloween logo on October 31 only; set it in Experience Builder to preview either one.
    @api theme = 'auto';

    get showHalloween() {
        return this.theme === 'halloween' || (this.theme === 'auto' && isHalloween());
    }

    get plaqueClass() {
        return this.showHalloween ? 'plaque plaque_halloween' : 'plaque';
    }

    get subtitle() {
        return this.showHalloween ? 'Happy Halloween' : 'Where good books find their readers';
    }
}
