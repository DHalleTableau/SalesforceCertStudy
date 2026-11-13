import { LightningElement, track } from 'lwc';
import listCerts from '@salesforce/apex/CertStudyController.listCerts';
import getActiveSession from '@salesforce/apex/CertStudyController.getActiveSession';
import startPractice from '@salesforce/apex/CertStudyController.startPractice';
import nextQuestion from '@salesforce/apex/CertStudyController.nextQuestion';
import retryGeneration from '@salesforce/apex/CertStudyController.retryGeneration';
import getLastSelection from '@salesforce/apex/CertStudyController.getLastSelection';
import getFocusableCerts from '@salesforce/apex/CertStudyController.getFocusableCerts';
import getExamFocus from '@salesforce/apex/CertStudyController.getExamFocus';
import previewSectionScores from '@salesforce/apex/CertStudyController.previewSectionScores';
import saveSectionScores from '@salesforce/apex/CertStudyController.saveSectionScores';
import getGoals from '@salesforce/apex/CertStudyController.getGoals';
import saveGoal from '@salesforce/apex/CertStudyController.saveGoal';
import removeGoal from '@salesforce/apex/CertStudyController.removeGoal';
import recordGoalOutcome from '@salesforce/apex/CertStudyController.recordGoalOutcome';
import submitAnswer from '@salesforce/apex/CertStudyController.submitAnswer';
import getSummary from '@salesforce/apex/CertStudyController.getSummary';
import startTest from '@salesforce/apex/CertStudyController.startTest';
import submitTestAnswer from '@salesforce/apex/CertStudyController.submitTestAnswer';
import pauseTest from '@salesforce/apex/CertStudyController.pauseTest';
import resumeTest from '@salesforce/apex/CertStudyController.resumeTest';
import finishTest from '@salesforce/apex/CertStudyController.finishTest';
import getHistory from '@salesforce/apex/CertStudyController.getHistory';
import getSessionDetail from '@salesforce/apex/CertStudyController.getSessionDetail';
import getEarnedCerts from '@salesforce/apex/CertStudyController.getEarnedCerts';
import setCertEarned from '@salesforce/apex/CertStudyController.setCertEarned';
import reportQuestion from '@salesforce/apex/CertStudyController.reportQuestion';
import submitContribution from '@salesforce/apex/CertStudyController.submitContribution';
import LightningConfirm from 'lightning/confirm';
import { recommend } from './certRecommendations';
import { RELEASES, UPCOMING } from './releaseNotes';
import { ALL, certType, certArea, typeOptions as buildTypeOptions, areaOptions as buildAreaOptions } from './certCategories';

const POLL_MS = 4000;
const MAX_POLLS = 90; // ~6 minutes

// Shown in the banner/footer. Bump APP_VERSION and APP_RELEASED on each release.
const APP_VERSION = 'v0.14.0';
const APP_RELEASED = 'Nov 2026'; // set the exact date when v0.14.0 is published
const OWNER_NAME = 'Daniel Halle';
const OWNER_EMAIL = 'daniel.halle@salesforce.com';

export default class CertStudy extends LightningElement {
    appVersion = APP_VERSION;
    releasedOn = APP_RELEASED;
    ownerName = OWNER_NAME;
    ownerEmail = OWNER_EMAIL;
    ownerMailto = 'mailto:' + OWNER_EMAIL + '?subject=Cert%20Study%20feedback%20(' + APP_VERSION + ')';

    view = 'loading'; // loading | select | prereq | question | feedback | waiting | summary | paused | testResult
    mode = 'practice'; // practice | test (selection screen)
    timerChoice = 'open'; // open | strict
    minDifficulty = '1'; // practice only: '1'..'5'
    testResult;
    clockBase = 0; // elapsed seconds reported by the server
    clockReceivedAt = 0; // Date.now() when clockBase was received
    clockTick = 0; // bumps every second to refresh the timer display
    clockInterval;
    finishing = false;
    history;
    fromHistory = false;
    busy = false;
    error;

    // cert selection
    allCerts = [];
    filterText = '';
    @track selectedCodes = [];
    prereqAnswers = {};
    pending;

    // session
    session;
    question;
    @track selectedKeys = [];
    grade;
    summary;
    pollCount = 0;
    pollTimer;
    waitMessage; // server's plain-language reason the next question is not ready yet

    // ------------------------------------------------------------ lifecycle

    connectedCallback() {
        this.keyHandler = this.handleKey.bind(this);
        window.addEventListener('keydown', this.keyHandler);
        this.load();
    }

    disconnectedCallback() {
        window.removeEventListener('keydown', this.keyHandler);
        this.stopPolling();
        this.stopClock();
    }

    async load() {
        this.error = undefined;
        try {
            const v = await getActiveSession();
            if (v && v.hasActiveSession) {
                this.applySession(v);
            } else {
                await this.showSelect();
            }
        } catch (e) {
            this.fail(e);
        }
    }

    // ------------------------------------------------------- view switches

    get isLoading() { return this.view === 'loading'; }
    get isSelect() { return this.view === 'select'; }
    get isPrereq() { return this.view === 'prereq'; }
    get isQuestion() { return this.view === 'question'; }
    get isFeedback() { return this.view === 'feedback'; }
    get isWaiting() { return this.view === 'waiting'; }
    get isSummary() { return this.view === 'summary'; }
    get isPaused() { return this.view === 'paused'; }
    get isTestResult() { return this.view === 'testResult'; }
    get isHistory() { return this.view === 'history'; }
    get isRecs() { return this.view === 'recs'; }
    get isContribute() { return this.view === 'contribute'; }
    get isWhatsNew() { return this.view === 'whatsNew'; }

    whatsNewReturnView = 'select';

    get upcoming() { return UPCOMING.map((text, i) => ({ key: 'u' + i, text })); }
    get hasUpcoming() { return UPCOMING.length > 0; }

    get releases() {
        return RELEASES.map((r) => ({
            ...r,
            isCurrent: r.version === APP_VERSION,
            lines: r.items.map((text, i) => ({ key: r.version + i, text }))
        }));
    }

    showWhatsNew() {
        if (this.view === 'whatsNew') return;
        this.whatsNewReturnView = this.view;
        this.view = 'whatsNew';
    }

    closeWhatsNew() {
        const back = this.whatsNewReturnView;
        if (!back || back === 'select' || back === 'loading') this.returnToSelect();
        else this.view = back;
    }

