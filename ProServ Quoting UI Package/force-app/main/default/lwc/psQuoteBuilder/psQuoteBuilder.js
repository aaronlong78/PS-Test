import { LightningElement, track, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getQuoteEstimate from '@salesforce/apex/PsQuoteController.getQuoteEstimate';
import buildQuote from '@salesforce/apex/PsQuoteController.buildQuote';
import repriceQuote from '@salesforce/apex/PsQuoteController.repriceQuote';
import getRoleEconomics from '@salesforce/apex/PsQuoteController.getRoleEconomics';

let seq = 0;
const nid = (p) => `${p}${++seq}`;

export default class PsQuoteBuilder extends LightningElement {
    @api recordId;              // Quote Id when placed on the Quote record page

    @track quoteName = '';
    @track opportunityName;
    @track accountName;
    @track phases = [];
    @track rates = {};          // productId -> one global negotiated rate across all phases
    @track economics = {};      // productId -> { cost, listRate } (cost = hourly, from the cost book)
    costBookName;
    targetMargin = 40;
    targetEdited = false;

    quoteId;
    opportunityId;
    building = false;
    loaded = false;
    result;

    // ---- context -------------------------------------------------------------------
    // The component sits on the Quote record (recordId = Quote Id).
    connectedCallback() {
        if (this.recordId && !this.loaded) {
            this.quoteId = this.recordId;
            this.loadQuote(this.recordId);
        }
    }

    @wire(getRoleEconomics)
    wiredEconomics({ data, error }) {
        if (data) {
            const map = {};
            (data.roles || []).forEach((r) => {
                map[r.productId] = {
                    cost: r.cost == null ? null : Number(r.cost),
                    listRate: r.listRate == null ? null : Number(r.listRate)
                };
            });
            this.economics = map;
            this.costBookName = data.costBookName;
            if (!this.targetEdited && data.targetMargin != null) {
                this.targetMargin = Number(data.targetMargin);
            }
        } else if (error) {
            this.toastError(error);
        }
    }

    /** Load the quote's context (opportunity/account) and any saved estimate. */
    async loadQuote(quoteId) {
        try {
            const load = await getQuoteEstimate({ quoteId });
            this.quoteName = load.quoteName;
            this.opportunityId = load.opportunityId;
            this.opportunityName = load.opportunityName;
            this.accountName = load.accountName;

            const rates = {};
            const phases = (load.phases || []).map((p) => ({
                id: nid('ph'),
                name: p.name,
                startDate: p.startDate,
                weeks: p.weeks,
                resources: (p.resources || []).map((r) => {
                    if (r.productId && rates[r.productId] == null) {
                        rates[r.productId] = Number(r.rate) || 0;
                    }
                    return {
                        id: nid('r'),
                        productId: r.productId,
                        roleName: r.roleName,
                        pbeId: r.pbeId,
                        selected: false,
                        hours: (r.hours || []).map((h) => Number(h) || 0)
                    };
                }),
                bulkHours: '',
                bulkTarget: 'all'
            }));
            this.rates = rates;
            this.phases = phases.length ? phases : [this.makePhase()];
        } catch (e) {
            this.toastError(e);
            if (this.phases.length === 0) {
                this.phases = [this.makePhase()];
            }
        } finally {
            this.loaded = true;
        }
    }

    get hasContext() {
        return !!this.quoteId;
    }

    get noContext() {
        return !this.quoteId;
    }

    // ---- phase / resource / week mutations ------------------------------------------
    findPhase(e) { return this.phases.find((p) => p.id === e.target.dataset.phase); }
    commit() { this.phases = [...this.phases]; }

    makePhase() {
        const last = this.phases[this.phases.length - 1];
        const start = last ? this.addDays(last.startDate, last.weeks * 7) : this.todayISO();
        return {
            id: nid('ph'),
            name: `Phase ${this.phases.length + 1}`,
            startDate: start,
            weeks: 2,
            resources: [this.newResource(2)],
            bulkHours: '',
            bulkTarget: 'all'
        };
    }

    addPhase() {
        this.phases.push(this.makePhase());
        this.commit();
    }

    newResource(weeks) {
        return { id: nid('r'), productId: null, roleName: '', pbeId: null, selected: false, hours: new Array(weeks).fill(0) };
    }

    removePhase(e) {
        const id = e.target.dataset.phase;
        this.phases = this.phases.filter((p) => p.id !== id);
    }

    handlePhaseName(e) { this.findPhase(e).name = e.detail.value; this.commit(); }
    handlePhaseStart(e) { this.findPhase(e).startDate = e.detail.value; this.commit(); }

    addWeek(e) {
        const p = this.findPhase(e);
        p.weeks += 1;
        p.resources.forEach((r) => r.hours.push(0));
        this.commit();
    }

    removeWeek(e) {
        const p = this.findPhase(e);
        if (p.weeks > 1) {
            p.weeks -= 1;
            p.resources.forEach((r) => r.hours.pop());
            this.commit();
        }
    }

    addResource(e) {
        const p = this.findPhase(e);
        p.resources.push(this.newResource(p.weeks));
        this.commit();
    }

    removeResource(e) {
        const p = this.findPhase(e);
        p.resources = p.resources.filter((r) => r.id !== e.target.dataset.res);
        this.commit();
    }

    handleRoleSelect(e) {
        const p = this.phases.find((x) => x.id === e.target.dataset.phase);
        const r = p.resources.find((x) => x.id === e.target.dataset.res);
        const role = e.detail;
        r.productId = role.productId;
        r.roleName = role.name;
        r.pbeId = role.pbeId;
        // Seed the global rate for this role (from the rate card) if not already set.
        if (this.rates[role.productId] == null) {
            this.rates = { ...this.rates, [role.productId]: Number(role.rate) || 0 };
        }
        this.commit();
    }

    handleHours(e) {
        const p = this.findPhase(e);
        const r = p.resources.find((x) => x.id === e.target.dataset.res);
        const w = Number(e.target.dataset.week);
        r.hours[w] = Math.max(0, Number(e.target.value) || 0);
        this.commit();
    }

    // ---- global roles & rates -------------------------------------------------------
    /** Distinct roles used anywhere in the quote, each with its single negotiated rate. */
    get roleRates() {
        return this.profitability.rows;
    }

    get hasRoles() {
        return this.roleRates.length > 0;
    }

    handleTargetMargin(e) {
        const v = Number(e.target.value);
        this.targetMargin = Number.isFinite(v) ? Math.min(99, Math.max(0, v)) : 0;
        this.targetEdited = true;
    }

    // ---- profitability --------------------------------------------------------------
    /**
     * Per-role and total revenue / cost / margin from the negotiated rates, the cost book hourly
     * costs, and the estimated hours. Margin covers only roles that have a cost, so a missing cost
     * never reads as 100% margin.
     */
    get profitability() {
        const target = Number(this.targetMargin) || 0;
        const byRole = new Map();
        for (const p of this.phases) {
            for (const r of p.resources) {
                if (!r.productId) { continue; }
                let entry = byRole.get(r.productId);
                if (!entry) {
                    entry = { productId: r.productId, roleName: r.roleName, hours: 0 };
                    byRole.set(r.productId, entry);
                }
                entry.hours += r.hours.reduce((a, h) => a + (Number(h) || 0), 0);
            }
        }

        let revenue = 0;
        let costedRevenue = 0;
        let cost = 0;
        let listRevenue = 0;
        let anyCost = false;
        const missing = [];
        const rows = Array.from(byRole.values()).map((e) => {
            const rate = this.rates[e.productId] == null ? 0 : Number(this.rates[e.productId]);
            const econ = this.economics[e.productId] || {};
            const unitCost = econ.cost == null ? null : econ.cost;
            const listRate = econ.listRate == null ? null : econ.listRate;
            const rowRevenue = e.hours * rate;
            revenue += rowRevenue;
            listRevenue += e.hours * (listRate == null ? rate : listRate);
            let marginPct = null;
            let targetRate = null;
            if (unitCost == null) {
                missing.push(e.roleName || 'Unnamed role');
            } else {
                anyCost = true;
                costedRevenue += rowRevenue;
                cost += e.hours * unitCost;
                marginPct = rate > 0 ? ((rate - unitCost) / rate) * 100 : null;
                targetRate = target < 100 ? unitCost / (1 - target / 100) : null;
            }
            return {
                productId: e.productId,
                roleName: e.roleName,
                rate,
                hours: e.hours,
                listRateDisplay: listRate == null ? '—' : this.fmt(listRate),
                costDisplay: unitCost == null ? 'No cost' : this.fmt(unitCost),
                revenueDisplay: this.fmt(rowRevenue),
                rowCostDisplay: unitCost == null ? '—' : this.fmt(e.hours * unitCost),
                marginDisplay: this.pct(marginPct),
                marginClass: this.marginClass(marginPct, target),
                targetRateDisplay: targetRate == null ? '—' : this.fmt(Math.ceil(targetRate))
            };
        });

        const margin = anyCost ? costedRevenue - cost : null;
        const marginPct = anyCost && costedRevenue > 0 ? (margin / costedRevenue) * 100 : null;
        const discount = listRevenue - revenue;
        return {
            rows,
            revenueDisplay: this.fmt(revenue),
            costDisplay: anyCost ? this.fmt(cost) : '—',
            marginDisplay: anyCost ? this.fmt(margin) : '—',
            marginPctDisplay: this.pct(marginPct),
            marginClass: `kpi-value ${this.marginClass(marginPct, target)}`,
            badgeClass: this.marginClass(marginPct, target),
            hasDiscount: discount > 0.5,
            discountDisplay: this.fmt(discount),
            discountPctDisplay: listRevenue > 0 ? this.pct((discount / listRevenue) * 100) : '—',
            hasMissing: missing.length > 0,
            missingDisplay: missing.join(', ')
        };
    }

    get hasCostBook() {
        return !!this.costBookName;
    }

    marginClass(pct, target) {
        if (pct == null) { return 'margin margin-none'; }
        if (pct >= target) { return 'margin margin-good'; }
        if (pct >= target - 10) { return 'margin margin-warn'; }
        return 'margin margin-bad';
    }

    get resultMarginDisplay() {
        return this.result && this.result.marginPct != null ? this.pct(Number(this.result.marginPct)) : null;
    }

    handleRoleRate(e) {
        const pid = e.target.dataset.product;
        this.rates = { ...this.rates, [pid]: Math.max(0, Number(e.target.value) || 0) };
        this.commit();
    }

    // ---- bulk hours apply (per phase) -----------------------------------------------
    toggleResource(e) {
        const p = this.findPhase(e);
        const r = p.resources.find((x) => x.id === e.target.dataset.res);
        r.selected = e.target.checked;
        this.commit();
    }

    toggleSelectAll(e) {
        const p = this.findPhase(e);
        const v = e.target.checked;
        p.resources.forEach((r) => { r.selected = v; });
        this.commit();
    }

    handleBulkHours(e) {
        this.findPhase(e).bulkHours = e.detail ? e.detail.value : e.target.value;
    }

    handleBulkTarget(e) {
        this.findPhase(e).bulkTarget = e.detail.value;
        this.commit();
    }

    applyBulk(e) {
        const p = this.findPhase(e);
        const selected = p.resources.filter((r) => r.selected);
        if (selected.length === 0) {
            this.toast('No resources selected', 'Tick one or more resources to bulk-apply.', 'warning');
            return;
        }
        if (p.bulkHours === '' || p.bulkHours == null) {
            this.toast('Nothing to apply', 'Enter an hours value to apply.', 'warning');
            return;
        }
        const hrs = Math.max(0, Number(p.bulkHours) || 0);
        const target = p.bulkTarget || 'all';
        selected.forEach((r) => {
            if (target === 'all') {
                for (let w = 0; w < p.weeks; w++) { r.hours[w] = hrs; }
            } else {
                r.hours[Number(target)] = hrs;
            }
        });
        this.commit();
    }

    // ---- computed view model --------------------------------------------------------
    get phaseViews() {
        return this.phases.map((p, pi) => {
            const weekHeaders = [];
            for (let w = 0; w < p.weeks; w++) {
                const s = this.addDays(p.startDate, w * 7);
                const e = this.addDays(p.startDate, w * 7 + 6);
                weekHeaders.push({ key: `${p.id}-h${w}`, label: `W${w + 1}`, range: `${this.md(s)}–${this.md(e)}` });
            }
            const colHours = new Array(p.weeks).fill(0);
            const colCost = new Array(p.weeks).fill(0);
            const rows = p.resources.map((r) => {
                const rate = (r.productId && this.rates[r.productId] != null) ? this.rates[r.productId] : 0;
                let rowHours = 0;
                const cells = [];
                for (let w = 0; w < p.weeks; w++) {
                    const val = r.hours[w] == null ? 0 : r.hours[w];
                    cells.push({ key: `${r.id}-c${w}`, week: w, value: val });
                    const num = Number(val) || 0;
                    rowHours += num;
                    colHours[w] += num;
                    colCost[w] += num * rate;
                }
                return {
                    id: r.id,
                    roleName: r.roleName,
                    selected: r.selected,
                    rateDisplay: rate ? this.fmt(rate) : '—',
                    cells,
                    rowHours,
                    rowCostDisplay: this.fmt(rowHours * rate)
                };
            });
            const colTotals = weekHeaders.map((h, w) => ({
                key: `${p.id}-t${w}`,
                hours: colHours[w],
                costDisplay: this.fmt(colCost[w])
            }));
            const phaseHours = colHours.reduce((a, b) => a + b, 0);
            const phaseCost = colCost.reduce((a, b) => a + b, 0);
            const bulkOptions = [{ label: 'All weeks', value: 'all' }].concat(
                weekHeaders.map((h, w) => ({ label: `Week ${w + 1}`, value: String(w) }))
            );
            return {
                id: p.id,
                name: p.name,
                startDate: p.startDate,
                weeks: p.weeks,
                number: pi + 1,
                weekHeaders,
                rows,
                colTotals,
                phaseHours,
                phaseCostDisplay: this.fmt(phaseCost),
                _cost: phaseCost,
                bulkHours: p.bulkHours == null ? '' : p.bulkHours,
                bulkTarget: p.bulkTarget || 'all',
                bulkOptions,
                allSelected: p.resources.length > 0 && p.resources.every((r) => r.selected)
            };
        });
    }

    get grandTotalDisplay() {
        return this.fmt(this.phaseViews.reduce((a, p) => a + p._cost, 0));
    }

    get grandHours() {
        return this.phaseViews.reduce((a, p) => a + p.phaseHours, 0);
    }

    /** Pull latest phase fields from the DOM so an uncommitted edit still counts. */
    syncFromDom() {
        this.template.querySelectorAll('[data-role="phase-name"]').forEach((el) => {
            const p = this.phases.find((x) => x.id === el.dataset.phase);
            if (p && el.value != null) { p.name = el.value; }
        });
        this.template.querySelectorAll('[data-role="phase-start"]').forEach((el) => {
            const p = this.phases.find((x) => x.id === el.dataset.phase);
            if (p && el.value) { p.startDate = el.value; }
        });
    }

    // ---- generate -------------------------------------------------------------------
    async generate() {
        this.syncFromDom();
        if (!this.quoteId) {
            this.toast('No quote', 'Open this builder from a Quote record.', 'warning');
            return;
        }
        for (const p of this.phases) {
            for (const r of p.resources) {
                if (!r.productId || !r.pbeId) {
                    this.toast('Missing role', `Pick a role for every resource in "${p.name}".`, 'warning');
                    return;
                }
                const rate = this.rates[r.productId];
                if (!rate || Number(rate) <= 0) {
                    this.toast('Missing rate', `Set a rate for "${r.roleName || 'role'}" in Roles & Rates.`, 'warning');
                    return;
                }
            }
        }
        this.building = true;
        this.result = null;
        const request = {
            quoteId: this.quoteId,
            phases: this.phases.map((p) => ({
                name: p.name,
                startDate: p.startDate,
                weeks: p.weeks,
                resources: p.resources.map((r) => ({
                    productId: r.productId,
                    pbeId: r.pbeId,
                    rate: this.rates[r.productId] || 0,
                    hours: r.hours.map((h) => Number(h) || 0)
                }))
            }))
        };
        try {
            const res = await buildQuote({ payload: JSON.stringify(request) });
            // Separate call (new transaction) so the reprice callout doesn't follow build's DML.
            await repriceQuote({ quoteId: this.quoteId });
            this.result = res;
            const marginNote = res.marginPct != null ? ` Estimated margin ${this.pct(Number(res.marginPct))}.` : '';
            this.toast('Estimate saved', `${res.lineCount} resource line(s) at $0/mo with negotiated usage rates written to this quote; ${res.segmentCount} estimate rows saved.${marginNote}`, 'success');
        } catch (e) {
            this.toastError(e);
        } finally {
            this.building = false;
        }
    }

    openQuote() {
        if (this.quoteId) {
            window.open(`/${this.quoteId}`, '_blank');
        }
    }

    // ---- helpers --------------------------------------------------------------------
    addDays(iso, n) {
        const d = new Date(`${iso}T00:00:00`);
        d.setDate(d.getDate() + n);
        return d.toISOString().slice(0, 10);
    }

    todayISO() {
        return new Date().toISOString().slice(0, 10);
    }

    md(iso) {
        const [, m, d] = iso.split('-');
        return `${m}/${d}`;
    }

    fmt(n) {
        return `$${(Number(n) || 0).toLocaleString('en-US', { maximumFractionDigits: 0 })}`;
    }

    pct(n) {
        return n == null || !Number.isFinite(n) ? '—' : `${n.toFixed(1)}%`;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    toastError(e) {
        const message = (e && e.body && e.body.message) ? e.body.message : (e && e.message) ? e.message : 'Unexpected error';
        this.toast('Error', message, 'error');
    }
}
