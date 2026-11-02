import { LightningElement, track } from 'lwc';
import listCerts from '@salesforce/apex/CertStudyController.listCerts';
import getActiveSession from '@salesforce/apex/CertStudyController.getActiveSession';
import startPractice from '@salesforce/apex/CertStudyController.startPractice';
import nextQuestion from '@salesforce/apex/CertStudyController.nextQuestion';
import submitAnswer from '@salesforce/apex/CertStudyController.submitAnswer';
import getSummary from '@salesforce/apex/CertStudyController.getSummary';

const POLL_MS = 4000;
const MAX_POLLS = 45; // ~3 minutes

export default class CertStudy extends LightningElement {
    view = 'loading'; // loading | select | prereq | question | feedback | waiting | summary
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

    // ------------------------------------------------------------ lifecycle

    connectedCallback() {
        this.keyHandler = this.handleKey.bind(this);
        window.addEventListener('keydown', this.keyHandler);
        this.load();
    }

    disconnectedCallback() {
        window.removeEventListener('keydown', this.keyHandler);
        this.stopPolling();
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
    get inSession() { return ['question', 'feedback', 'waiting'].includes(this.view); }
    get pollGaveUp() { return this.view === 'waiting' && this.pollCount >= MAX_POLLS; }

    async showSelect() {
        this.stopPolling();
        if (!this.allCerts.length) {
            this.allCerts = await listCerts();
        }
        this.selectedCodes = [];
        this.prereqAnswers = {};
        this.pending = undefined;
        this.view = 'select';
    }

    // ----------------------------------------------------- cert selection

    get filteredCerts() {
        const f = this.filterText.toLowerCase();
        return this.allCerts
            .filter((c) => !f || c.name.toLowerCase().includes(f) || c.code.toLowerCase().includes(f))
            .map((c) => ({
                ...c,
                checked: this.selectedCodes.includes(c.code),
                label: c.isAggregate ? `${c.name} (earned via prerequisites)` : c.name
            }));
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
        if (event.target.checked) {
            if (!this.selectedCodes.includes(code)) this.selectedCodes = [...this.selectedCodes, code];
        } else {
            this.selectedCodes = this.selectedCodes.filter((c) => c !== code);
        }
    }

    removeCert(event) {
        const code = event.target.name;
        this.selectedCodes = this.selectedCodes.filter((c) => c !== code);
    }

    async start() {
        this.busy = true;
        this.error = undefined;
        try {
            const v = await startPractice({
                certCodes: this.selectedCodes,
                prereqAnswersJson: JSON.stringify(this.prereqAnswers)
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

    answerPrereqYes() { this.answerPrereq(true); }
    answerPrereqNo() { this.answerPrereq(false); }

    answerPrereq(include) {
        this.prereqAnswers = { ...this.prereqAnswers, [this.pending.code]: include };
        this.start();
    }

    // ------------------------------------------------------------ session

    applySession(v) {
        this.session = v;
        this.grade = undefined;
        if (v.question) {
            this.stopPolling();
            this.question = v.question;
            this.selectedKeys = [];
            this.view = 'question';
        } else {
            this.question = undefined;
            this.view = 'waiting';
            this.startPolling();
        }
    }

    get scoreText() {
        if (!this.session) return '';
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

    retryPolling() {
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
                areas: (s.areas || []).map((a, i) => ({ ...a, key: 'a' + i, barStyle: `width:${a.pct}%` }))
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

    // ---------------------------------------------------------- keyboard

    handleKey(event) {
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