    /**
     * Back to the picker from a side page (What's new, suggestions) without clearing the
     * learner's mode, certs and prerequisite answers. Falls back to a full reset if the
     * picker was never loaded.
     */
    returnToSelect() {
        if (this.allCerts.length) this.view = 'select';
        else this.showSelect();
    }
    get showHistoryButton() { return ['select', 'summary', 'testResult', 'recs'].includes(this.view) && !this.busy; }
    get showRecsButton() { return ['select', 'summary', 'testResult', 'history'].includes(this.view) && !this.busy; }
    get inSession() { return ['question', 'feedback', 'waiting', 'paused'].includes(this.view); }
    get inTest() { return this.inSession && this.session && this.session.isTest; }
    get inPractice() { return this.inSession && !(this.session && this.session.isTest); }
    get pollGaveUp() { return this.view === 'waiting' && this.pollCount >= MAX_POLLS; }

    async showSelect() {
        this.stopPolling();
        this.stopClock();
        this.fromHistory = false;
        if (!this.allCerts.length) {
            this.allCerts = await listCerts();
        }
        try {
            this.earnedCodes = await getEarnedCerts();
        } catch (e) {
            this.earnedCodes = []; // the picker still works without it
        }
        try {
            this.lastSelection = await getLastSelection();
        } catch (e) {
            this.lastSelection = undefined; // the picker still works without it
        }
        try {
            this.focusableCodes = await getFocusableCerts();
        } catch (e) {
            this.focusableCodes = []; // focus is simply unavailable
        }
        try {
            this.examFocus = await getExamFocus();
        } catch (e) {
            this.examFocus = [];
        }
        this.focusTouched = false;
        this.focusWeak = false;
        this.goalNotice = undefined;
        await this.refreshGoals();
        this.selectedCodes = [];
        this.prereqAnswers = {};
        this.pending = undefined;
        this.view = 'select';
    }

    // ----------------------------------------------------- cert selection

    get modeOptions() {
        return [
            { label: 'Practice — feedback and explanations after every answer (one or more certs)', value: 'practice' },
            { label: 'Test — a full mock exam for one cert, scored pass/fail at the end', value: 'test' }
        ];
    }

    get timerOptions() {
        return [
            { label: 'Open time — total time shown at the end', value: 'open' },
            { label: 'Strict timer — the test ends when the real exam time runs out', value: 'strict' }
        ];
    }

    get minDifficultyOptions() {
        return [
            { label: '1 — all difficulties (default)', value: '1' },
            { label: '2', value: '2' },
            { label: '3', value: '3' },
            { label: '4', value: '4' },
            { label: '5 — hardest only', value: '5' }
        ];
    }

    handleMinDifficulty(event) {
        this.minDifficulty = event.detail.value;
    }

    // Weak-area focus (Practice only): available for certs the learner has answered before.
    focusableCodes = [];
    focusWeak = false;

    // Exam results entered after a failed exam: focus is pre-ticked for those certs until the learner unticks it.
    examFocus = [];
    focusTouched = false;

    get canFocus() { return this.selectedCodes.some((c) => this.focusableCodes.includes(c)); }
    get cannotFocus() { return !this.canFocus; }
    get selectedExamFocus() { return this.examFocus.filter((x) => this.selectedCodes.includes(x.certCode)); }
    get hasSelectedExamFocus() { return this.selectedExamFocus.length > 0; }
    get focusChecked() {
        if (!this.canFocus) return false;
        return this.focusTouched ? this.focusWeak : this.focusWeak || this.hasSelectedExamFocus;
    }
    get examFocusNote() {
        if (!this.hasSelectedExamFocus || !this.focusChecked) return '';
        const parts = this.selectedExamFocus.map((x) =>
            x.recordedLabel ? `${x.certName} (exam results from ${x.recordedLabel})` : x.certName
        );
        return `Focusing on your exam results for ${parts.join(', ')}, until you pass. Untick the box to practice without it.`;
    }
    get hasExamFocusNote() { return this.examFocusNote !== ''; }
    get focusHelp() {
        return this.canFocus
            ? 'Asks more questions from the sections you have scored lowest in, based on your earlier practice and tests (or your exam results, if you entered them). Certs with no history are not affected.'
            : 'Available once you have answered questions for one of the selected certifications.';
    }
    get sessionFocusNote() {
        return this.inPractice && this.session && this.session.focusNote ? this.session.focusNote : '';
    }

    handleFocus(event) {
        this.focusWeak = event.target.checked;
        this.focusTouched = true;
    }

    get isPracticeMode() { return !this.isTestMode; }
    get isTestMode() { return this.mode === 'test'; }
    get startLabel() { return this.isTestMode ? 'Start test' : 'Start practice'; }
    get selectHelp() {
        return this.isTestMode
            ? 'Pick one certification. You get the same number of questions as the real exam, weighted by its sections, with no feedback until the end.'
            : "Pick one or more certifications to practice. Questions rotate between them, and you'll see whether you were right — and why — after every answer.";
    }

    handleMode(event) {
        this.mode = event.detail.value;
        if (this.isTestMode) {
            const keep = this.selectedCodes.find((c) => {
                const cert = this.allCerts.find((x) => x.code === c);
                return cert && !cert.isAggregate;
            });
            this.selectedCodes = keep ? [keep] : [];
        }
    }

    handleTimer(event) {
        this.timerChoice = event.detail.value;
    }

    hideRetiring = true; // hidden by default; the filter can be unticked
    typeFilter = ALL;
    areaFilter = ALL;
    typeFilterOptions = buildTypeOptions();
    areaFilterOptions = buildAreaOptions();

    handleHideRetiring(event) {
        this.hideRetiring = event.target.checked;
    }

    // Certs the learner says they have earned. Hidden by default; the filter can be unticked.
    earnedCodes = [];
    hideEarned = true;

    handleHideEarned(event) {
        this.hideEarned = event.target.checked;
    }

    get hideEarnedLabel() {
        const n = this.allCerts.filter((c) => this.earnedCodes.includes(c.code)).length;
        return n > 0 ? `Hide certs I've earned (${n})` : "Hide certs I've earned";
    }

    // ------------------------------------------------ upcoming exams (study goals)

    goals = [];
    snoozedGoalIds = []; // "Ask me later": hidden until the next visit
    goalNotice;          // one-time message after recording a result
    goalCertCode = '';
    goalDate = '';
    goalError;

    async refreshGoals() {
        try {
            this.goals = await getGoals();
        } catch (e) {
            this.goals = []; // the picker still works without goals
        }
    }

    get isGoals() { return this.view === 'goals'; }

    get currentGoals() { return this.goals.filter((g) => !g.overdue); }
    get overdueGoals() { return this.goals.filter((g) => g.overdue && !this.snoozedGoalIds.includes(g.id)); }
    get hasOverdue() { return this.overdueGoals.length > 0; }
    get hasCurrentGoals() { return this.currentGoals.length > 0; }
    get upcomingSelectLabel() { return `Select upcoming exams (${this.currentGoals.length})`; }

