import { LightningElement, api } from 'lwc';

const MAX_RESULTS = 10;

/**
 * Type-ahead picker for a long list of certifications. Parent passes options ({label, value}) and the
 * selected value; the component fires `select` with { value } when the learner picks one.
 */
export default class CertSearchPicker extends LightningElement {
    @api label = 'Certification';
    @api placeholder = 'Type to search';
    @api options = [];

    query = '';
    open = false;
    _value = '';

    @api
    get value() { return this._value; }
    set value(v) {
        const next = v || '';
        if (next === this._value) return; // also true right after the learner starts typing over a choice
        this._value = next;
        if (!next) {
            this.query = ''; // the parent cleared the choice (for example after adding)
        } else {
            const o = (this.options || []).find((x) => x.value === next);
            if (o) this.query = o.label;
        }
    }

    get results() {
        const tokens = (this.query || '').toLowerCase().split(/\s+/).filter(Boolean);
        const all = this.options || [];
        const hits = tokens.length
            ? all.filter((o) => {
                  const hay = `${o.label} ${o.value}`.toLowerCase();
                  return tokens.every((t) => hay.includes(t));
              })
            : all;
        return hits.slice(0, MAX_RESULTS).map((o) => ({ ...o, selected: o.value === this._value }));
    }
    get hasResults() { return this.results.length > 0; }
    get showList() { return this.open; }
    get moreNote() {
        const tokens = (this.query || '').toLowerCase().split(/\s+/).filter(Boolean);
        const total = tokens.length
            ? (this.options || []).filter((o) => tokens.every((t) => `${o.label} ${o.value}`.toLowerCase().includes(t))).length
            : (this.options || []).length;
        return total > MAX_RESULTS ? `Showing ${MAX_RESULTS} of ${total}. Keep typing to narrow the list.` : '';
    }
    get hasMoreNote() { return this.moreNote !== ''; }

    handleInput(event) {
        this.query = event.target.value;
        this.open = true;
        if (this._value) {
            this._value = '';
            this.dispatchEvent(new CustomEvent('select', { detail: { value: '' } }));
        }
    }

    handleFocus() { this.open = true; }

    handleBlur() {
        // Delay so a click on a result registers before the list closes.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.open = false; }, 150);
    }

    handlePick(event) {
        const v = event.currentTarget.dataset.value;
        const o = (this.options || []).find((x) => x.value === v);
        this._value = v;
        this.query = o ? o.label : '';
        this.open = false;
        this.dispatchEvent(new CustomEvent('select', { detail: { value: v } }));
    }
}
