import { LightningElement, api, track } from 'lwc';
import searchRoles from '@salesforce/apex/PsQuoteController.searchRoles';

export default class PsRoleLookup extends LightningElement {
    @track inputValue = '';
    @track results = [];
    @track open = false;
    _timer;
    _searched = false;

    /** Allows the parent to seed the display (e.g. when a role is already chosen). */
    @api
    get selectedLabel() {
        return this.inputValue;
    }
    set selectedLabel(val) {
        if (val && !this.inputValue) {
            this.inputValue = val;
        }
    }

    get noResults() {
        return this.open && this._searched && this.results.length === 0;
    }

    handleFocus() {
        this.open = true;
        if (!this._searched) {
            this.search('');
        }
    }

    handleInput(e) {
        this.inputValue = e.target.value;
        this.open = true;
        window.clearTimeout(this._timer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setTimeout(() => this.search(this.inputValue), 250);
    }

    async search(term) {
        try {
            const stripped = (term || '').replace(/\s*\(\$.*$/, ''); // ignore the "($x/hr)" suffix
            this.results = await searchRoles({ term: stripped });
        } catch (e) {
            this.results = [];
        }
        this._searched = true;
    }

    handleSelect(e) {
        const id = e.currentTarget.dataset.id;
        const role = this.results.find((r) => r.productId === id);
        if (role) {
            this.inputValue = `${role.name} ($${role.rate}/hr)`;
            this.open = false;
            this.dispatchEvent(new CustomEvent('select', { detail: role }));
        }
    }

    handleBlur() {
        // delay so a click/mousedown on an option is processed before closing
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.setTimeout(() => { this.open = false; }, 200);
    }
}