    get goalRows() {
        return this.goals.map((g) => {
            let whenText = 'No date set';
            if (g.daysLeft !== undefined && g.daysLeft !== null) {
                if (g.daysLeft < 0) whenText = 'Date passed';
                else if (g.daysLeft === 0) whenText = 'Today';
                else if (g.daysLeft === 1) whenText = 'Tomorrow';
                else whenText = `In ${g.daysLeft} days`;
            }
            return { ...g, whenText };
        });
    }
    get hasGoalRows() { return this.goals.length > 0; }

    /** Exams that can be added: real exams (not aggregates), not already earned, not already tracked. */
    get goalCertOptions() {
        const tracked = new Set(this.goals.map((g) => g.certCode));
        return this.allCerts
            .filter((c) => !c.isAggregate && !this.earnedCodes.includes(c.code) && !tracked.has(c.code))
            .sort((a, b) => a.name.localeCompare(b.name))
            .map((c) => ({ label: c.name, value: c.code }));
    }
    get cannotAddGoal() { return !this.goalCertCode || this.busy; }

    selectUpcoming() {
        const known = new Map(this.allCerts.map((c) => [c.code, c]));
        let codes = this.currentGoals.map((g) => g.certCode).filter((c) => known.has(c));
        if (this.isTestMode) codes = codes.slice(0, 1); // a test is one cert at a time
        this.selectedCodes = codes;
        this.prereqAnswers = {};
    }

    async showGoals() {
        this.goalError = undefined;
        this.goalNotice = undefined;
        if (!this.allCerts.length) {
            try { this.allCerts = await listCerts(); } catch (e) { /* options just stay empty */ }
        }
        this.view = 'goals';
    }

    closeGoals() { this.returnToSelect(); }

    handleGoalCert(event) { this.goalCertCode = event.detail.value; }
    handleGoalDate(event) { this.goalDate = event.detail.value; }

    async addGoal() {
        this.goalError = undefined;
        this.busy = true;
        try {
            this.goals = await saveGoal({ certCode: this.goalCertCode, examDate: this.goalDate || null });
            this.goalCertCode = '';
            this.goalDate = '';
        } catch (e) {
            this.goalError = this.messageOf(e);
        } finally {
            this.busy = false;
        }
    }

    async changeGoalDate(event) {
        this.goalError = undefined;
        try {
            this.goals = await saveGoal({ certCode: event.target.dataset.code, examDate: event.detail.value || null });
        } catch (e) {
            this.goalError = this.messageOf(e);
        }
    }

    async removeGoalRow(event) {
        this.goalError = undefined;
        try {
            this.goals = await removeGoal({ goalId: event.target.dataset.id });
        } catch (e) {
            this.goalError = this.messageOf(e);
        }
    }

    async markGoalPassed(event) {
        await this.recordOutcome(event.target.dataset.id, true);
    }

    async markGoalNotPassed(event) {
        await this.recordOutcome(event.target.dataset.id, false);
    }

    snoozeGoal(event) {
        this.snoozedGoalIds = [...this.snoozedGoalIds, event.target.dataset.id];
    }

    async recordOutcome(goalId, passed) {
        const goal = this.goals.find((g) => g.id === goalId);
        try {
            this.goals = await recordGoalOutcome({ goalId, passed });
            if (passed) {
                this.earnedCodes = await getEarnedCerts();
                this.goalNotice = `Congratulations on passing${goal ? ' ' + goal.certName : ''}! It is now marked as earned.`;
            } else {
                this.goalNotice = `Thanks for letting us know${goal ? ' about ' + goal.certName : ''}. When you book a retake, add it again under Manage upcoming exams.`;
                this.openScores(goalId, goal ? goal.certName : '');
            }
        } catch (e) {
            this.fail(e);
        }
    }

    // ------------------------------------------- exam results (after a failed exam)

    scoresGoalId;
    scoresCertName = '';
    scoresText = '';
    scoresPreview;      // { certName, passingScore, passingEstimated, domains, rows }
    scoresRows = [];    // editable rows: { key, name, pct, domain }
    scoresError;
    scoresDone;         // summary shown after saving

    get isScores() { return this.view === 'scores'; }
    get scoresCertLabel() { return this.scoresCertName ? ` (${this.scoresCertName})` : ''; }
    get hasScoresPreview() { return !!this.scoresPreview; }
    get noScoresPreview() { return !this.scoresPreview; }
    get cannotPreviewScores() { return this.busy || !(this.scoresText || '').trim(); }
    get cannotSaveScores() { return this.busy || this.scoresRows.length === 0; }
    get scoresPassNote() {
        const p = this.scoresPreview;
        if (!p) return '';
        return p.passingEstimated
            ? `Pass mark not on file for this exam, so ${p.passingScore}% is assumed.`
            : `Pass mark: ${p.passingScore}%.`;
    }
    get scoreDomainOptions() {
        const none = { label: '(not one of these sections)', value: '' };
        const d = this.scoresPreview ? this.scoresPreview.domains : [];
        return [none, ...d.map((x) => ({ label: x, value: x }))];
    }

    openScores(goalId, certName) {
        this.scoresGoalId = goalId;
        this.scoresCertName = certName;
        this.scoresText = '';
        this.scoresPreview = undefined;
        this.scoresRows = [];
        this.scoresError = undefined;
        this.scoresDone = undefined;
        this.view = 'scores';
    }

    handleScoresText(event) { this.scoresText = event.target.value; }

    async previewScoresClick() {
        this.scoresError = undefined;
        this.busy = true;
        try {
            const p = await previewSectionScores({ goalId: this.scoresGoalId, text: this.scoresText });
            if (!p.rows.length) {
                this.scoresError = 'No section scores found. Paste lines like "Prompt Engineering: 83%".';
                this.scoresPreview = undefined;
            } else {
                this.scoresPreview = p;
                this.scoresRows = p.rows.map((r, i) => ({ key: 'r' + i, name: r.name, pct: r.pct, domain: r.domain || '' }));
            }
        } catch (e) {
            this.scoresError = this.messageOf(e);
        } finally {
            this.busy = false;
        }
    }

    handleScoreDomain(event) {
        const key = event.target.dataset.key;
        const value = event.detail.value;
        this.scoresRows = this.scoresRows.map((r) => (r.key === key ? { ...r, domain: value } : r));
    }

    editScores() {
        this.scoresPreview = undefined;
        this.scoresRows = [];
        this.scoresError = undefined;
    }

    async saveScoresClick() {
        this.scoresError = undefined;
        this.busy = true;
        try {
            const rows = this.scoresRows.map((r) => ({ name: r.name, pct: r.pct, domain: r.domain || null }));
            this.scoresDone = await saveSectionScores({ goalId: this.scoresGoalId, rowsJson: JSON.stringify(rows) });
        } catch (e) {
            this.scoresError = this.messageOf(e);
        } finally {
            this.busy = false;
        }
    }

