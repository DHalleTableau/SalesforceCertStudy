/**
 * Backend for the certStudy Lightning web component (in-org practice app).
 * Thin layer over CertStudyService's core methods: same sessions, pool,
 * grading and summaries as the Agentforce agent, but returned as structured
 * data so the page can show the explanation until the learner clicks Next.
 * No model calls happen here; question generation stays in CertStudyPoolJob.
 *
 * Learner identity = the logged-in user's email (CertStudyService.resolveUserKey).
 */
public with sharing class CertStudyController {

    // ------------------------------------------------------------------ DTOs

    public class CertOption {
        @AuraEnabled public String code;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isAggregate;
        @AuraEnabled public String status;       // Retiring / Retired / Renamed; null = active
        @AuraEnabled public String retiresOn;    // e.g. "Feb 1, 2027"
        @AuraEnabled public String pathForward;
        @AuraEnabled public List<String> prereqs = new List<String>(); // direct prerequisite names
    }

    public class OptionView {
        @AuraEnabled public String key;
        @AuraEnabled public String text;
        @AuraEnabled public Boolean isCorrect;
        @AuraEnabled public Boolean wasChosen;
        @AuraEnabled public String explanation;
    }

    public class QuestionView {
        @AuraEnabled public String id;
        @AuraEnabled public Integer questionNumber;
        @AuraEnabled public String certName;
        @AuraEnabled public String domain;
        @AuraEnabled public Integer difficulty;
        @AuraEnabled public String stem;
        @AuraEnabled public List<OptionView> options = new List<OptionView>();
        @AuraEnabled public Integer chooseCount;
    }

    public class CertOverview {
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isAggregate;
        @AuraEnabled public Integer numQuestions;
        @AuraEnabled public Integer durationMin;
        @AuraEnabled public Integer passingScore;
        @AuraEnabled public String domains;
    }

    public class DomainView {
        @AuraEnabled public String name;
        @AuraEnabled public Decimal weight;
        @AuraEnabled public Integer quota;
        @AuraEnabled public Integer answered;
        @AuraEnabled public Integer correct;
        @AuraEnabled public Integer pct;
        @AuraEnabled public Boolean likelyPass;
    }

    public class TestResultView {
        @AuraEnabled public String certName;
        @AuraEnabled public Boolean passed;
        @AuraEnabled public Integer officialPct;
        @AuraEnabled public Integer passing;
        @AuraEnabled public Boolean passingEstimated;
        @AuraEnabled public Integer correct;
        @AuraEnabled public Integer target;
        @AuraEnabled public Integer answered;
        @AuraEnabled public Integer unanswered;
        @AuraEnabled public Integer answeredPct;
        @AuraEnabled public Boolean answeredLikelyPass;
        @AuraEnabled public Boolean incomplete;
        @AuraEnabled public Boolean timedOut;
        @AuraEnabled public Integer elapsedSeconds;
        @AuraEnabled public Integer limitMin;
        @AuraEnabled public Boolean strictTimer;
        @AuraEnabled public List<DomainView> domains = new List<DomainView>();
        @AuraEnabled public List<String> recommendations = new List<String>();
        @AuraEnabled public List<MissedView> missed = new List<MissedView>();
    }

    public class SessionView {
        @AuraEnabled public Boolean hasActiveSession = false;
        // test mode
        @AuraEnabled public Boolean isTest = false;
        @AuraEnabled public Boolean isPaused = false;
        @AuraEnabled public Boolean strictTimer = false;
        @AuraEnabled public Boolean clockRunning = false;
        @AuraEnabled public Integer elapsedSeconds = 0;
        @AuraEnabled public Integer timeLimitMin;
        @AuraEnabled public Integer questionTarget;
        @AuraEnabled public TestResultView testResult; // set once a test is scored
        @AuraEnabled public List<CertOverview> certs = new List<CertOverview>();
        @AuraEnabled public Integer answered = 0;
        @AuraEnabled public Integer correct = 0;
        @AuraEnabled public QuestionView question; // null = still generating
        // prerequisite prompt (start only)
        @AuraEnabled public String pendingCode;
        @AuraEnabled public String pendingCertName;
        @AuraEnabled public List<String> pendingPrereqNames;
        @AuraEnabled public String error;
    }

    public class GradeView {
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isCorrect;
        @AuraEnabled public List<String> chosen;
        @AuraEnabled public List<String> correctKeys;
        @AuraEnabled public Integer answered;
        @AuraEnabled public Integer correct;
        @AuraEnabled public QuestionView question; // the graded question, with per-option explanations
        @AuraEnabled public String rawFeedback;    // fallback if explanations couldn't be split per option
    }

    public class AreaView {
        @AuraEnabled public String label;
        @AuraEnabled public Integer correct;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer pct;
    }

    public class MissedView {
        @AuraEnabled public String stem;
        @AuraEnabled public String correctAnswer;
        @AuraEnabled public String yourAnswer;
        @AuraEnabled public String feedback;
    }

    public class SummaryView {
        @AuraEnabled public String error;
        @AuraEnabled public Boolean hasSession = false;
        @AuraEnabled public Boolean sessionActive = false;
        @AuraEnabled public Integer answered = 0;
        @AuraEnabled public Integer correct = 0;
        @AuraEnabled public Integer pct = 0;
        @AuraEnabled public List<AreaView> areas = new List<AreaView>();
        @AuraEnabled public List<MissedView> missed = new List<MissedView>();
    }

    public class HistoryArea {
        @AuraEnabled public String label;
        @AuraEnabled public Integer correct;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer pct;
    }

    public class HistorySession {
        @AuraEnabled public String id;
        @AuraEnabled public Boolean isTest;
        @AuraEnabled public String certNames;
        @AuraEnabled public DateTime startedAt;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Integer answered;
        @AuraEnabled public Integer correct;
        @AuraEnabled public Integer pct;
        @AuraEnabled public Integer target;      // tests
        @AuraEnabled public Integer officialPct; // tests: correct / target
        @AuraEnabled public Boolean passed;      // tests
        @AuraEnabled public Boolean completed;   // tests: scored
    }

    public class HistoryView {
        @AuraEnabled public Integer totalAnswered = 0;
        @AuraEnabled public Integer totalCorrect = 0;
        @AuraEnabled public Integer overallPct = 0;
        @AuraEnabled public Integer sessionsCount = 0;
        @AuraEnabled public Integer testsTaken = 0;
        @AuraEnabled public Integer testsPassed = 0;
        @AuraEnabled public List<HistoryArea> weakAreas = new List<HistoryArea>();
        @AuraEnabled public List<HistorySession> sessions = new List<HistorySession>();
    }

    public class DetailView {
        @AuraEnabled public String error;
        @AuraEnabled public SummaryView practice;
        @AuraEnabled public TestResultView test;
    }

    public static final Integer HISTORY_SESSIONS = 50;
    public static final Integer WEAK_AREA_MIN_ANSWERS = 2;
    public static final Integer WEAK_AREAS_SHOWN = 8;

    // --------------------------------------------------------------- methods

    @AuraEnabled
    public static List<CertOption> listCerts() {
        List<CertOption> out = new List<CertOption>();
        // Queried in the without-sharing service: Cert__c is Private for external users.
        Map<Id, List<String>> prereqs = CertStudyService.prereqNamesByCert();
        for (Cert__c c : CertStudyService.usableCerts()) {
            CertOption o = new CertOption();
            if (prereqs.containsKey(c.Id)) o.prereqs = prereqs.get(c.Id);
            o.code = c.Cert_Code__c;
            o.name = c.Name;
            o.isAggregate = c.Is_Aggregate__c;
            o.status = c.Exam_Status__c;
            o.retiresOn = c.Retires_On__c == null
                ? null
                : Datetime.newInstanceGmt(c.Retires_On__c, Time.newInstance(0, 0, 0, 0)).formatGmt('MMM d, yyyy');
            o.pathForward = c.Path_Forward__c;
            out.add(o);
        }
        return out;
    }

    /** Cert codes the current learner has marked as earned. */
    @AuraEnabled
    public static List<String> getEarnedCerts() {
        try {
            return CertStudyService.earnedCertCodes(UserInfo.getUserId());
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** Mark or unmark a cert as earned for the current learner; returns the updated list of earned codes. */
    @AuraEnabled
    public static List<String> setCertEarned(String certCode, Boolean earned) {
        try {
            return CertStudyService.setEarned(UserInfo.getUserId(), certCode, earned);
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** Report a problem with a question the current learner was served. */
    @AuraEnabled
    public static void reportQuestion(String questionId, String issueType, String comment) {
        try {
            CertStudyService.reportQuestion(UserInfo.getUserId(), questionId, issueType, comment);
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** Resume point on page load: the active session and its current question, if any. */
    @AuraEnabled
    public static SessionView getActiveSession() {
        try {
            Study_Session__c s = CertStudyService.activeSession(CertStudyService.resolveUserKey(null));
            SessionView v = new SessionView();
            if (s == null) return v;
            fillSession(v, s, false);
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** prereqAnswersJson: {"CODE": true/false, ...} answers collected from earlier prompts. */
    @AuraEnabled
    public static SessionView startPractice(List<String> certCodes, String prereqAnswersJson) {
        try {
            Map<String, Boolean> answers = new Map<String, Boolean>();
            if (String.isNotBlank(prereqAnswersJson)) {
                Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(prereqAnswersJson);
                for (String k : raw.keySet()) answers.put(k.toUpperCase(), raw.get(k) == true);
            }
            CertStudyService.StartOutcome res = CertStudyService.startSessionCore(
                CertStudyService.resolveUserKey(null), certCodes, answers
            );
            SessionView v = new SessionView();
            if (res.error != null) {
                v.error = res.error;
                return v;
            }
            if (res.pendingCode != null) {
                v.pendingCode = res.pendingCode;
                v.pendingCertName = res.pendingCertName;
                v.pendingPrereqNames = res.pendingPrereqNames;
                return v;
            }
            fillSession(v, res.session, true);
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** Current unanswered question, or claims the next one. question == null means still generating. */
    @AuraEnabled
    public static SessionView nextQuestion() {
        try {
            Study_Session__c s = CertStudyService.activeSession(CertStudyService.resolveUserKey(null));
            SessionView v = new SessionView();
            if (s == null) return v;
            fillSession(v, s, true);
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    @AuraEnabled
    public static GradeView submitAnswer(List<String> letters) {
        try {
            Study_Session__c s = CertStudyService.activeSession(CertStudyService.resolveUserKey(null));
            GradeView g = new GradeView();
            if (s == null) {
                g.status = 'noSession';
                return g;
            }
            List<String> chosen = new List<String>();
            for (String l : letters == null ? new List<String>() : letters) {
                if (String.isNotBlank(l)) chosen.add(l.trim().toUpperCase());
            }
            chosen.sort();
            CertStudyService.GradeOutcome res = CertStudyService.gradeCore(s, chosen, false);
            g.status = res.status;
            g.isCorrect = res.isCorrect;
            g.chosen = res.chosen;
            g.correctKeys = res.correct;
            g.answered = res.answered;
            g.correct = res.right;
            if (res.status == 'ok') {
                g.question = toView(res.question, res.answered, new Set<String>(res.chosen), true);
                Boolean anyExplanation = false;
                for (OptionView o : g.question.options) {
                    if (String.isNotBlank(o.explanation)) anyExplanation = true;
                }
                if (!anyExplanation) g.rawFeedback = res.question.Feedback_MD__c;
            }
            return g;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    @AuraEnabled
    public static SummaryView getSummary(Boolean endSession) {
        try {
            SummaryView v = new SummaryView();
            Study_Session__c s = CertStudyService.latestSession(CertStudyService.resolveUserKey(null));
            if (s == null) return v;
            if (CertStudyService.isTest(s) && s.Status__c == CertStudyService.ACTIVE) {
                v.error = 'Results are shown when the test ends.';
                return v;
            }
            CertStudyService.SummaryData d = CertStudyService.summaryCore(s, endSession == true);
            return toSummaryView(d);
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    private static SummaryView toSummaryView(CertStudyService.SummaryData d) {
        {
            SummaryView v = new SummaryView();
            v.hasSession = true;
            v.sessionActive = d.session.Status__c == CertStudyService.ACTIVE;
            v.answered = d.answered;
            v.correct = d.right;
            v.pct = CertStudyService.pct(d.right, d.answered);
            for (CertStudyService.AreaStat st : d.areas) {
                AreaView a = new AreaView();
                a.label = st.certName + (String.isBlank(st.domain) ? '' : ' / ' + st.domain);
                a.correct = st.right;
                a.total = st.total;
                a.pct = st.pct();
                v.areas.add(a);
            }
            for (Answer__c a : d.missed) {
                MissedView m = new MissedView();
                m.stem = a.Question__r.Stem__c;
                m.correctAnswer = describe(a.Question__r.Options_JSON__c, a.Question__r.Correct_JSON__c);
                m.yourAnswer = a.User_Answer__c;
                m.feedback = a.Question__r.Feedback_MD__c;
                v.missed.add(m);
            }
            return v;
        }
    }

    // --------------------------------------------------------------- history

    /** The learner's sessions and tests, plus all-time weakest areas. */
    @AuraEnabled
    public static HistoryView getHistory() {
        try {
            String key = CertStudyService.resolveUserKey(null);
            HistoryView h = new HistoryView();
            Integer maxSessions = HISTORY_SESSIONS;
            List<Study_Session__c> sessions = [
                SELECT Id, Mode__c, Status__c, Started_At__c, Cert_Codes__c, Question_Target__c, Completed_At__c
                FROM Study_Session__c WHERE User_Key__c = :key
                ORDER BY Started_At__c DESC LIMIT :maxSessions
            ];
            Map<Id, Integer> totals = new Map<Id, Integer>();
            Map<Id, Integer> rights = new Map<Id, Integer>();
            for (AggregateResult ar : [
                SELECT Study_Session__c sid, COUNT(Id) n FROM Answer__c
                WHERE Study_Session__c IN :sessions GROUP BY Study_Session__c
            ]) totals.put((Id) ar.get('sid'), (Integer) ar.get('n'));
            for (AggregateResult ar : [
                SELECT Study_Session__c sid, COUNT(Id) n FROM Answer__c
                WHERE Study_Session__c IN :sessions AND Is_Correct__c = true GROUP BY Study_Session__c
            ]) rights.put((Id) ar.get('sid'), (Integer) ar.get('n'));

            Set<Id> certIds = new Set<Id>();
            for (Study_Session__c s : sessions) certIds.addAll(idsIn(s.Cert_Codes__c));
            Map<Id, Cert__c> certs = new Map<Id, Cert__c>([
                SELECT Id, Name, Passing_Score__c FROM Cert__c WHERE Id IN :certIds
            ]);

            for (Study_Session__c s : sessions) {
                Integer answered = totals.containsKey(s.Id) ? totals.get(s.Id) : 0;
                Boolean active = s.Status__c == CertStudyService.ACTIVE;
                Boolean isTest = CertStudyService.isTest(s);
                if (answered == 0 && !active && !isTest) continue; // empty practice sessions are noise
                HistorySession hs = new HistorySession();
                hs.id = s.Id;
                hs.isTest = isTest;
                hs.startedAt = s.Started_At__c;
                hs.active = active;
                hs.answered = answered;
                hs.correct = rights.containsKey(s.Id) ? rights.get(s.Id) : 0;
                hs.pct = CertStudyService.pct(hs.correct, hs.answered);
                List<String> names = new List<String>();
                Decimal passing = null;
                for (Id cid : idsIn(s.Cert_Codes__c)) {
                    if (certs.containsKey(cid)) {
                        names.add(certs.get(cid).Name);
                        passing = certs.get(cid).Passing_Score__c;
                    }
                }
                names.sort();
                hs.certNames = String.join(names, ', ');
                if (isTest) {
                    hs.target = s.Question_Target__c == null ? answered : s.Question_Target__c.intValue();
                    hs.officialPct = CertStudyService.pct(hs.correct, hs.target > 0 ? hs.target : hs.answered);
                    Integer passMark = passing == null ? CertStudyService.DEFAULT_PASSING_SCORE : passing.intValue();
                    hs.passed = hs.officialPct >= passMark;
                    hs.completed = !active;
                    if (hs.completed) {
                        h.testsTaken++;
                        if (hs.passed) h.testsPassed++;
                    }
                }
                h.sessions.add(hs);
            }
            h.sessionsCount = h.sessions.size();

            // all-time by cert / section
            Map<String, HistoryArea> areas = new Map<String, HistoryArea>();
            for (AggregateResult ar : [
                SELECT Question__r.Cert__r.Name cn, Question__r.Domain__c dn, COUNT(Id) n FROM Answer__c
                WHERE Study_Session__r.User_Key__c = :key
                GROUP BY Question__r.Cert__r.Name, Question__r.Domain__c
            ]) {
                HistoryArea a = new HistoryArea();
                String cn = (String) ar.get('cn');
                String dn = (String) ar.get('dn');
                a.label = cn + (String.isBlank(dn) ? '' : ' / ' + dn);
                a.total = (Integer) ar.get('n');
                a.correct = 0;
                areas.put(cn + '|' + dn, a);
                h.totalAnswered += a.total;
            }
            for (AggregateResult ar : [
                SELECT Question__r.Cert__r.Name cn, Question__r.Domain__c dn, COUNT(Id) n FROM Answer__c
                WHERE Study_Session__r.User_Key__c = :key AND Is_Correct__c = true
                GROUP BY Question__r.Cert__r.Name, Question__r.Domain__c
            ]) {
                HistoryArea a = areas.get((String) ar.get('cn') + '|' + (String) ar.get('dn'));
                if (a != null) a.correct = (Integer) ar.get('n');
                h.totalCorrect += (Integer) ar.get('n');
            }
            h.overallPct = CertStudyService.pct(h.totalCorrect, h.totalAnswered);
            Map<String, HistoryArea> sorted = new Map<String, HistoryArea>();
            for (String k : areas.keySet()) {
                HistoryArea a = areas.get(k);
                if (a.total < WEAK_AREA_MIN_ANSWERS) continue;
                a.pct = CertStudyService.pct(a.correct, a.total);
                // weakest first; among equals, the one with more evidence first
                sorted.put(String.valueOf(a.pct).leftPad(3, '0') + '|' + String.valueOf(100000 - a.total).leftPad(6, '0') + '|' + k, a);
            }
            List<String> keys = new List<String>(sorted.keySet());
            keys.sort();
            for (String k : keys) {
                if (h.weakAreas.size() >= WEAK_AREAS_SHOWN) break;
                h.weakAreas.add(sorted.get(k));
            }
            return h;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** Re-opens one of the learner's own past sessions (practice summary or test result). */
    @AuraEnabled
    public static DetailView getSessionDetail(Id sessionId) {
        try {
            String key = CertStudyService.resolveUserKey(null);
            DetailView d = new DetailView();
            List<Study_Session__c> rows = [
                SELECT Id, Cert_Codes__c, Status__c, Started_At__c, Mode__c, Question_Target__c, Timer_Mode__c,
                    Time_Limit_Min__c, Elapsed_Seconds__c, Resumed_At__c, Paused__c, Completed_At__c
                FROM Study_Session__c WHERE Id = :sessionId AND User_Key__c = :key
            ];
            if (rows.isEmpty()) {
                d.error = 'That session was not found.';
                return d;
            }
            Study_Session__c s = rows[0];
            if (CertStudyService.isTest(s)) {
                if (s.Status__c == CertStudyService.ACTIVE) {
                    d.error = 'This test is still in progress -- results appear when it ends.';
                    return d;
                }
                d.test = toResultView(CertStudyService.testResult(s));
            } else {
                d.practice = toSummaryView(CertStudyService.summaryCore(s, false));
            }
            return d;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    private static Set<Id> idsIn(String delimited) {
        Set<Id> out = new Set<Id>();
        if (String.isBlank(delimited)) return out;
        for (String part : delimited.split(';')) {
            if (String.isNotBlank(part)) {
                try {
                    out.add(Id.valueOf(part.trim()));
                } catch (Exception e) {
                    continue; // legacy rows that stored names
                }
            }
        }
        return out;
    }

    // ------------------------------------------------------------- test mode

    @AuraEnabled
    public static SessionView startTest(String certCode, Boolean strictTimer) {
        try {
            CertStudyService.StartOutcome res = CertStudyService.startTestCore(
                CertStudyService.resolveUserKey(null), certCode, strictTimer
            );
            SessionView v = new SessionView();
            if (res.error != null) {
                v.error = res.error;
                return v;
            }
            fillSession(v, res.session, true);
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** Records the answer without revealing correctness; returns the next question, or the result when done. */
    @AuraEnabled
    public static SessionView submitTestAnswer(List<String> letters) {
        try {
            Study_Session__c s = CertStudyService.activeSession(CertStudyService.resolveUserKey(null));
            SessionView v = new SessionView();
            if (s == null || !CertStudyService.isTest(s)) return v;
            if (!CertStudyService.isTimeUp(s)) {
                List<String> chosen = new List<String>();
                for (String l : letters == null ? new List<String>() : letters) {
                    if (String.isNotBlank(l)) chosen.add(l.trim().toUpperCase());
                }
                chosen.sort();
                CertStudyService.GradeOutcome g = CertStudyService.gradeCore(s, chosen, false);
                if (g.status == 'invalid') v.error = 'Please pick the required number of options.';
            }
            fillSession(v, s, true);
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    @AuraEnabled
    public static SessionView pauseTest() {
        try {
            Study_Session__c s = CertStudyService.activeSession(CertStudyService.resolveUserKey(null));
            SessionView v = new SessionView();
            if (s == null || !CertStudyService.isTest(s)) return v;
            CertStudyService.pauseTest(s);
            fillSession(v, s, false);
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    @AuraEnabled
    public static SessionView resumeTest() {
        try {
            Study_Session__c s = CertStudyService.activeSession(CertStudyService.resolveUserKey(null));
            SessionView v = new SessionView();
            if (s == null || !CertStudyService.isTest(s)) return v;
            CertStudyService.resumeTest(s);
            fillSession(v, s, true);
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    /** Learner ends the test (early or when the strict timer hits zero). */
    @AuraEnabled
    public static SessionView finishTest() {
        try {
            Study_Session__c s = CertStudyService.activeSession(CertStudyService.resolveUserKey(null));
            SessionView v = new SessionView();
            if (s == null || !CertStudyService.isTest(s)) return v;
            v.isTest = true;
            v.testResult = toResultView(CertStudyService.finishTest(s, CertStudyService.isTimeUp(s)));
            return v;
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    // --------------------------------------------------------------- helpers

    private static void fillSession(SessionView v, Study_Session__c s, Boolean claimIfNeeded) {
        v.hasActiveSession = true;
        // Counted in the without-sharing service: external users can't see Answer__c rows directly.
        Integer[] counts = CertStudyService.answerCounts(s.Id);
        v.answered = counts[0];
        v.correct = counts[1];
        if (CertStudyService.isTest(s)) {
            fillTest(v, s);
            return;
        }
        Set<String> codes = CertStudyService.sessionCodes(s);
        for (Cert__c c : [
            SELECT Name, Is_Aggregate__c, Num_Questions__c, Duration_Min__c, Passing_Score__c, Domains_JSON__c
            FROM Cert__c WHERE Cert_Code__c IN :codes ORDER BY Name
        ]) {
            CertOverview o = new CertOverview();
            o.name = c.Name;
            o.isAggregate = c.Is_Aggregate__c;
            o.numQuestions = c.Num_Questions__c == null ? null : c.Num_Questions__c.intValue();
            o.durationMin = c.Duration_Min__c == null ? null : c.Duration_Min__c.intValue();
            o.passingScore = c.Passing_Score__c == null ? null : c.Passing_Score__c.intValue();
            List<String> doms = new List<String>();
            for (Map<String, Object> d : CertStudyGenerator.domains(c)) {
                doms.add(String.valueOf(d.get('name')) + (d.get('weight_pct') != null ? ' (' + String.valueOf(d.get('weight_pct')) + '%)' : ''));
            }
            o.domains = String.join(doms, ' · ');
            v.certs.add(o);
        }
        Question__c q = claimIfNeeded ? CertStudyService.nextQuestionRecord(s) : currentOnly(s.Id);
        if (q != null) v.question = toView(q, v.answered + 1, new Set<String>(), false);
    }

    private static void fillTest(SessionView v, Study_Session__c s) {
        v.isTest = true;
        v.correct = null; // never reveal the running score during a test
        v.strictTimer = s.Timer_Mode__c == 'Strict';
        v.timeLimitMin = s.Time_Limit_Min__c == null ? null : s.Time_Limit_Min__c.intValue();
        v.questionTarget = s.Question_Target__c == null ? null : s.Question_Target__c.intValue();
        Boolean timeUp = CertStudyService.isTimeUp(s);
        if (timeUp || (v.questionTarget != null && v.answered >= v.questionTarget)) {
            v.hasActiveSession = false;
            v.testResult = toResultView(CertStudyService.finishTest(s, timeUp));
            return;
        }
        Set<String> testCodes = CertStudyService.sessionCodes(s);
        for (Cert__c c : [
            SELECT Name, Is_Aggregate__c, Num_Questions__c, Duration_Min__c, Passing_Score__c, Domains_JSON__c
            FROM Cert__c WHERE Cert_Code__c IN :testCodes
        ]) {
            CertOverview o = new CertOverview();
            o.name = c.Name;
            o.isAggregate = c.Is_Aggregate__c;
            o.numQuestions = v.questionTarget;
            o.durationMin = v.timeLimitMin;
            o.passingScore = c.Passing_Score__c == null ? null : c.Passing_Score__c.intValue();
            v.certs.add(o);
        }
        v.isPaused = s.Paused__c == true;
        Question__c q = CertStudyService.testQuestion(s, v.answered);
        if (q != null) v.question = toView(q, v.answered + 1, new Set<String>(), false);
        v.elapsedSeconds = CertStudyService.elapsedSeconds(s);
        v.clockRunning = s.Resumed_At__c != null;
    }

    private static TestResultView toResultView(CertStudyService.TestResult r) {
        TestResultView t = new TestResultView();
        t.certName = r.cert == null ? '' : r.cert.Name;
        t.passed = r.passed;
        t.officialPct = r.officialPct;
        t.passing = r.passing;
        t.passingEstimated = r.passingEstimated;
        t.correct = r.correct;
        t.target = r.target;
        t.answered = r.answered;
        t.unanswered = r.unanswered;
        t.answeredPct = r.answeredPct;
        t.answeredLikelyPass = r.answeredLikelyPass;
        t.incomplete = r.incomplete;
        t.timedOut = r.timedOut;
        t.elapsedSeconds = r.elapsedSeconds;
        t.limitMin = r.limitMin;
        t.strictTimer = r.strictTimer;
        for (CertStudyService.DomainResult d : r.domains) {
            DomainView dv = new DomainView();
            dv.name = d.name;
            dv.weight = d.weight;
            dv.quota = d.quota;
            dv.answered = d.answered;
            dv.correct = d.correct;
            dv.pct = d.pctOfAnswered();
            dv.likelyPass = d.answered > 0 && dv.pct >= r.passing;
            t.domains.add(dv);
        }
        t.recommendations = r.recommendations;
        for (Answer__c a : r.missed) {
            MissedView m = new MissedView();
            m.stem = a.Question__r.Stem__c;
            m.correctAnswer = describe(a.Question__r.Options_JSON__c, a.Question__r.Correct_JSON__c);
            m.yourAnswer = a.User_Answer__c;
            m.feedback = a.Question__r.Feedback_MD__c;
            t.missed.add(m);
        }
        return t;
    }

    private static Question__c currentOnly(Id sessionId) {
        List<Question__c> rows = [
            SELECT Id, Stem__c, Options_JSON__c, Correct_JSON__c, Feedback_MD__c, Domain__c,
                Difficulty__c, Format__c, Cert__c, Cert__r.Name
            FROM Question__c
            WHERE Study_Session__c = :sessionId AND Status__c = 'Served'
            ORDER BY Served_At__c DESC LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** revealAnswers=false never sends correct flags or explanations to the browser. */
    private static QuestionView toView(Question__c q, Integer questionNumber, Set<String> chosen, Boolean revealAnswers) {
        QuestionView v = new QuestionView();
        v.id = q.Id;
        v.questionNumber = questionNumber;
        v.certName = q.Cert__r.Name;
        v.domain = q.Domain__c;
        v.difficulty = q.Difficulty__c == null ? null : q.Difficulty__c.intValue();
        v.stem = q.Stem__c;
        List<String> correct = CertStudyService.correctKeys(q);
        v.chooseCount = correct.size();
        Map<String, String> explanations = revealAnswers ? splitFeedback(q.Feedback_MD__c) : new Map<String, String>();
        Set<String> correctSet = new Set<String>(correct);
        for (Map<String, String> o : CertStudyService.options(q)) {
            OptionView ov = new OptionView();
            ov.key = o.get('key');
            ov.text = o.get('text');
            if (revealAnswers) {
                ov.isCorrect = correctSet.contains(ov.key);
                ov.wasChosen = chosen.contains(ov.key);
                ov.explanation = explanations.get(ov.key);
            }
            v.options.add(ov);
        }
        return v;
    }

    /**
     * Feedback_MD__c is built by CertStudyGenerator as blocks of
     * "**A. option text** -- Correct: explanation" separated by blank lines.
     * Returns key -> explanation; empty if the format doesn't match.
     */
    @TestVisible
    private static Map<String, String> splitFeedback(String feedback) {
        Map<String, String> out = new Map<String, String>();
        if (String.isBlank(feedback)) return out;
        Pattern p = Pattern.compile('(?s)^\\*\\*([A-E])\\..*?\\*\\*\\s*--\\s*(?:Correct|Incorrect):\\s*(.*)$');
        for (String block : feedback.split('\n\n')) {
            Matcher m = p.matcher(block.trim());
            if (m.matches()) out.put(m.group(1), m.group(2).trim());
        }
        return out;
    }

    private static String describe(String optionsJson, String correctJson) {
        Question__c tmp = new Question__c(Options_JSON__c = optionsJson, Correct_JSON__c = correctJson);
        Map<String, String> textByKey = new Map<String, String>();
        for (Map<String, String> o : CertStudyService.options(tmp)) textByKey.put(o.get('key'), o.get('text'));
        List<String> parts = new List<String>();
        for (String k : CertStudyService.correctKeys(tmp)) parts.add(k + '. ' + textByKey.get(k));
        return String.join(parts, '; ');
    }

    private static AuraHandledException wrap(Exception e) {
        AuraHandledException ex = new AuraHandledException(e.getMessage());
        ex.setMessage(e.getMessage());
        return ex;
    }
}
