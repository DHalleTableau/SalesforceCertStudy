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

    public class SessionView {
        @AuraEnabled public Boolean hasActiveSession = false;
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
        @AuraEnabled public Boolean hasSession = false;
        @AuraEnabled public Boolean sessionActive = false;
        @AuraEnabled public Integer answered = 0;
        @AuraEnabled public Integer correct = 0;
        @AuraEnabled public Integer pct = 0;
        @AuraEnabled public List<AreaView> areas = new List<AreaView>();
        @AuraEnabled public List<MissedView> missed = new List<MissedView>();
    }

    // --------------------------------------------------------------- methods

    @AuraEnabled
    public static List<CertOption> listCerts() {
        List<CertOption> out = new List<CertOption>();
        for (Cert__c c : [
            SELECT Name, Cert_Code__c, Is_Aggregate__c, Grounding_Chars__c
            FROM Cert__c ORDER BY Name LIMIT 500
        ]) {
            if (!(c.Is_Aggregate__c || (c.Grounding_Chars__c != null && c.Grounding_Chars__c > 0))) continue;
            CertOption o = new CertOption();
            o.code = c.Cert_Code__c;
            o.name = c.Name;
            o.isAggregate = c.Is_Aggregate__c;
            out.add(o);
        }
        return out;
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
            CertStudyService.SummaryData d = CertStudyService.summaryCore(s, endSession == true);
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
        } catch (Exception e) {
            throw wrap(e);
        }
    }

    // --------------------------------------------------------------- helpers

    private static void fillSession(SessionView v, Study_Session__c s, Boolean claimIfNeeded) {
        v.hasActiveSession = true;
        v.answered = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id];
        v.correct = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id AND Is_Correct__c = true];
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