    closeScores() { this.showSelect(); }

    /** Plain message from an Apex or JS error, for inline display. */
    messageOf(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong. Please try again.';
    }

    async toggleEarned(event) {
        const code = event.target.dataset.code;
        const nowEarned = !this.earnedCodes.includes(code);
        const before = this.earnedCodes;
        // Optimistic update, rolled back if the save fails.
        this.earnedCodes = nowEarned ? [...before, code] : before.filter((c) => c !== code);
        if (nowEarned && this.hideEarned) {
            this.selectedCodes = this.selectedCodes.filter((c) => c !== code);
        }
        try {
            this.earnedCodes = await setCertEarned({ certCode: code, earned: nowEarned });
            if (nowEarned) await this.refreshGoals(); // the server settles an open goal for a cert you now hold
        } catch (e) {
            this.earnedCodes = before;
            this.fail(e);
        }
    }

    handleTypeFilter(event) {
        this.typeFilter = event.detail.value;
    }

    handleAreaFilter(event) {
        this.areaFilter = event.detail.value;
    }

    get filteredCerts() {
        const f = this.filterText.toLowerCase();
        return this.allCerts
            .filter((c) => !(this.isTestMode && c.isAggregate))
            .filter((c) => !(this.hideRetiring && (c.status === 'Retiring' || c.status === 'Retired')))
            .filter((c) => !(this.hideEarned && this.earnedCodes.includes(c.code)))
            .filter((c) => this.typeFilter === ALL || certType(c.name) === this.typeFilter)
            .filter((c) => this.areaFilter === ALL || certArea(c.name) === this.areaFilter)
            .filter((c) => !f || c.name.toLowerCase().includes(f) || c.code.toLowerCase().includes(f))
            .map((c) => {
                const flagged = c.status === 'Retiring' || c.status === 'Retired';
                let note = '';
                if (flagged) {
                    const when = c.retiresOn ? (c.status === 'Retired' ? ' (' : ' on ') + c.retiresOn + (c.status === 'Retired' ? ')' : '') : '';
                    note = `${c.status === 'Retired' ? 'Retired' : 'Retiring'}${when}`;
                    if (c.pathForward) note += `. ${c.pathForward}`;
                }
                const prereqNames = (c.prereqs || []).map((n) => n.replace(/^Salesforce (Certified|Accredited) /, ''));
                return {
                    ...c,
                    checked: this.selectedCodes.includes(c.code),
                    label: c.isAggregate ? `${c.name} (earned via prerequisites)` : c.name,
                    isFlagged: flagged,
                    statusNote: note,
                    isEarned: this.earnedCodes.includes(c.code),
                    earnedLabel: this.earnedCodes.includes(c.code) ? 'Earned (undo)' : 'Mark earned',
                    earnedIcon: this.earnedCodes.includes(c.code) ? 'utility:check' : '',
                    hasPrereqs: prereqNames.length > 0,
                    prereqNote: `Requires: ${prereqNames.join(', ')}`
                };
            });
    }

    get selectedCerts() {
        return this.allCerts.filter((c) => this.selectedCodes.includes(c.code));
    }

    get noneSelected() { return this.selectedCodes.length === 0 || this.busy; }
    get selectedCount() { return this.selectedCodes.length; }

    handleFilter(event) {
        this.filterText = event.target.value || '';
    }

    toggleCert(event) {
        const code = event.target.dataset.code;
        if (event.target.checked && this.isTestMode) {
            this.selectedCodes = [code];
        } else if (event.target.checked) {
            if (!this.selectedCodes.includes(code)) this.selectedCodes = [...this.selectedCodes, code];
        } else {
            this.selectedCodes = this.selectedCodes.filter((c) => c !== code);
        }
    }

    deselectAll() {
        this.selectedCodes = [];
        this.prereqAnswers = {};
    }

    // Last session's picks, so "Select last session" can restore them in one click.
    lastSelection;

    /** Last session's certs that still exist in the picker list. */
    get lastSelectionCodes() {
        const l = this.lastSelection;
        if (!l || !l.mode || !l.certCodes) return [];
        const known = new Map(this.allCerts.map((c) => [c.code, c]));
        const codes = l.certCodes.filter((c) => known.has(c));
        // A test is one cert at a time, and never an aggregate.
        return l.mode === 'test' ? codes.filter((c) => !known.get(c).isAggregate).slice(0, 1) : codes;
    }

    get hasLastSelection() { return this.lastSelectionCodes.length > 0; }

    get lastSelectionLabel() {
        const n = this.lastSelectionCodes.length;
        const l = this.lastSelection;
        const mode = l && l.mode === 'test' ? 'Test' : 'Practice';
        return `Select last session (${mode}, ${n} cert${n === 1 ? '' : 's'})`;
    }

    selectLastSession() {
        const l = this.lastSelection;
        if (!l) return;
        this.mode = l.mode === 'test' ? 'test' : 'practice';
        if (this.mode === 'test') {
            this.timerChoice = l.timerMode === 'Strict' ? 'strict' : 'open';
        } else {
            this.minDifficulty = String(l.minDifficulty || 1);
        }
        this.selectedCodes = [...this.lastSelectionCodes];
        this.prereqAnswers = {};
    }

    removeCert(event) {
        const code = event.target.name;
        this.selectedCodes = this.selectedCodes.filter((c) => c !== code);
    }

    async start() {
        if (this.isTestMode) {
            await this.beginTest();
            return;
        }
        this.busy = true;
        this.error = undefined;
        try {
            const v = await startPractice({
                certCodes: this.selectedCodes,
                prereqAnswersJson: JSON.stringify(this.prereqAnswers),
                minDifficulty: parseInt(this.minDifficulty, 10) || 1,
                focusWeakAreas: this.focusChecked
            });
            if (v.error) {
                this.error = v.error;
            } else if (v.pendingCode) {
                this.pending = {
                    code: v.pendingCode,
                    certName: v.pendingCertName,
                    prereqs: (v.pendingPrereqNames || []).join(', ')
                };
                this.view = 'prereq';
            } else {
                this.applySession(v);
            }
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    async beginTest() {
        this.busy = true;
        this.error = undefined;
        try {
            const v = await startTest({ certCode: this.selectedCodes[0], strictTimer: this.timerChoice === 'strict' });
            if (v.error) {
                this.error = v.error;
            } else {
                this.applySession(v);
            }
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    answerPrereqYes() { this.answerPrereq(true); }
    answerPrereqNo() { this.answerPrereq(false); }

    answerPrereq(include) {
        this.prereqAnswers = { ...this.prereqAnswers, [this.pending.code]: include };
        this.start();
    }

    // ------------------------------------------------------------ session

    applySession(v) {
        if (v.testResult) {
            this.showTestResult(v.testResult);
            return;
        }
        this.session = v;
        this.grade = undefined;
        this.resetReport();
        this.syncClock(v);
        if (v.isTest && v.isPaused) {
            this.stopPolling();
            this.question = undefined;
            this.view = 'paused';
            return;
        }
        if (v.question) {
            this.stopPolling();
            this.question = v.question;
            this.selectedKeys = [];
            this.view = 'question';
        } else {
            this.question = undefined;
            this.waitMessage = v.waitMessage;
            this.view = 'waiting';
            this.startPolling();
        }
    }

    get scoreText() {
        if (!this.session) return '';
        if (this.session.isTest) {
            const n = this.question ? this.question.questionNumber : this.session.answered + 1;
            return `Test · question ${Math.min(n, this.session.questionTarget)} of ${this.session.questionTarget}`;
        }
        const { answered, correct } = this.session;
        if (!answered) return 'No answers yet';
        return `Score: ${correct}/${answered} (${Math.round((100 * correct) / answered)}%)`;
    }

    get sessionCertNames() {
        return this.session && this.session.certs ? this.session.certs.map((c) => c.name).join(' · ') : '';
    }

    get overviewCerts() {
        return (this.session && this.session.certs ? this.session.certs : []).map((c) => ({
            ...c,
            examLine: c.isAggregate
                ? 'Credential earned via its prerequisites'
                : c.numQuestions
                    ? `Real exam: ${c.numQuestions} questions · ${c.durationMin} min · pass at ${c.passingScore}%`
                    : 'Exam details not derived yet'
        }));
    }

    // ----------------------------------------------------------- question

    get questionMeta() {
        const q = this.question;
        if (!q) return '';
        const parts = [q.certName];
        if (q.domain) parts.push(q.domain);
        if (q.difficulty) parts.push(`difficulty ${q.difficulty}/5`);
        return parts.join(' · ');
    }

    get isMulti() { return this.question && this.question.chooseCount > 1; }

    get chooseText() {
        if (!this.question) return '';
        return this.isMulti ? `Choose ${this.question.chooseCount}.` : 'Choose 1.';
    }

    get questionOptions() {
        return (this.question ? this.question.options : []).map((o) => ({
            ...o,
            cls: 'option' + (this.selectedKeys.includes(o.key) ? ' option_selected' : '')
        }));
    }

    get submitDisabled() {
        return this.busy || !this.question || this.selectedKeys.length !== this.question.chooseCount;
    }

    selectOption(event) {
        this.toggleKey(event.currentTarget.dataset.key);
    }

    toggleKey(key) {
        if (!this.question || !this.question.options.some((o) => o.key === key)) return;
        if (!this.isMulti) {
            this.selectedKeys = [key];
        } else if (this.selectedKeys.includes(key)) {
            this.selectedKeys = this.selectedKeys.filter((k) => k !== key);
        } else if (this.selectedKeys.length < this.question.chooseCount) {
            this.selectedKeys = [...this.selectedKeys, key];
        }
    }

    async submit() {
        if (this.submitDisabled) return;
        if (this.session && this.session.isTest) {
            await this.submitTest();
            return;
        }
        this.busy = true;
        this.error = undefined;
        try {
            const g = await submitAnswer({ letters: this.selectedKeys });
            if (g.status === 'ok') {
                this.grade = g;
                this.session = { ...this.session, answered: g.answered, correct: g.correct };
                this.view = 'feedback';
            } else if (g.status === 'noQuestion') {
                await this.next();
            } else if (g.status === 'noSession') {
                await this.showSelect();
            } else if (g.status === 'invalid') {
                this.error = 'Please pick the required number of options.';
            }
            // 'duplicate' (double click) is ignored
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    async submitTest() {
        this.busy = true;
        this.error = undefined;
        try {
            const v = await submitTestAnswer({ letters: this.selectedKeys });
            if (v.error) this.error = v.error;
            if (v.testResult || v.hasActiveSession) {
                this.applySession(v);
            } else {
                await this.showSelect();
            }
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    // ---------------------------------------------------------- test mode

    get submitLabel() {
        return this.session && this.session.isTest ? 'Submit and continue' : 'Submit answer';
    }

    async pause() {
        this.busy = true;
        try {
            this.applySession(await pauseTest());
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    async resume() {
        this.busy = true;
        try {
            this.applySession(await resumeTest());
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    async confirmEndTest() {
        const remaining = this.session ? this.session.questionTarget - this.session.answered : 0;
        const ok = await LightningConfirm.open({
            message: `End the test now? ${remaining} unanswered question(s) will count as incorrect. You'll still see how you did on the questions you completed.`,
            label: 'End test',
            theme: 'warning'
        });
        if (ok) await this.endTest();
    }

    async endTest() {
        if (this.finishing) return;
        this.finishing = true;
        this.busy = true;
        try {
            const v = await finishTest();
            if (v.testResult) this.showTestResult(v.testResult);
            else await this.showSelect();
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
            this.finishing = false;
        }
    }

    showTestResult(r) {
        this.stopPolling();
        this.stopClock();
        this.session = undefined;
        this.question = undefined;
        this.testResult = {
            ...r,
            domains: (r.domains || []).map((d, i) => ({
                ...d,
                key: 'd' + i,
                weightText: d.weight != null ? `${Math.round(d.weight)}% of exam` : '',
                scoreText: d.answered ? `${d.pct}% (${d.correct}/${d.answered})` : 'Not reached',
                verdict: !d.answered ? '' : d.likelyPass ? 'Likely pass' : 'Below pass mark',
                verdictClass: 'slds-badge ' + (!d.answered ? '' : d.likelyPass ? 'slds-theme_success' : 'slds-theme_error'),
                barStyle: `width:${d.answered ? d.pct : 0}%`
            })),
            recommendations: (r.recommendations || []).map((t, i) => ({ key: 'r' + i, text: t })),
            missed: (r.missed || []).map((m, i) => ({ ...m, key: 'm' + i, feedbackBlocks: this.splitBlocks(m.feedback) })),
            studyLinks: this.mapLinks(r.studyLinks)
        };
        this.view = 'testResult';
    }

    get resultBannerClass() {
        return 'slds-box slds-m-bottom_medium verdict ' + (this.testResult && this.testResult.passed ? 'verdict_correct' : 'verdict_wrong');
    }

    get resultHeadline() {
        const r = this.testResult;
        if (!r) return '';
        return `${r.passed ? 'PASS' : 'FAIL'} — ${r.officialPct}% (pass mark ${r.passing}%${r.passingEstimated ? ', estimated' : ''})`;
    }

    get resultDetail() {
        const r = this.testResult;
        if (!r) return '';
        return `${r.correct} of ${r.target} correct for ${r.certName}.`;
    }

    get incompleteNote() {
        const r = this.testResult;
        if (!r || !r.incomplete) return '';
        const lead = r.timedOut ? 'Time ran out' : 'You ended the test early';
        const verdict = r.answered
            ? `On the ${r.answered} question(s) you completed you scored ${r.answeredPct}%, so you likely ${r.answeredLikelyPass ? 'would have passed' : 'would not have passed'} at that pace.`
            : 'No questions were answered.';
        return `${lead} with ${r.unanswered} question(s) unanswered; they count as incorrect above. ${verdict}`;
    }

    get timeNote() {
        const r = this.testResult;
        if (!r) return '';
        const used = this.formatDuration(r.elapsedSeconds || 0);
        const limit = r.limitMin ? ` of the ${r.limitMin}-minute limit` : '';
        return `Time with questions on screen: ${used}${limit}${r.strictTimer ? ' (strict timer)' : ' (open time)'}.`;
    }

    get hasResultMissed() { return this.testResult && this.testResult.missed.length > 0; }

    // clock: server reports elapsed seconds + whether it's running; the page ticks locally
    syncClock(v) {
        this.clockBase = v.elapsedSeconds || 0;
        this.clockReceivedAt = Date.now();
        if (v.isTest && v.clockRunning) {
            if (!this.clockInterval) {
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                this.clockInterval = setInterval(() => this.onTick(), 1000);
            }
        } else {
            this.stopClock();
        }
    }

    stopClock() {
        if (this.clockInterval) clearInterval(this.clockInterval);
        this.clockInterval = undefined;
    }

    currentElapsed() {
        const running = !!this.clockInterval;
        return this.clockBase + (running ? Math.floor((Date.now() - this.clockReceivedAt) / 1000) : 0);
    }

    onTick() {
        this.clockTick += 1;
        const s = this.session;
        if (s && s.isTest && s.strictTimer && s.timeLimitMin && this.currentElapsed() >= s.timeLimitMin * 60) {
            this.stopClock();
            this.endTest();
        }
    }

    get timerText() {
        // eslint-disable-next-line no-unused-expressions
        this.clockTick;
        const s = this.session;
        if (!s || !s.isTest) return '';
        const elapsed = this.currentElapsed();
        if (s.strictTimer && s.timeLimitMin) {
            return `Time left ${this.formatDuration(Math.max(0, s.timeLimitMin * 60 - elapsed))}`;
        }
        return `Elapsed ${this.formatDuration(elapsed)}${s.timeLimitMin ? ` (real exam: ${s.timeLimitMin} min)` : ''}`;
    }

    get timerClass() {
        // eslint-disable-next-line no-unused-expressions
        this.clockTick;
        const s = this.session;
        const low = s && s.strictTimer && s.timeLimitMin && s.timeLimitMin * 60 - this.currentElapsed() < 300;
        return 'slds-text-title_bold' + (low ? ' timer_low' : '');
    }

    formatDuration(totalSeconds) {
        const h = Math.floor(totalSeconds / 3600);
        const m = Math.floor((totalSeconds % 3600) / 60);
        const sec = totalSeconds % 60;
        const mm = String(m).padStart(h ? 2 : 1, '0');
        const ss = String(sec).padStart(2, '0');
        return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
    }

    // ----------------------------------------------------------- feedback

    get verdictClass() {
        return 'slds-box slds-m-bottom_small verdict ' + (this.grade && this.grade.isCorrect ? 'verdict_correct' : 'verdict_wrong');
    }

    get verdictText() {
        if (!this.grade) return '';
        if (this.grade.isCorrect) return 'Correct!';
        return `Not quite. You chose ${this.grade.chosen.join(', ')}; the correct answer is ${this.grade.correctKeys.join(', ')}.`;
    }

    get feedbackOptions() {
        const q = this.grade && this.grade.question;
        return (q ? q.options : []).map((o) => {
            let cls = 'option option_static';
            if (o.isCorrect) cls += ' option_correct';
            else if (o.wasChosen) cls += ' option_wrong';
            return {
                ...o,
                cls,
                badge: o.isCorrect ? (o.wasChosen ? 'Correct · your answer' : 'Correct answer') : o.wasChosen ? 'Your answer' : ''
            };
        });
    }

    get gradedStem() {
        return this.grade && this.grade.question ? this.grade.question.stem : '';
    }

    get gradedMeta() {
        const q = this.grade && this.grade.question;
        if (!q) return '';
        return `Question ${q.questionNumber} · ${q.certName}${q.domain ? ' · ' + q.domain : ''}`;
    }

    async next() {
        this.resetReport();
        this.busy = true;
        this.error = undefined;
        try {
            const v = await nextQuestion();
            if (v.hasActiveSession) {
                this.applySession(v);
            } else {
                await this.showSelect();
            }
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    // ------------------------------------------------------------ polling

    startPolling() {
        this.stopPolling();
        this.pollCount = 0;
        this.schedulePoll();
    }

    schedulePoll() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setTimeout(async () => {
            this.pollCount += 1;
            try {
                const v = await nextQuestion();
                if (!v.hasActiveSession) {
                    await this.showSelect();
                } else if (v.question) {
                    this.applySession(v);
                } else if (this.pollCount < MAX_POLLS) {
                    this.waitMessage = v.waitMessage;
                    this.schedulePoll();
                }
            } catch (e) {
                this.fail(e);
            }
        }, POLL_MS);
    }

    stopPolling() {
        if (this.pollTimer) clearTimeout(this.pollTimer);
        this.pollTimer = undefined;
    }

    /** "Check again": also asks the server to clear any failure cooldown or stalled lock and restart generation. */
    async retryPolling() {
        this.stopPolling();
        try {
            const v = await retryGeneration();
            if (v.hasActiveSession && v.question) {
                this.applySession(v);
                return;
            }
            this.waitMessage = v.waitMessage;
        } catch (e) {
            // Fall through: polling below reports any persistent error.
        }
        this.startPolling();
    }

    // ------------------------------------------------------------ summary

    async showSummary() { await this.loadSummary(false); }
    async endSession() { await this.loadSummary(true); }

    async loadSummary(end) {
        this.busy = true;
        this.error = undefined;
        this.stopPolling();
        try {
            const s = await getSummary({ endSession: end });
            this.summary = {
                ...s,
                missed: (s.missed || []).map((m, i) => ({ ...m, key: 'm' + i, feedbackBlocks: this.splitBlocks(m.feedback) })),
                areas: (s.areas || []).map((a, i) => ({ ...a, key: 'a' + i, barStyle: `width:${a.pct}%` })),
                studyLinks: this.mapLinks(s.studyLinks)
            };
            this.view = 'summary';
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    get summaryScoreText() {
        if (!this.summary || !this.summary.answered) return 'No questions answered yet.';
        return `${this.summary.correct} of ${this.summary.answered} correct (${this.summary.pct}%)`;
    }

    get hasMissed() { return this.summary && this.summary.missed && this.summary.missed.length > 0; }
    get hasAreas() { return this.summary && this.summary.areas && this.summary.areas.length > 0; }
    get canContinue() { return this.summary && this.summary.sessionActive; }

    splitBlocks(text) {
        return (text || '')
            .split('\n\n')
            .filter((b) => b.trim())
            .map((b, i) => ({ key: 'b' + i, text: b.replace(/\*\*/g, '') }));
    }

    continuePractice() { this.next(); }
    newSession() { this.showSelect(); }

    // ------------------------------------------------- suggested next certs

    recs = [];

    get hasRecs() { return this.recs.length > 0; }
    get recsSubline() {
        const n = this.earnedCodes.length;
        return n
            ? `Based on the ${n} certification${n === 1 ? '' : 's'} you marked as earned, plus a couple of ways to broaden your skills. Retiring exams are left out.`
            : 'You have not marked any certifications as earned yet, so these are popular places to start. Use "Mark earned" in the list for suggestions tailored to you.';
    }

    buildRecs() {
        this.recs = recommend(this.allCerts, this.earnedCodes).map((r, i) => ({
            ...r,
            key: 'r' + i,
            isBroaden: r.kind === 'broaden'
        }));
    }

    async showRecs() {
        this.stopPolling();
        this.error = undefined;
        this.busy = true;
        try {
            if (!this.allCerts.length) this.allCerts = await listCerts();
            try {
                this.earnedCodes = await getEarnedCerts();
            } catch (e) {
                // fall back to what is already loaded
            }
            this.buildRecs();
            this.view = 'recs';
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    async practiceRec(event) {
        const code = event.target.dataset.code;
        this.mode = 'practice';
        await this.showSelect();
        this.selectedCodes = [code];
    }

    async recAlreadyHave(event) {
        const code = event.target.dataset.code;
        try {
            this.earnedCodes = await setCertEarned({ certCode: code, earned: true });
            this.buildRecs();
        } catch (e) {
            this.fail(e);
        }
    }

    // ------------------------------------------------------------ history

    async showHistory() {
        this.busy = true;
        this.error = undefined;
        try {
            const h = await getHistory();
            const fmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
            this.history = {
                ...h,
                weakAreas: (h.weakAreas || []).map((a, i) => ({ ...a, key: 'w' + i, barStyle: `width:${a.pct}%` })),
                suggestedLinks: this.mapLinks(h.suggestedLinks, fmt),
                sessions: (h.sessions || []).map((x) => {
                    let scoreText;
                    let badge = '';
                    let badgeClass = 'slds-badge';
                    if (x.isTest) {
                        if (x.active) {
                            scoreText = `In progress · ${x.answered} of ${x.target} answered`;
                        } else {
                            scoreText = `${x.officialPct}% (${x.correct}/${x.target})`;
                            badge = x.passed ? 'PASS' : 'FAIL';
                            badgeClass += x.passed ? ' slds-theme_success' : ' slds-theme_error';
                        }
                    } else {
                        scoreText = x.answered ? `${x.pct}% (${x.correct}/${x.answered})` : 'No answers yet';
                        if (x.active) badge = 'Active';
                    }
                    return {
                        ...x,
                        when: x.startedAt ? fmt.format(new Date(x.startedAt)) : '',
                        modeLabel: x.isTest ? 'Test' : 'Practice',
                        scoreText,
                        badge,
                        badgeClass,
                        canOpen: !(x.isTest && x.active)
                    };
                })
            };
            this.view = 'history';
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    get historyHeadline() {
        const h = this.history;
        if (!h || !h.totalAnswered) return 'No questions answered yet — your progress will build up here.';
        return `${h.totalAnswered} questions answered · ${h.overallPct}% correct overall`;
    }

    get historySubline() {
        const h = this.history;
        if (!h) return '';
        const tests = h.testsTaken ? ` · ${h.testsPassed} of ${h.testsTaken} mock test(s) passed` : '';
        return `${h.sessionsCount} session(s)${tests}`;
    }

    get hasSuggestedLinks() { return this.history && this.history.suggestedLinks.length > 0; }
    get hasSummaryLinks() { return this.summary && this.summary.studyLinks && this.summary.studyLinks.length > 0; }
    get hasTestLinks() { return this.testResult && this.testResult.studyLinks && this.testResult.studyLinks.length > 0; }

    /** Study links for display: stable keys, a "Cert · Type" line, and (in My progress) when it was last suggested. */
    mapLinks(links, fmt) {
        return (links || []).map((l, i) => ({
            ...l,
            key: 'l' + i,
            meta: [l.certName, l.linkType].filter((x) => x).join(' · '),
            lastText: fmt && l.lastSuggested ? 'Last suggested ' + fmt.format(new Date(l.lastSuggested)) : ''
        }));
    }

    get hasWeakAreas() { return this.history && this.history.weakAreas.length > 0; }
    get hasHistorySessions() { return this.history && this.history.sessions.length > 0; }

    async openPastSession(event) {
        const id = event.currentTarget.dataset.id;
        this.busy = true;
        this.error = undefined;
        try {
            const d = await getSessionDetail({ sessionId: id });
            if (d.error) {
                this.error = d.error;
            } else if (d.test) {
                this.showTestResult(d.test);
                this.fromHistory = true;
            } else if (d.practice) {
                const s = d.practice;
                this.summary = {
                    ...s,
                    sessionActive: false,
                    missed: (s.missed || []).map((m, i) => ({ ...m, key: 'm' + i, feedbackBlocks: this.splitBlocks(m.feedback) })),
                    areas: (s.areas || []).map((a, i) => ({ ...a, key: 'a' + i, barStyle: `width:${a.pct}%` })),
                studyLinks: this.mapLinks(s.studyLinks)
                };
                this.fromHistory = true;
                this.view = 'summary';
            }
        } catch (e) {
            this.fail(e);
        } finally {
            this.busy = false;
        }
    }

    backToHistory() { this.showHistory(); }

    // ---------------------------------------------------------- keyboard

    // ------------------------------------------- contributions / suggestions

    contribKind = 'Study resource';
    contribCert = '';
    contribTitle = '';
    contribUrl = '';
    contribDetails = '';
    contribError;
    contribSending = false;
    contribSent = false;
    contribReturnView = 'select';

    get contribKindOptions() {
        return [
            { label: 'A study resource for a cert', value: 'Study resource' },
            { label: 'A suggestion for the app', value: 'Suggestion' }
        ];
    }
    get contribIsResource() { return this.contribKind === 'Study resource'; }
    get contribHeading() { return this.contribIsResource ? 'Share a study resource' : 'Suggest an improvement'; }
    get contribHelp() {
        return this.contribIsResource
            ? 'Know a great guide, trail, or set of notes? Share a link or paste text. An admin reviews it before it is used to write new questions.'
            : 'Tell us what would make Cert Study better: features, wording, anything that got in your way.';
    }
    get contribCertOptions() {
        return this.allCerts
            .filter((c) => !c.isAggregate)
            .map((c) => ({ label: c.name, value: c.code }));
    }

    async openContribute(event) {
        const kind = event.currentTarget.dataset.kind || 'Study resource';
        this.contribReturnView = this.view;
        if (!this.allCerts.length) {
            try { this.allCerts = await listCerts(); } catch (e) { /* the cert list is optional for suggestions */ }
        }
        this.resetContributeForm();
        this.contribKind = kind;
        this.contribCert = this.defaultContribCert();
        this.view = 'contribute';
    }

    defaultContribCert() {
        const usable = this.allCerts.filter((c) => !c.isAggregate);
        const fromSession = this.session && this.session.certs ? this.session.certs.find((c) => !c.isAggregate) : null;
        if (fromSession) {
            const match = usable.find((c) => c.name === fromSession.name);
            if (match) return match.code;
        }
        const picked = this.selectedCodes && this.selectedCodes[0];
        return picked && usable.some((c) => c.code === picked) ? picked : '';
    }

    resetContributeForm() {
        this.contribTitle = '';
        this.contribUrl = '';
        this.contribDetails = '';
        this.contribError = undefined;
        this.contribSending = false;
        this.contribSent = false;
    }

    closeContribute() {
        this.resetContributeForm();
        const back = this.contribReturnView;
        if (back === 'select' || !back) this.returnToSelect();
        else this.view = back;
    }

    changeContribKind(event) { this.contribKind = event.detail.value; this.contribError = undefined; }
    changeContribCert(event) { this.contribCert = event.detail.value; }
    changeContribTitle(event) { this.contribTitle = event.target.value; }
    changeContribUrl(event) { this.contribUrl = event.target.value; }
    changeContribDetails(event) { this.contribDetails = event.target.value; }

    async sendContribution() {
        this.contribError = undefined;
        const details = (this.contribDetails || '').trim();
        const url = (this.contribUrl || '').trim();
        if (this.contribIsResource) {
            if (!this.contribCert) { this.contribError = 'Pick the certification this resource is for.'; return; }
            if (!url && !details) { this.contribError = 'Add a link, some text, or both.'; return; }
        } else if (!details) {
            this.contribError = 'Please describe your suggestion.';
            return;
        }
        this.contribSending = true;
        try {
            await submitContribution({
                kind: this.contribKind,
                certCode: this.contribIsResource ? this.contribCert : null,
                title: this.contribTitle,
                url: this.contribIsResource ? url : null,
                details
            });
            this.contribSent = true;
        } catch (e) {
            this.contribError = (e && e.body && e.body.message) || 'Could not send it. Please try again.';
        } finally {
            this.contribSending = false;
        }
    }

    // -------------------------------------------------- report a problem

    reportOpen = false;
    reportType = '';
    reportComment = '';
    reportError;
    reportSending = false;
    reportedIds = []; // question ids already reported this visit

    get reportTypeOptions() {
        return [
            { label: 'Inaccurate or factually wrong', value: 'Inaccurate' },
            { label: 'More than one correct answer', value: 'Multiple correct answers' },
            { label: 'No correct answer', value: 'No correct answer' },
            { label: 'Outdated: missing a recent product update', value: 'Outdated' },
            { label: 'Unclear or badly worded', value: 'Unclear wording' },
            { label: 'The explanation is wrong', value: 'Explanation is wrong' },
            { label: 'Other', value: 'Other' }
        ];
    }

    get reportQuestionId() {
        if (this.view === 'feedback') return this.grade && this.grade.question ? this.grade.question.id : undefined;
        return this.question ? this.question.id : undefined;
    }

    get reportAlreadySent() { return this.reportedIds.includes(this.reportQuestionId); }
    get showReportLink() { return !!this.reportQuestionId && !this.reportOpen && !this.reportAlreadySent; }
    get showReportForm() { return !!this.reportQuestionId && this.reportOpen && !this.reportAlreadySent; }
    get reportSendDisabled() { return this.reportSending || !this.reportType; }
    get reportCommentRequired() { return this.reportType === 'Other'; }

    openReport() {
        this.reportOpen = true;
        this.reportError = undefined;
    }

    cancelReport() { this.resetReport(); }

    resetReport() {
        this.reportOpen = false;
        this.reportType = '';
        this.reportComment = '';
        this.reportError = undefined;
        this.reportSending = false;
    }

    changeReportType(event) { this.reportType = event.detail.value; }
    changeReportComment(event) { this.reportComment = event.target.value; }

    async sendReport() {
        const qid = this.reportQuestionId;
        if (!qid || !this.reportType) return;
        if (this.reportCommentRequired && !(this.reportComment || '').trim()) {
            this.reportError = 'Please describe the problem.';
            return;
        }
        this.reportSending = true;
        this.reportError = undefined;
        try {
            await reportQuestion({ questionId: qid, issueType: this.reportType, comment: this.reportComment });
            this.reportedIds = [...this.reportedIds, qid];
            this.resetReport();
        } catch (e) {
            this.reportError = (e && e.body && e.body.message) || 'Could not send the report. Please try again.';
            this.reportSending = false;
        }
    }

    handleKey(event) {
        if (this.reportOpen) return; // typing a report: no answer shortcuts
        const tag = (event.target && event.target.tagName) || '';
        if (['INPUT', 'TEXTAREA'].includes(tag) || event.metaKey || event.ctrlKey || event.altKey) return;
        if (this.view === 'question') {
            const k = (event.key || '').toUpperCase();
            if (/^[A-E]$/.test(k)) {
                this.toggleKey(k);
                event.preventDefault();
            } else if (event.key === 'Enter') {
                this.submit();
                event.preventDefault();
            }
        } else if (this.view === 'feedback' && (event.key === 'Enter' || event.key === 'n' || event.key === 'N')) {
            this.next();
            event.preventDefault();
        }
    }

    // ------------------------------------------------------------- errors

    fail(e) {
        // eslint-disable-next-line no-console
        console.error(e);
        this.error = (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
        if (this.view === 'loading') this.view = 'select';
    }
}
