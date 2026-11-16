/**
 * Learner-facing logic behind the agent actions: cert lookup, session
 * setup (aggregate/prerequisite resolution, port of cert_resolution.py),
 * serving pre-generated questions, deterministic grading, and summaries.
 *
 * No model calls happen here -- serving and grading are plain Apex, so an
 * agent turn costs no generation credits. Generation runs in
 * CertStudyPoolJob.
 *
 * Every method returns a ready-to-show markdown message; the agent is
 * instructed to relay it verbatim. Learners are identified by userKey
 * (defaults to the running user's email; a Slack ID also works), not by
 * Salesforce user, so the same logic works for any future interface.
 *
 * Runs without sharing: the question pool is shared across learners.
 */
public without sharing class CertStudyService {
    public class ServiceException extends Exception {}

    public static final String ACTIVE = 'Active';
    public static final String ENDED = 'Ended';
    /** Agents sometimes re-call SubmitAnswer in one turn; identical answers this close together are ignored. */
    public static final Integer DUPLICATE_WINDOW_SECONDS = 10;
    public static final String DUPLICATE_PREFIX = 'DUPLICATE_IGNORED';
    public static final String MODE_PRACTICE = 'Practice';
    public static final String MODE_TEST = 'Test';
    /** Ready questions kept per cert; larger while someone is taking a test on it. */
    public static final Integer TEST_POOL_TARGET = 10;
    public static final Integer DEFAULT_TEST_QUESTIONS = 60;
    /** Like the real exam, a test delivers this many extra questions that do not count toward the score. */
    public static final Integer UNSCORED_PER_TEST = 5;
    @TestVisible private static Integer unscoredExtra = UNSCORED_PER_TEST; // tests with tiny exams set 0
    public static final Integer DEFAULT_TEST_MINUTES = 105;
    public static final Integer DEFAULT_PASSING_SCORE = 65;
    public static final Integer MAX_RECOMMENDATIONS = 5;

    // ------------------------------------------------------------- identity

    /**
     * Learner identity. Blank = the logged-in Salesforce user's 18-character Id
     * (unique per person, including Experience Cloud users; emails are NOT unique
     * in Salesforce -- e.g. agent users all share noreply@salesforce.com).
     * A supplied key (e.g. the agent's EndUserId or a Slack user Id) is used as-is.
     */
    public static String resolveUserKey(String userKey) {
        if (String.isBlank(userKey)) return UserInfo.getUserId();
        return userKey.trim();
    }

    /** User__c lookup value for a session: set when the key is the running user's Id. */
    public static Id userIdFor(String key) {
        return key == UserInfo.getUserId() ? UserInfo.getUserId() : null;
    }

    // ---------------------------------------------------------------- certs

    /** Certs with study material loaded (or aggregates), for the Lightning/site cert picker. */
    public static List<Cert__c> usableCerts() {
        List<Cert__c> out = new List<Cert__c>();
        for (Cert__c c : [
            SELECT Name, Cert_Code__c, Is_Aggregate__c, Grounding_Chars__c,
                Exam_Status__c, Retires_On__c, Path_Forward__c
            FROM Cert__c ORDER BY Name LIMIT 500
        ]) {
            if (c.Is_Aggregate__c || (c.Grounding_Chars__c != null && c.Grounding_Chars__c > 0)) out.add(c);
        }
        return out;
    }

    // --------------------------------------------- certifications a learner has earned

    /** Cert codes this user has marked as earned (self-reported now; Trailhead sync may add rows later). */
    public static List<String> earnedCertCodes(Id userId) {
        List<String> codes = new List<String>();
        for (User_Cert__c uc : [
            SELECT Cert__r.Cert_Code__c FROM User_Cert__c
            WHERE User__c = :userId AND Cert__c != null
        ]) {
            if (uc.Cert__r != null && uc.Cert__r.Cert_Code__c != null) codes.add(uc.Cert__r.Cert_Code__c);
        }
        return codes;
    }

    /** Mark a cert earned (one row per user + cert) or remove the mark. Returns the user's earned codes. */
    public static List<String> setEarned(Id userId, String certCode, Boolean earned) {
        if (String.isBlank(certCode)) throw new ServiceException('Pick a certification.');
        List<Cert__c> certs = [SELECT Id FROM Cert__c WHERE Cert_Code__c = :certCode LIMIT 1];
        if (certs.isEmpty()) throw new ServiceException('That certification was not found.');
        String key = String.valueOf(userId) + ':' + String.valueOf(certs[0].Id);
        if (earned == true) {
            upsert new User_Cert__c(
                Unique_Key__c = key, User__c = userId, Cert__c = certs[0].Id, Source__c = 'Self-reported'
            ) User_Cert__c.Unique_Key__c;
        } else {
            delete [SELECT Id FROM User_Cert__c WHERE Unique_Key__c = :key];
        }
        if (earned == true) closeOpenGoals(userId, certs[0].Id, GOAL_PASSED);
        return earnedCertCodes(userId);
    }

    // ------------------------------------------- study goals (upcoming exams)

    public static final String GOAL_STUDYING = 'Studying';
    public static final String GOAL_PASSED = 'Passed';
    public static final String GOAL_NOT_PASSED = 'Not passed';
    public static final String GOAL_DROPPED = 'Dropped';
    public static final Integer MAX_OPEN_GOALS = 10;

    public class GoalRow {
        public Id id;
        public String certCode;
        public String certName;
        public Date examDate;      // null = no date set
        public Boolean overdue;    // the exam date has passed and no outcome is recorded yet
    }

    /** The learner's open goals: dated ones soonest first, then undated by cert name. */
    public static List<GoalRow> openGoals(Id userId) {
        List<GoalRow> out = new List<GoalRow>();
        Date today = Date.today();
        for (Study_Goal__c g : [
            SELECT Id, Exam_Date__c, Cert__r.Cert_Code__c, Cert__r.Name
            FROM Study_Goal__c
            WHERE User__c = :userId AND Status__c = :GOAL_STUDYING AND Cert__c != null
            ORDER BY Exam_Date__c ASC NULLS LAST, Cert__r.Name ASC
        ]) {
            GoalRow r = new GoalRow();
            r.id = g.Id;
            r.certCode = g.Cert__r.Cert_Code__c;
            r.certName = g.Cert__r.Name;
            r.examDate = g.Exam_Date__c;
            r.overdue = g.Exam_Date__c != null && g.Exam_Date__c < today;
            out.add(r);
        }
        return out;
    }

    /** Add a cert to "studying for", or change the date of the open goal already there (null clears the date). */
    public static List<GoalRow> saveGoal(Id userId, String certCode, Date examDate) {
        if (String.isBlank(certCode)) throw new ServiceException('Pick a certification.');
        List<Cert__c> certs = [SELECT Id, Is_Aggregate__c FROM Cert__c WHERE Cert_Code__c = :certCode LIMIT 1];
        if (certs.isEmpty()) throw new ServiceException('That certification was not found.');
        if (certs[0].Is_Aggregate__c == true) {
            throw new ServiceException('That credential has no exam of its own. Pick one of its individual exams.');
        }
        List<Study_Goal__c> existing = [
            SELECT Id FROM Study_Goal__c
            WHERE User__c = :userId AND Cert__c = :certs[0].Id AND Status__c = :GOAL_STUDYING
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            existing[0].Exam_Date__c = examDate;
            update existing[0];
        } else {
            Integer open = [SELECT COUNT() FROM Study_Goal__c WHERE User__c = :userId AND Status__c = :GOAL_STUDYING];
            if (open >= MAX_OPEN_GOALS) {
                throw new ServiceException('You can track up to ' + MAX_OPEN_GOALS + ' upcoming exams. Remove one first.');
            }
            insert new Study_Goal__c(
                User__c = userId, Cert__c = certs[0].Id, Exam_Date__c = examDate, Status__c = GOAL_STUDYING
            );
        }
        return openGoals(userId);
    }

    private static Study_Goal__c ownOpenGoal(Id userId, String goalId) {
        return ownGoal(userId, goalId, GOAL_STUDYING);
    }

    private static Study_Goal__c ownGoal(Id userId, String goalId, String status) {
        if (String.isBlank(goalId)) throw new ServiceException('That exam was not found.');
        Id gid;
        try {
            gid = Id.valueOf(goalId);
        } catch (Exception e) {
            throw new ServiceException('That exam was not found.');
        }
        List<Study_Goal__c> rows = [
            SELECT Id, Cert__c, Section_Scores_JSON__c FROM Study_Goal__c
            WHERE Id = :gid AND User__c = :userId AND Status__c = :status
        ];
        if (rows.isEmpty()) throw new ServiceException('That exam was not found.');
        return rows[0];
    }

    /** The learner stops tracking this exam (kept as Dropped, not deleted). */
    public static List<GoalRow> removeGoal(Id userId, String goalId) {
        Study_Goal__c g = ownOpenGoal(userId, goalId);
        g.Status__c = GOAL_DROPPED;
        update g;
        return openGoals(userId);
    }

    /**
     * After the exam date: record whether the learner passed. Passed also marks the cert as earned
     * (which feeds Hide earned and Up next). Not passed keeps the goal's history; the learner can add
     * the cert again with a new date for a retake.
     */
    public static List<GoalRow> recordOutcome(Id userId, String goalId, Boolean passed) {
        Study_Goal__c g = ownOpenGoal(userId, goalId);
        g.Status__c = passed == true ? GOAL_PASSED : GOAL_NOT_PASSED;
        g.Outcome_Recorded_On__c = Date.today();
        update g;
        if (passed == true) {
            List<Cert__c> certs = [SELECT Cert_Code__c FROM Cert__c WHERE Id = :g.Cert__c LIMIT 1];
            if (!certs.isEmpty()) setEarned(userId, certs[0].Cert_Code__c, true);
        }
        return openGoals(userId);
    }

    /** Marking a cert earned elsewhere also settles any open goal for it. */
    private static void closeOpenGoals(Id userId, Id certId, String status) {
        List<Study_Goal__c> open = [
            SELECT Id FROM Study_Goal__c
            WHERE User__c = :userId AND Cert__c = :certId AND Status__c = :GOAL_STUDYING
        ];
        for (Study_Goal__c g : open) {
            g.Status__c = status;
            g.Outcome_Recorded_On__c = Date.today();
        }
        if (!open.isEmpty()) update open;
    }

    // ---------------------------------------------- completed exams (history)

    public class ExamRow {
        public Id id;
        public String certCode;
        public String certName;
        public Date examDate;
        public Date outcomeOn;
        public String status;       // Passed, Not passed or Dropped
        public Boolean hasScores;
    }

    /** Exams that are no longer open (passed, not passed, dropped), newest first. Never deleted, so always reachable. */
    public static List<ExamRow> examHistory(Id userId) {
        List<ExamRow> out = new List<ExamRow>();
        for (Study_Goal__c g : [
            SELECT Id, Exam_Date__c, Outcome_Recorded_On__c, Status__c, Section_Scores_JSON__c,
                Cert__r.Cert_Code__c, Cert__r.Name
            FROM Study_Goal__c
            WHERE User__c = :userId AND Status__c != :GOAL_STUDYING AND Cert__c != null
            ORDER BY Outcome_Recorded_On__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 200
        ]) {
            ExamRow r = new ExamRow();
            r.id = g.Id;
            r.certCode = g.Cert__r.Cert_Code__c;
            r.certName = g.Cert__r.Name;
            r.examDate = g.Exam_Date__c;
            r.outcomeOn = g.Outcome_Recorded_On__c;
            r.status = g.Status__c;
            r.hasScores = String.isNotBlank(g.Section_Scores_JSON__c);
            out.add(r);
        }
        return out;
    }

    /**
     * Record an exam attempt that already happened (for example an earlier failure) without going through
     * "studying for". The exam date is when it was taken (today if blank, never in the future) and becomes
     * the outcome date, so attempts sort in the order they happened. Passed also marks the cert earned.
     * Returns the new record's Id.
     */
    public static Id addPastExam(Id userId, String certCode, Date examDate, Boolean passed) {
        if (String.isBlank(certCode)) throw new ServiceException('Pick a certification.');
        List<Cert__c> certs = [SELECT Id, Is_Aggregate__c FROM Cert__c WHERE Cert_Code__c = :certCode LIMIT 1];
        if (certs.isEmpty()) throw new ServiceException('That certification was not found.');
        if (certs[0].Is_Aggregate__c == true) {
            throw new ServiceException('That credential has no exam of its own. Pick one of its individual exams.');
        }
        Date taken = examDate == null ? Date.today() : examDate;
        if (taken > Date.today()) {
            throw new ServiceException('A past attempt cannot have a future date. Add upcoming exams under "Add an exam".');
        }
        Study_Goal__c g = new Study_Goal__c(
            User__c = userId, Cert__c = certs[0].Id, Exam_Date__c = taken, Outcome_Recorded_On__c = taken,
            Status__c = passed == true ? GOAL_PASSED : GOAL_NOT_PASSED
        );
        insert g;
        if (passed == true) setEarned(userId, certCode, true);
        return g.Id;
    }

    /**
     * Permanently deletes one completed exam record (passed, not passed or dropped), including any section scores.
     * Open exams use removeGoal instead. Deleting a Passed record does not un-earn the certification.
     */
    public static List<ExamRow> deleteCompletedExam(Id userId, String goalId) {
        Id gid;
        try {
            gid = Id.valueOf(goalId);
        } catch (Exception e) {
            throw new ServiceException('That exam was not found.');
        }
        List<Study_Goal__c> rows = [
            SELECT Id FROM Study_Goal__c WHERE Id = :gid AND User__c = :userId AND Status__c != :GOAL_STUDYING
        ];
        if (rows.isEmpty()) throw new ServiceException('That exam was not found.');
        delete rows;
        return examHistory(userId);
    }

    /** Previously saved section scores for a "Not passed" exam, ready to review and edit (rows empty if none). */
    public static ScorePreview savedScores(Id userId, String goalId) {
        Study_Goal__c g = ownGoal(userId, goalId, GOAL_NOT_PASSED);
        Cert__c c = [SELECT Name, Passing_Score__c, Domains_JSON__c FROM Cert__c WHERE Id = :g.Cert__c];
        ScorePreview out = new ScorePreview();
        out.certName = c.Name;
        out.passingEstimated = c.Passing_Score__c == null;
        out.passingScore = (c.Passing_Score__c == null ? EXAM_DEFAULT_PASS : c.Passing_Score__c).intValue();
        out.domains = domainNames(c);
        if (String.isNotBlank(g.Section_Scores_JSON__c)) {
            try {
                for (Object o : (List<Object>) JSON.deserializeUntyped(g.Section_Scores_JSON__c)) {
                    Map<String, Object> m = (Map<String, Object>) o;
                    ScoreRow r = new ScoreRow();
                    r.name = (String) m.get('name');
                    r.pct = Decimal.valueOf(String.valueOf(m.get('pct')));
                    r.domain = (String) m.get('domain');
                    // A section renamed since saving no longer matches: leave it unmatched for the learner to fix.
                    if (r.domain != null && !out.domains.contains(r.domain)) r.domain = matchDomain(r.name, out.domains);
                    out.rows.add(r);
                }
            } catch (Exception e) {
                out.rows = new List<ScoreRow>();
            }
        }
        return out;
    }

    // -------------------------------- exam section scores (after a failed exam)

    public static final Decimal EXAM_DEFAULT_PASS = 70;
    /** Weight for a section at or above the pass mark: asked about half as often as normal. */
    public static final Decimal EXAM_PASSED_WEIGHT = 0.5;
    /** Points below the pass mark at which a section reaches the maximum weight. */
    public static final Decimal EXAM_FULL_GAP = 25;
    private static final Set<String> SCORE_STOP_WORDS = new Set<String>{ 'and', 'the', 'of', 'a', 'an', 'for', 'to', 'in' };

    public class ScoreRow {
        public String name;    // the exam report's own section name
        public Decimal pct;
        public String domain;  // the app's matching section, or blank
    }

    public class ScorePreview {
        public String certName;
        public Integer passingScore;
        public Boolean passingEstimated = false;
        public List<String> domains = new List<String>();
        public List<ScoreRow> rows = new List<ScoreRow>();
    }

    public class ExamFocusRow {
        public String certCode;
        public String certName;
        public Date recordedOn;
    }

    /** Reads lines like "Prompt Engineering: 83%" (also "Name 83%" or "Name - 83 %"); anything else is ignored. */
    public static List<ScoreRow> parseSectionScores(String text) {
        List<ScoreRow> out = new List<ScoreRow>();
        if (String.isBlank(text)) return out;
        Pattern p = Pattern.compile('^\\s*(.+?)\\s*[:\\-\\t]?\\s*(\\d{1,3}(?:\\.\\d+)?)\\s*%\\s*$');
        for (String line : text.split('\n')) {
            Matcher m = p.matcher(line.trim());
            if (!m.matches()) continue;
            Decimal pct = Decimal.valueOf(m.group(2));
            if (pct > 100) continue;
            String name = m.group(1).trim();
            while (name.length() > 0 && (name.endsWith(':') || name.endsWith('-'))) {
                name = name.substring(0, name.length() - 1).trim();
            }
            if (String.isBlank(name)) continue;
            ScoreRow r = new ScoreRow();
            r.name = name;
            r.pct = pct;
            out.add(r);
        }
        return out;
    }

    private static String normName(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('[^a-z0-9]+', ' ').trim();
    }

    private static Set<String> nameTokens(String normalized) {
        Set<String> out = new Set<String>();
        for (String t : normalized.split(' ')) {
            if (String.isNotBlank(t) && !SCORE_STOP_WORDS.contains(t)) out.add(t);
        }
        return out;
    }

    /** The app section that best matches an exam section name, or null when nothing matches clearly. */
    public static String matchDomain(String sectionName, List<String> domains) {
        String n = normName(sectionName);
        if (n == '' || domains == null) return null;
        for (String d : domains) if (normName(d) == n) return d;
        List<String> hits = new List<String>();
        for (String d : domains) {
            String nd = normName(d);
            if (nd != '' && (nd.contains(n) || n.contains(nd))) hits.add(d);
        }
        if (hits.size() == 1) return hits[0];
        Set<String> a = nameTokens(n);
        String best = null;
        Decimal bestScore = 0;
        Boolean tied = false;
        for (String d : domains) {
            Set<String> b = nameTokens(normName(d));
            if (a.isEmpty() || b.isEmpty()) continue;
            Set<String> both = a.clone();
            both.retainAll(b);
            Set<String> either = a.clone();
            either.addAll(b);
            Decimal score = Decimal.valueOf(both.size()) / either.size();
            if (score > bestScore) {
                bestScore = score;
                best = d;
                tied = false;
            } else if (score == bestScore && score > 0) {
                tied = true;
            }
        }
        return (best != null && bestScore >= 0.5 && !tied) ? best : null;
    }

    private static List<String> domainNames(Cert__c c) {
        List<String> names = new List<String>();
        for (Map<String, Object> d : CertStudyGenerator.domains(c)) names.add(String.valueOf(d.get('name')));
        return names;
    }

    /** Parse pasted results and suggest a section match for each line. The goal must be a recorded "Not passed". */
    public static ScorePreview previewScores(Id userId, String goalId, String text) {
        Study_Goal__c g = ownGoal(userId, goalId, GOAL_NOT_PASSED);
        Cert__c c = [SELECT Name, Passing_Score__c, Domains_JSON__c FROM Cert__c WHERE Id = :g.Cert__c];
        ScorePreview out = new ScorePreview();
        out.certName = c.Name;
        out.passingEstimated = c.Passing_Score__c == null;
        out.passingScore = (c.Passing_Score__c == null ? EXAM_DEFAULT_PASS : c.Passing_Score__c).intValue();
        out.domains = domainNames(c);
        out.rows = parseSectionScores(text);
        for (ScoreRow r : out.rows) r.domain = matchDomain(r.name, out.domains);
        return out;
    }

    /**
     * Save the confirmed rows on the goal. Returns a one-line summary of what practice will focus on.
     * Sections left unmatched are kept for the record but do not affect weighting.
     */
    public static String saveScores(Id userId, String goalId, List<ScoreRow> rows) {
        Study_Goal__c g = ownGoal(userId, goalId, GOAL_NOT_PASSED);
        Cert__c c = [SELECT Cert_Code__c, Passing_Score__c, Domains_JSON__c FROM Cert__c WHERE Id = :g.Cert__c];
        if (rows == null || rows.isEmpty()) throw new ServiceException('Add at least one section score first.');
        Set<String> valid = new Set<String>(domainNames(c));
        List<Map<String, Object>> stored = new List<Map<String, Object>>();
        for (ScoreRow r : rows) {
            if (r.pct == null || r.pct < 0 || r.pct > 100) {
                throw new ServiceException('Scores must be between 0 and 100.');
            }
            if (String.isNotBlank(r.domain) && !valid.contains(r.domain)) {
                throw new ServiceException('"' + r.domain + '" is not a section of this exam.');
            }
            stored.add(new Map<String, Object>{
                'name' => r.name, 'pct' => r.pct, 'domain' => String.isBlank(r.domain) ? null : r.domain
            });
        }
        g.Section_Scores_JSON__c = JSON.serialize(stored);
        update g;

        Map<String, Decimal> w = weightsFromScores(g.Section_Scores_JSON__c, c.Passing_Score__c);
        List<String> weak = new List<String>();
        for (String d : w.keySet()) if (w.get(d) >= FOCUS_WEAK_WEIGHT) weak.add(d);
        weak.sort();
        return weak.isEmpty()
            ? 'Saved. None of the matched sections were below the pass mark, so practice will not change.'
            : 'Saved. Practice will focus on: ' + String.join(weak, ', ') + '. Focus on my weaker sections is on for this exam until you pass.';
    }

    /**
     * Section weights from exam results. Below the pass mark: 1.5 up to 3.0 (bigger gap, bigger weight, full at
     * 25 points under). At or above it: 0.5, so it still comes up but about half as often as a normal section.
     */
    public static Map<String, Decimal> weightsFromScores(String jsonText, Decimal passingScore) {
        Map<String, Decimal> lowest = new Map<String, Decimal>(); // domain -> weakest score listed for it
        if (String.isBlank(jsonText)) return new Map<String, Decimal>();
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(jsonText)) {
                Map<String, Object> row = (Map<String, Object>) o;
                String d = (String) row.get('domain');
                if (String.isBlank(d) || row.get('pct') == null) continue;
                Decimal pct = Decimal.valueOf(String.valueOf(row.get('pct')));
                if (!lowest.containsKey(d) || pct < lowest.get(d)) lowest.put(d, pct);
            }
        } catch (Exception e) {
            return new Map<String, Decimal>();
        }
        Decimal pass = passingScore == null ? EXAM_DEFAULT_PASS : passingScore;
        Map<String, Decimal> out = new Map<String, Decimal>();
        for (String d : lowest.keySet()) {
            Decimal pct = lowest.get(d);
            if (pct >= pass) {
                out.put(d, EXAM_PASSED_WEIGHT);
            } else {
                Decimal frac = Math.min((pass - pct) / EXAM_FULL_GAP, 1);
                out.put(d, (1.5 + 1.5 * frac).setScale(2));
            }
        }
        return out;
    }

    /** Latest failed exam with saved section scores, per cert code (null codes = all certs). Earned certs are excluded. */
    private static Map<String, Study_Goal__c> latestScoredGoals(Id userId, Set<String> codes) {
        Map<String, Study_Goal__c> latest = new Map<String, Study_Goal__c>();
        if (userId == null) return latest;
        Set<String> earned = new Set<String>(earnedCertCodes(userId));
        for (Study_Goal__c g : [
            SELECT Section_Scores_JSON__c, Outcome_Recorded_On__c, Cert__r.Cert_Code__c, Cert__r.Name, Cert__r.Passing_Score__c
            FROM Study_Goal__c
            WHERE User__c = :userId AND Status__c = :GOAL_NOT_PASSED AND Cert__c != null
            ORDER BY Outcome_Recorded_On__c DESC NULLS LAST, CreatedDate DESC
        ]) {
            String cc = g.Cert__r.Cert_Code__c;
            if (String.isBlank(g.Section_Scores_JSON__c)) continue;
            if (earned.contains(cc) || latest.containsKey(cc)) continue;
            if (codes != null && !codes.contains(cc)) continue;
            latest.put(cc, g);
        }
        return latest;
    }

    /** Per cert, per domain weights from exam results. Active until the learner passes (earns) that cert. */
    public static Map<String, Map<String, Decimal>> examWeights(Id userId, Set<String> codes) {
        Map<String, Map<String, Decimal>> out = new Map<String, Map<String, Decimal>>();
        for (Study_Goal__c g : latestScoredGoals(userId, codes).values()) {
            Map<String, Decimal> w = weightsFromScores(g.Section_Scores_JSON__c, g.Cert__r.Passing_Score__c);
            if (!w.isEmpty()) out.put(g.Cert__r.Cert_Code__c, w);
        }
        return out;
    }

    /** Certs whose practice focus currently comes from the learner's exam results (for the picker note). */
    public static List<ExamFocusRow> examFocusRows(Id userId) {
        List<ExamFocusRow> out = new List<ExamFocusRow>();
        for (Study_Goal__c g : latestScoredGoals(userId, null).values()) {
            if (weightsFromScores(g.Section_Scores_JSON__c, g.Cert__r.Passing_Score__c).isEmpty()) continue;
            ExamFocusRow r = new ExamFocusRow();
            r.certCode = g.Cert__r.Cert_Code__c;
            r.certName = g.Cert__r.Name;
            r.recordedOn = g.Outcome_Recorded_On__c;
            out.add(r);
        }
        return out;
    }

    private static Id userIdOrNull(String key) {
        try {
            Id i = Id.valueOf(key);
            return i.getSobjectType() == User.SObjectType ? i : null;
        } catch (Exception e) {
            return null;
        }
    }

    public static final Integer MAX_REPORTS_PER_HOUR = 20;
    public static final Integer MAX_REPORT_COMMENT = 2000;   // per message
    public static final Integer MAX_REPORT_THREAD = 32000;   // whole Comment__c (field holds 32,768)
    public static final Set<String> REPORT_TYPES = new Set<String>{
        'Inaccurate', 'Multiple correct answers', 'No correct answer', 'Outdated',
        'Unclear wording', 'Explanation is wrong', 'Other'
    };

    /**
     * Save a learner's report on a question they were served. The question must belong to one of the
     * learner's own sessions; reports are rate limited. A repeat report on the same question by the
     * same learner is appended to their earlier open report (original type and text are kept).
     */
    public static void reportQuestion(Id userId, String questionId, String issueType, String comment) {
        if (String.isBlank(questionId)) throw new ServiceException('Question not found.');
        if (String.isBlank(issueType) || !REPORT_TYPES.contains(issueType)) {
            throw new ServiceException('Pick the type of problem.');
        }
        String text = String.isBlank(comment) ? null : comment.trim();
        if (issueType == 'Other' && text == null) throw new ServiceException('Please describe the problem.');
        if (text != null && text.length() > MAX_REPORT_COMMENT) text = text.substring(0, MAX_REPORT_COMMENT);

        Id qid;
        try {
            qid = Id.valueOf(questionId);
        } catch (Exception e) {
            throw new ServiceException('Question not found.');
        }
        List<Question__c> qs = [
            SELECT Id, Cert__c, Study_Session__r.User_Key__c FROM Question__c WHERE Id = :qid LIMIT 1
        ];
        if (qs.isEmpty() || qs[0].Study_Session__r == null || qs[0].Study_Session__r.User_Key__c != String.valueOf(userId)) {
            throw new ServiceException('Question not found.');
        }

        DateTime since = DateTime.now().addHours(-1);
        if ([SELECT COUNT() FROM Question_Report__c WHERE Reporter__c = :userId AND Reported_At__c >= :since] >= MAX_REPORTS_PER_HOUR) {
            throw new ServiceException('You have sent a lot of reports in the last hour. Please try again later.');
        }

        List<Question_Report__c> open = [
            SELECT Id, Issue_Type__c, Comment__c FROM Question_Report__c
            WHERE Reporter__c = :userId AND Question__c = :qid AND Status__c IN ('New', 'Reviewing') LIMIT 1
        ];
        if (open.isEmpty()) {
            insert new Question_Report__c(
                Question__c = qid, Cert__c = qs[0].Cert__c, Reporter__c = userId, Status__c = 'New',
                Issue_Type__c = issueType, Comment__c = text, Reported_At__c = DateTime.now()
            );
            return;
        }
        // Same learner, same question, still open: append to the existing issue so nothing is overwritten
        // and per-cert counts stay one row per learner per question.
        Question_Report__c r = open[0];
        String entry = '[' + DateTime.now().formatGmt('yyyy-MM-dd HH:mm') + ' UTC, follow-up: ' + issueType + ']'
            + (text == null ? '' : '\n' + text);
        String combined = String.isBlank(r.Comment__c) ? entry : r.Comment__c + '\n\n' + entry;
        if (combined.length() > MAX_REPORT_THREAD) {
            throw new ServiceException('This issue already has a lot of detail. An admin will review it soon.');
        }
        update new Question_Report__c(Id = r.Id, Comment__c = combined);
    }

    // -------------------------------------------------------- study links

    public static final Integer STUDY_LINKS_PER_CERT = 3;
    public static final Integer STUDY_LINKS_MAX = 6;

    /**
     * Active study links for the given certs, up to STUDY_LINKS_PER_CERT each. Links tagged with an exam
     * section the learner scored low on come first; then by Sort Order.
     */
    public static List<Study_Link__c> studyLinksFor(Set<Id> certIds, Set<String> weakSections) {
        List<Study_Link__c> out = new List<Study_Link__c>();
        if (certIds == null || certIds.isEmpty()) return out;
        Set<String> weak = new Set<String>();
        if (weakSections != null) for (String w : weakSections) if (w != null) weak.add(w.trim().toLowerCase());
        Map<Id, List<Study_Link__c>> byCert = new Map<Id, List<Study_Link__c>>();
        for (Study_Link__c l : [
            SELECT Id, Cert__c, Cert__r.Name, Title__c, URL__c, Link_Type__c, Domain__c, Sort_Order__c
            FROM Study_Link__c
            WHERE Cert__c IN :certIds AND Active__c = true AND URL__c != null
            ORDER BY Cert__r.Name, Sort_Order__c NULLS LAST, Title__c
        ]) {
            if (!byCert.containsKey(l.Cert__c)) byCert.put(l.Cert__c, new List<Study_Link__c>());
            byCert.get(l.Cert__c).add(l);
        }
        for (List<Study_Link__c> links : byCert.values()) {
            List<Study_Link__c> first = new List<Study_Link__c>();
            List<Study_Link__c> rest = new List<Study_Link__c>();
            for (Study_Link__c l : links) {
                Boolean hit = l.Domain__c != null && weak.contains(l.Domain__c.trim().toLowerCase());
                if (hit) first.add(l);
                else rest.add(l);
            }
            first.addAll(rest);
            for (Integer i = 0; i < first.size() && i < STUDY_LINKS_PER_CERT && out.size() < STUDY_LINKS_MAX; i++) {
                out.add(first[i]);
            }
        }
        return out;
    }

    /** Remember which links a learner was shown: one row per learner + link (re-showing updates Last Suggested). */
    public static void recordSuggestedLinks(Id userId, List<Study_Link__c> links) {
        if (userId == null || links == null || links.isEmpty()) return;
        Map<String, Id> keyToLink = new Map<String, Id>();
        for (Study_Link__c l : links) keyToLink.put(String.valueOf(userId) + ':' + String.valueOf(l.Id), l.Id);
        Set<String> existing = new Set<String>();
        for (User_Study_Link__c u : [SELECT Unique_Key__c FROM User_Study_Link__c WHERE Unique_Key__c IN :keyToLink.keySet()]) {
            existing.add(u.Unique_Key__c);
        }
        DateTime now = DateTime.now();
        List<User_Study_Link__c> rows = new List<User_Study_Link__c>();
        for (String k : keyToLink.keySet()) {
            User_Study_Link__c u = new User_Study_Link__c(Unique_Key__c = k, Last_Suggested_At__c = now);
            if (!existing.contains(k)) {
                u.User__c = userId;
                u.Study_Link__c = keyToLink.get(k);
                u.First_Suggested_At__c = now;
            }
            rows.add(u);
        }
        upsert rows User_Study_Link__c.Unique_Key__c;
    }

    /** Every link this learner has been shown, most recent first (deduplicated by construction). */
    public static List<User_Study_Link__c> suggestedLinksFor(Id userId) {
        return [
            SELECT Study_Link__r.Title__c, Study_Link__r.URL__c, Study_Link__r.Link_Type__c, Study_Link__r.Cert__r.Name,
                First_Suggested_At__c, Last_Suggested_At__c
            FROM User_Study_Link__c
            WHERE User__c = :userId AND Study_Link__c != null AND Study_Link__r.URL__c != null
            ORDER BY Last_Suggested_At__c DESC
            LIMIT 200
        ];
    }

    /** Cert Ids for a session's codes (aggregates included; they simply have no links of their own). */
    public static Set<Id> certIdsForSession(Study_Session__c s) {
        Set<String> codes = sessionCodes(s);
        Set<Id> ids = new Set<Id>();
        for (Cert__c c : [SELECT Id FROM Cert__c WHERE Cert_Code__c IN :codes]) ids.add(c.Id);
        return ids;
    }

    // ------------------------------------------------------ contributions

    public static final String KIND_RESOURCE = 'Study resource';
    public static final String KIND_SUGGESTION = 'Suggestion';
    public static final Integer MAX_CONTRIBUTIONS_PER_HOUR = 10;
    public static final Integer MAX_CONTRIBUTION_DETAILS = 20000;

    /**
     * Save a learner's study resource (link and/or text for a cert) or a suggestion for the app.
     * Nothing reaches the question generator until an admin approves it.
     */
    public static void submitContribution(Id userId, String kind, String certCode, String title, String url, String details) {
        if (kind != KIND_RESOURCE && kind != KIND_SUGGESTION) throw new ServiceException('Choose what you are sending.');
        String t = String.isBlank(title) ? null : title.trim().abbreviate(150);
        String u = String.isBlank(url) ? null : url.trim();
        String d = String.isBlank(details) ? null : details.trim();
        if (d != null && d.length() > MAX_CONTRIBUTION_DETAILS) {
            throw new ServiceException('Please keep the text under ' + MAX_CONTRIBUTION_DETAILS + ' characters.');
        }
        if (u != null) {
            if (!Pattern.matches('(?i)https?://[^\\s]+', u) || u.length() > 255) {
                throw new ServiceException('The link must start with http:// or https:// and have no spaces.');
            }
        }
        Id certId;
        if (kind == KIND_RESOURCE) {
            if (String.isBlank(certCode)) throw new ServiceException('Pick the certification this resource is for.');
            List<Cert__c> certs = [SELECT Id FROM Cert__c WHERE Cert_Code__c = :certCode LIMIT 1];
            if (certs.isEmpty()) throw new ServiceException('That certification was not found.');
            certId = certs[0].Id;
            if (u == null && d == null) throw new ServiceException('Add a link, some text, or both.');
        } else if (d == null) {
            throw new ServiceException('Please describe your suggestion.');
        }
        DateTime since = DateTime.now().addHours(-1);
        if ([SELECT COUNT() FROM Contribution__c WHERE Submitter__c = :userId AND Submitted_At__c >= :since] >= MAX_CONTRIBUTIONS_PER_HOUR) {
            throw new ServiceException('You have sent a lot in the last hour. Please try again later.');
        }
        insert new Contribution__c(
            Kind__c = kind, Cert__c = certId, Title__c = t, URL__c = u, Details__c = d,
            Submitter__c = userId, Status__c = 'New', Submitted_At__c = DateTime.now()
        );
    }

    /** Trigger hook: approved study resources become Additional Cert Resources (once each). */
    public static void onContributionsApproved(List<Contribution__c> rows, Map<Id, Contribution__c> oldMap) {
        List<Contribution__c> toConvert = new List<Contribution__c>();
        for (Contribution__c c : rows) {
            Contribution__c old = oldMap.get(c.Id);
            Boolean nowApproved = c.Status__c == 'Approved' && (old == null || old.Status__c != 'Approved');
            if (!nowApproved || c.Kind__c != KIND_RESOURCE || c.Cert_Resource__c != null) continue;
            if (c.Cert__c == null) {
                c.addError('Pick a Certification before approving a study resource.');
                continue;
            }
            toConvert.add(c);
        }
        if (toConvert.isEmpty()) return;
        List<Cert_Resource__c> created = new List<Cert_Resource__c>();
        for (Contribution__c c : toConvert) {
            String content = c.Details__c;
            if (!String.isBlank(c.Title__c)) content = c.Title__c + (String.isBlank(content) ? '' : '\n\n' + content);
            created.add(new Cert_Resource__c(Cert__c = c.Cert__c, Role__c = 'Additional', URL__c = c.URL__c, Content__c = content));
        }
        insert created;
        for (Integer i = 0; i < toConvert.size(); i++) toConvert[i].Cert_Resource__c = created[i].Id;
    }

    /** Direct prerequisite names per cert Id, for the picker. */
    public static Map<Id, List<String>> prereqNamesByCert() {
        Map<Id, List<String>> out = new Map<Id, List<String>>();
        for (Cert_Prerequisite__c p : [
            SELECT Cert__c, Prereq_Cert__r.Name
            FROM Cert_Prerequisite__c
            WHERE Cert__c != null AND Prereq_Cert__c != null
            ORDER BY Prereq_Cert__r.Name
        ]) {
            if (!out.containsKey(p.Cert__c)) out.put(p.Cert__c, new List<String>());
            out.get(p.Cert__c).add(p.Prereq_Cert__r.Name);
        }
        return out;
    }

    /** [answered, correct] for a session. */
    public static Integer[] answerCounts(Id sessionId) {
        return new Integer[] {
            [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :sessionId],
            [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :sessionId AND Is_Correct__c = true]
        };
    }

    public static String findCerts(String searchTerm) {
        List<Cert__c> certs;
        if (String.isBlank(searchTerm)) {
            certs = [
                SELECT Name, Cert_Code__c, Is_Aggregate__c, Grounding_Chars__c
                FROM Cert__c ORDER BY Name LIMIT 300
            ];
        } else {
            String likeTerm = '%' + searchTerm.trim() + '%';
            certs = [
                SELECT Name, Cert_Code__c, Is_Aggregate__c, Grounding_Chars__c
                FROM Cert__c
                WHERE Name LIKE :likeTerm OR Cert_Code__c LIKE :likeTerm
                ORDER BY Name LIMIT 300
            ];
        }
        List<String> lines = new List<String>();
        for (Cert__c c : certs) {
            Boolean usable = c.Is_Aggregate__c || (c.Grounding_Chars__c != null && c.Grounding_Chars__c > 0);
            if (!usable) continue;
            String label = c.Name == c.Cert_Code__c ? c.Name : c.Name + ' (code: ' + c.Cert_Code__c + ')';
            lines.add('- ' + label + (c.Is_Aggregate__c ? ' -- credential earned via its prerequisites' : ''));
        }
        if (lines.isEmpty()) {
            return String.isBlank(searchTerm)
                ? 'No certifications have study material loaded yet.'
                : 'No certifications with study material match "' + searchTerm + '". Try a shorter search term.';
        }
        return 'Certifications available for practice:\n' + String.join(lines, '\n');
    }

    /**
     * Breadth-first walk of prerequisites. Aggregate certs pull in their
     * prerequisites silently; a non-aggregate cert with prerequisites needs
     * a yes/no answer first. Returns resolved codes, plus pendingPrompt if
     * resolution paused for an answer.
     */
    public class Resolution {
        public Set<String> resolved = new Set<String>();
        public String pendingPrompt;
    }

    public static Resolution resolveCerts(List<String> selected, Map<String, Boolean> answers) {
        Map<String, Cert__c> certsByCode = new Map<String, Cert__c>();
        for (Cert__c c : [SELECT Id, Name, Cert_Code__c, Is_Aggregate__c FROM Cert__c]) {
            certsByCode.put(c.Cert_Code__c.toUpperCase(), c);
        }
        Map<String, List<String>> prereqsByCode = new Map<String, List<String>>();
        for (Cert_Prerequisite__c e : [
            SELECT Cert__r.Cert_Code__c, Prereq_Cert__r.Cert_Code__c
            FROM Cert_Prerequisite__c
            WHERE Cert__c != null AND Prereq_Cert__c != null
        ]) {
            String parent = e.Cert__r.Cert_Code__c.toUpperCase();
            if (!prereqsByCode.containsKey(parent)) prereqsByCode.put(parent, new List<String>());
            prereqsByCode.get(parent).add(e.Prereq_Cert__r.Cert_Code__c.toUpperCase());
        }

        Resolution res = new Resolution();
        res.resolved.addAll(selected);
        List<String> toProcess = new List<String>(selected);
        Set<String> processed = new Set<String>();
        while (!toProcess.isEmpty()) {
            String code = toProcess.remove(0);
            if (processed.contains(code)) continue;
            processed.add(code);
            List<String> prereqs = prereqsByCode.get(code);
            if (prereqs == null || prereqs.isEmpty()) continue;

            Cert__c cert = certsByCode.get(code);
            Boolean isAggregate = cert != null && cert.Is_Aggregate__c;
            if (!isAggregate) {
                Boolean answer = answers.get(code);
                if (answer == null) {
                    res.pendingPrompt = code;
                    return res;
                }
                if (!answer) continue;
            }
            for (String p : prereqs) {
                res.resolved.add(p);
                if (!processed.contains(p)) toProcess.add(p);
            }
        }
        return res;
    }

    // -------------------------------------------------------------- session
    //
    // "Core" methods return structured results and are shared by the Lightning
    // app (CertStudyController) and the agent actions; the String methods
    // below them format those results as markdown for the chat agent.

    public class StartOutcome {
        public String error;
        public String pendingCode;
        public String pendingCertName;
        public List<String> pendingPrereqNames = new List<String>();
        public Study_Session__c session;
        public List<Cert__c> certs = new List<Cert__c>();
    }

    public class GradeOutcome {
        public String status; // ok | duplicate | noQuestion | invalid
        public Question__c question;
        public List<String> chosen = new List<String>();
        public List<String> correct = new List<String>();
        public Boolean isCorrect = false;
        public Integer answered = 0;
        public Integer right = 0;
    }

    public class AreaStat {
        public String certName;
        public String domain;
        public Integer right = 0;
        public Integer total = 0;
        public Integer pct() { return CertStudyService.pct(right, total); }
    }

    public class SummaryData {
        public Study_Session__c session;
        public Integer answered = 0;
        public Integer right = 0;
        public List<AreaStat> areas = new List<AreaStat>(); // weakest first
        public List<Answer__c> missed = new List<Answer__c>();
    }

    private static Map<String, Cert__c> certsByUpperCode() {
        Map<String, Cert__c> certsByCode = new Map<String, Cert__c>();
        for (Cert__c c : [
            SELECT Id, Name, Cert_Code__c, Is_Aggregate__c, Duration_Min__c, Num_Questions__c,
                Passing_Score__c, Domains_JSON__c, Grounding_Chars__c, Delivered_Questions__c
            FROM Cert__c
        ]) {
            certsByCode.put(c.Cert_Code__c.toUpperCase(), c);
        }
        return certsByCode;
    }

    /** Clamps to 1-5; null (no selection) means 1. */
    public static Integer clampDifficulty(Integer d) {
        return d == null ? 1 : Math.max(1, Math.min(5, d));
    }

    public static StartOutcome startSessionCore(String key, List<String> requestedCodes, Map<String, Boolean> answers) {
        return startSessionCore(key, requestedCodes, answers, null, false);
    }

    public static StartOutcome startSessionCore(
        String key, List<String> requestedCodes, Map<String, Boolean> answers, Integer minDifficulty
    ) {
        return startSessionCore(key, requestedCodes, answers, minDifficulty, false);
    }

    /**
     * focusWeakAreas: weight question selection toward the learner's weaker sections (Practice only).
     * It only applies to certs with earlier answers; with no history anywhere, the session just runs normally.
     */
    public static StartOutcome startSessionCore(
        String key, List<String> requestedCodes, Map<String, Boolean> answers, Integer minDifficulty,
        Boolean focusWeakAreas
    ) {
        StartOutcome out = new StartOutcome();
        Map<String, Cert__c> certsByCode = certsByUpperCode();

        List<String> selected = new List<String>();
        List<String> unknown = new List<String>();
        for (String token : requestedCodes == null ? new List<String>() : requestedCodes) {
            if (String.isBlank(token)) continue;
            String code = token.trim().toUpperCase();
            if (certsByCode.containsKey(code)) {
                if (!selected.contains(code)) selected.add(code);
            } else {
                unknown.add(token);
            }
        }
        if (!unknown.isEmpty() || selected.isEmpty()) {
            out.error = 'I could not find these certification codes: ' + String.join(unknown, ', ')
                + '. Use Find Certifications to look up the exact code.';
            return out;
        }

        Resolution res = resolveCerts(selected, answers == null ? new Map<String, Boolean>() : answers);
        if (res.pendingPrompt != null) {
            Cert__c c = certsByCode.get(res.pendingPrompt);
            out.pendingCode = res.pendingPrompt;
            out.pendingCertName = c.Name;
            for (Cert_Prerequisite__c e : [
                SELECT Prereq_Cert__r.Name FROM Cert_Prerequisite__c WHERE Cert__c = :c.Id
            ]) {
                out.pendingPrereqNames.add(e.Prereq_Cert__r.Name);
            }
            return out;
        }

        List<String> codes = new List<String>(res.resolved);
        codes.sort();
        List<String> ids = new List<String>();
        for (String code : codes) {
            if (certsByCode.containsKey(code)) {
                ids.add(String.valueOf(certsByCode.get(code).Id));
                out.certs.add(certsByCode.get(code));
            }
        }
        String delimited = ';' + String.join(ids, ';') + ';';
        if (delimited.length() > 255) {
            out.error = 'That selection expands to too many certifications for one session. Please pick fewer.';
            return out;
        }

        endSessions([SELECT Id FROM Study_Session__c WHERE User_Key__c = :key AND Status__c = :ACTIVE]);
        Study_Session__c s = new Study_Session__c(
            User_Key__c = key,
            User__c = userIdFor(key),
            Cert_Codes__c = delimited,
            Mode__c = MODE_PRACTICE,
            Min_Difficulty__c = clampDifficulty(minDifficulty),
            Status__c = ACTIVE,
            Started_At__c = DateTime.now(),
            Last_Activity__c = DateTime.now()
        );
        if (focusWeakAreas == true) {
            Map<String, Map<String, Decimal>> weights = focusWeights(key, new Set<String>(codes));
            if (!weights.isEmpty()) {
                s.Focus_Weak_Areas__c = true;
                s.Domain_Weights_JSON__c = JSON.serialize(weights);
            }
        }
        insert s;
        CertStudyPoolJob.requestTopUpAsync(new Set<String>(codes));
        out.session = s;
        return out;
    }

    /** The unanswered question if any, else claims the next Ready row; null = still generating. */
    public static Question__c nextQuestionRecord(Study_Session__c s) {
        Question__c current = currentQuestion(s.Id);
        if (current != null) return current;
        Set<String> codes = sessionCodes(s);
        Question__c claimed = claimFromPool(s.Id, codes);
        CertStudyPoolJob.requestTopUpAsync(codes);
        return claimed;
    }

    public static GradeOutcome gradeCore(Study_Session__c s, List<String> chosen) {
        return gradeCore(s, chosen, true);
    }

    /**
     * guardDuplicates: the chat agent sometimes re-calls SubmitAnswer within one
     * turn, so it ignores an identical answer seconds after the last one. The
     * Lightning page prevents double-submits itself and passes false, so a fast
     * learner picking the same letter twice in a row is never silently ignored.
     */
    public static GradeOutcome gradeCore(Study_Session__c s, List<String> chosen, Boolean guardDuplicates) {
        GradeOutcome out = new GradeOutcome();
        out.chosen = chosen == null ? new List<String>() : chosen;

        // Compare against every answer in the window, not just the latest: answers
        // in the same second have no reliable order.
        DateTime windowStart = DateTime.now().addSeconds(-DUPLICATE_WINDOW_SECONDS);
        String chosenKey = String.join(out.chosen, ',');
        if (guardDuplicates && !out.chosen.isEmpty()) {
            for (Answer__c recent : [
                SELECT User_Answer__c FROM Answer__c
                WHERE Study_Session__c = :s.Id AND Answered_At__c >= :windowStart
            ]) {
                if (recent.User_Answer__c == chosenKey) {
                    out.status = 'duplicate';
                    return out;
                }
            }
        }
        Question__c q = currentQuestion(s.Id);
        if (q == null) {
            out.status = 'noQuestion';
            return out;
        }
        out.question = q;
        Set<String> validKeys = new Set<String>();
        for (Map<String, String> o : options(q)) validKeys.add(o.get('key'));
        if (out.chosen.isEmpty() || !validKeys.containsAll(out.chosen)) {
            out.status = 'invalid';
            return out;
        }

        out.correct = correctKeys(q);
        out.isCorrect = new Set<String>(out.chosen).equals(new Set<String>(out.correct));
        Boolean unscored = false;
        String unscoredPos = isTest(s) ? unscoredPositions(s) : null;
        if (String.isNotBlank(unscoredPos)) {
            Integer position = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id] + 1;
            unscored = unscoredPos.contains(';' + position + ';');
        }
        insert new Answer__c(
            Study_Session__c = s.Id,
            Question__c = q.Id,
            User_Answer__c = chosenKey,
            Is_Correct__c = out.isCorrect,
            Is_Unscored__c = unscored,
            Answered_At__c = DateTime.now()
        );
        q.Status__c = 'Answered';
        update q;
        s.Last_Activity__c = DateTime.now();
        update s;

        out.answered = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id];
        out.right = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id AND Is_Correct__c = true];
        out.status = 'ok';
        return out;
    }

    /** Most recent session for the user (active first by recency); null if none. */
    public static Study_Session__c latestSession(String key) {
        List<Study_Session__c> sessions = [
            SELECT Id, Cert_Codes__c, Status__c, Started_At__c, Mode__c, Question_Target__c, Unscored_Positions__c, Timer_Mode__c, Time_Limit_Min__c, Elapsed_Seconds__c, Resumed_At__c, Paused__c, Completed_At__c,
                Min_Difficulty__c, Focus_Weak_Areas__c, Domain_Weights_JSON__c
            FROM Study_Session__c
            WHERE User_Key__c = :key
            ORDER BY Started_At__c DESC
            LIMIT 1
        ];
        return sessions.isEmpty() ? null : sessions[0];
    }

    /** What the learner picked last time, so the picker can offer "Select last session". */
    public class LastSelection {
        public String mode;                  // 'practice' | 'test'; null when there is no earlier session
        public List<String> certCodes = new List<String>();
        public String timerMode;             // test only: 'Open' | 'Strict'
        public Integer minDifficulty = 1;    // practice only
    }

    public static LastSelection lastSelection(String key) {
        LastSelection out = new LastSelection();
        List<Study_Session__c> rows = [
            SELECT Cert_Codes__c, Mode__c, Timer_Mode__c, Min_Difficulty__c
            FROM Study_Session__c
            WHERE User_Key__c = :key AND Started_At__c != null
            ORDER BY Started_At__c DESC
            LIMIT 1
        ];
        if (rows.isEmpty()) return out;
        Study_Session__c s = rows[0];
        out.mode = s.Mode__c == MODE_TEST ? 'test' : 'practice';
        out.timerMode = s.Timer_Mode__c;
        out.minDifficulty = clampDifficulty(s.Min_Difficulty__c == null ? null : s.Min_Difficulty__c.intValue());
        List<String> codes = new List<String>(sessionCodes(s));
        codes.sort();
        out.certCodes = codes;
        return out;
    }

    public static SummaryData summaryCore(Study_Session__c s, Boolean endIt) {
        SummaryData out = new SummaryData();
        out.session = s;
        Map<String, AreaStat> byArea = new Map<String, AreaStat>();
        for (Answer__c a : [
            SELECT Is_Correct__c, User_Answer__c, Question__r.Stem__c, Question__r.Domain__c,
                Question__r.Correct_JSON__c, Question__r.Options_JSON__c, Question__r.Feedback_MD__c,
                Question__r.Cert__r.Name
            FROM Answer__c
            WHERE Study_Session__c = :s.Id
            ORDER BY Answered_At__c
        ]) {
            out.answered++;
            if (a.Is_Correct__c) out.right++;
            String areaKey = a.Question__r.Cert__r.Name + '|' + (a.Question__r.Domain__c == null ? '' : a.Question__r.Domain__c);
            if (!byArea.containsKey(areaKey)) {
                AreaStat st = new AreaStat();
                st.certName = a.Question__r.Cert__r.Name;
                st.domain = a.Question__r.Domain__c;
                byArea.put(areaKey, st);
            }
            AreaStat st = byArea.get(areaKey);
            st.total++;
            if (a.Is_Correct__c) {
                st.right++;
            } else {
                out.missed.add(a);
            }
        }
        // weakest first: zero-padded percentage sort key
        Map<String, AreaStat> sorted = new Map<String, AreaStat>();
        for (String k : byArea.keySet()) {
            AreaStat st = byArea.get(k);
            sorted.put(String.valueOf(st.pct()).leftPad(3, '0') + '|' + k, st);
        }
        List<String> keys = new List<String>(sorted.keySet());
        keys.sort();
        for (String k : keys) out.areas.add(sorted.get(k));

        if (endIt && s.Status__c == ACTIVE) {
            endSessions(new List<Study_Session__c>{ s });
            s.Status__c = ENDED;
        }
        return out;
    }

    // ----------------------------------------------------------- test mode
    //
    // Clock rule: time accumulates only while a question is on screen
    // (Resumed_At__c != null). It stops when the learner pauses AND while the
    // learner waits for a question to be generated, so generation never eats
    // into a strict time limit.

    public class DomainResult {
        public String name;
        public Decimal weight;
        public Integer quota = 0;
        public Integer answered = 0;
        public Integer correct = 0;
        public Integer pctOfAnswered() { return CertStudyService.pct(correct, answered); }
    }

    public class TestResult {
        public Cert__c cert;
        public Integer target = 0;         // questions delivered, including unscored ones
        public Integer scoredTarget = 0;   // questions that count toward the score
        public Integer unscoredCount = 0;  // delivered but not counted (never revealed which)
        public Integer answered = 0;
        public Integer correct = 0;
        public Integer unanswered = 0;
        public Integer passing;
        public Boolean passingEstimated = false;
        public Integer officialPct = 0;   // correct / target (unanswered count as wrong)
        public Boolean passed = false;
        public Integer answeredPct = 0;   // correct / answered
        public Boolean answeredLikelyPass = false;
        public Boolean incomplete = false;
        public Boolean timedOut = false;
        public Integer elapsedSeconds = 0;
        public Integer limitMin;
        public Boolean strictTimer = false;
        public List<DomainResult> domains = new List<DomainResult>();
        public List<String> recommendations = new List<String>();
        public List<Answer__c> missed = new List<Answer__c>();
    }

    public static Boolean isTest(Study_Session__c s) {
        return s != null && s.Mode__c == MODE_TEST;
    }

    /** Questions shown in a test: the cert's delivered count, else its scored count plus the unscored extras. */
    public static Integer deliveredQuestions(Cert__c c) {
        Integer scored = c.Num_Questions__c != null ? c.Num_Questions__c.intValue() : DEFAULT_TEST_QUESTIONS;
        Integer delivered = null;
        try {
            delivered = c.Delivered_Questions__c == null ? null : c.Delivered_Questions__c.intValue();
        } catch (Exception e) {
            delivered = null; // field not queried by the caller
        }
        return delivered != null && delivered > 0 ? delivered : scored + unscoredExtra;
    }

    /** Random question numbers (1-based) that will not be scored, as ;n;n;. Never shown to the learner. */
    public static String pickUnscored(Integer delivered) {
        Integer n = Math.min(unscoredExtra, Math.max(0, (delivered == null ? 0 : delivered) - 1));
        if (n == 0) return null;
        List<Integer> positions = new List<Integer>();
        for (Integer i = 1; i <= delivered; i++) positions.add(i);
        for (Integer i = positions.size() - 1; i > 0; i--) {
            Integer j = Math.floor(Math.random() * (i + 1)).intValue();
            Integer t = positions[i];
            positions[i] = positions[j];
            positions[j] = t;
        }
        List<Integer> chosen = new List<Integer>();
        for (Integer i = 0; i < n; i++) chosen.add(positions[i]);
        chosen.sort();
        return ';' + String.join(chosen, ';') + ';';
    }

    public static Integer unscoredCount(Study_Session__c s) {
        String p = unscoredPositions(s);
        if (String.isBlank(p)) return 0;
        Integer n = 0;
        for (String t : p.split(';')) if (String.isNotBlank(t)) n++;
        return n;
    }

    private static String unscoredPositions(Study_Session__c s) {
        try {
            return s == null ? null : s.Unscored_Positions__c;
        } catch (Exception e) {
            return null; // field not queried by the caller
        }
    }

    public static StartOutcome startTestCore(String key, String certCode, Boolean strictTimer) {
        StartOutcome out = new StartOutcome();
        Cert__c c = String.isBlank(certCode) ? null : certsByUpperCode().get(certCode.trim().toUpperCase());
        if (c == null) {
            out.error = 'Pick a certification for the test.';
            return out;
        }
        if (c.Is_Aggregate__c) {
            out.error = c.Name + ' has no exam of its own (it is earned via its prerequisites). Pick one of those for a test.';
            return out;
        }
        if (c.Grounding_Chars__c == null || c.Grounding_Chars__c == 0) {
            out.error = c.Name + ' has no study material loaded yet, so test questions cannot be generated.';
            return out;
        }
        endSessions([SELECT Id FROM Study_Session__c WHERE User_Key__c = :key AND Status__c = :ACTIVE]);
        Integer delivered = deliveredQuestions(c);
        Study_Session__c s = new Study_Session__c(
            User_Key__c = key,
            User__c = userIdFor(key),
            Cert_Codes__c = ';' + c.Id + ';',
            Mode__c = MODE_TEST,
            Status__c = ACTIVE,
            Question_Target__c = delivered,
            Unscored_Positions__c = pickUnscored(delivered),
            Time_Limit_Min__c = c.Duration_Min__c != null ? c.Duration_Min__c : DEFAULT_TEST_MINUTES,
            Timer_Mode__c = strictTimer == true ? 'Strict' : 'Open',
            Elapsed_Seconds__c = 0,
            Paused__c = false,
            Started_At__c = DateTime.now(),
            Last_Activity__c = DateTime.now()
        );
        insert s;
        CertStudyPoolJob.requestTopUpAsync(new Set<String>{ c.Cert_Code__c });
        out.session = s;
        out.certs.add(c);
        return out;
    }

    public static Integer elapsedSeconds(Study_Session__c s) {
        Decimal base = s.Elapsed_Seconds__c == null ? 0 : s.Elapsed_Seconds__c;
        if (s.Resumed_At__c != null) {
            base += (DateTime.now().getTime() - s.Resumed_At__c.getTime()) / 1000;
        }
        return base.intValue();
    }

    public static Boolean isTimeUp(Study_Session__c s) {
        return isTest(s) && s.Timer_Mode__c == 'Strict' && s.Time_Limit_Min__c != null
            && elapsedSeconds(s) >= s.Time_Limit_Min__c * 60;
    }

    /** Folds the running stretch into Elapsed_Seconds__c and stops the clock (caller updates). */
    private static void stopClock(Study_Session__c s) {
        s.Elapsed_Seconds__c = elapsedSeconds(s);
        s.Resumed_At__c = null;
    }

    public static void pauseTest(Study_Session__c s) {
        stopClock(s);
        s.Paused__c = true;
        s.Last_Activity__c = DateTime.now();
        update s;
    }

    /** The clock restarts when the next question is actually shown (testQuestion). */
    public static void resumeTest(Study_Session__c s) {
        s.Paused__c = false;
        s.Last_Activity__c = DateTime.now();
        update s;
    }

    /**
     * The question to show in a test (claims one if needed), maintaining the
     * clock. Null while paused, while generating, or once the target is reached.
     */
    public static Question__c testQuestion(Study_Session__c s, Integer answered) {
        if (s.Paused__c == true) return null;
        Question__c q = null;
        if (answered < s.Question_Target__c) q = nextQuestionRecord(s);
        if (q != null && s.Resumed_At__c == null) {
            s.Resumed_At__c = DateTime.now();
            update s;
        } else if (q == null && s.Resumed_At__c != null) {
            stopClock(s);
            update s;
        }
        return q;
    }

    /** Scores the test and ends the session. */
    public static TestResult finishTest(Study_Session__c s, Boolean timedOut) {
        Boolean firstFinish = s.Completed_At__c == null;
        if (firstFinish) {
            stopClock(s);
            s.Completed_At__c = DateTime.now();
            s.Paused__c = false;
            update s;
        }
        TestResult r = testResult(s);
        r.timedOut = timedOut == true;
        if (firstFinish) {
            // Stored for reporting (usage dashboard); the app itself always recomputes.
            update new Study_Session__c(Id = s.Id, Score_Pct__c = r.officialPct, Passed__c = r.passed);
        }
        if (s.Status__c == ACTIVE) {
            endSessions(new List<Study_Session__c>{ s });
            s.Status__c = ENDED;
        }
        return r;
    }

    /** Domain quotas for a test of n questions (largest-remainder rounding of the official weights). */
    public static Map<String, Integer> domainQuotas(Cert__c c, Integer n) {
        Map<String, Integer> quotas = new Map<String, Integer>();
        List<Map<String, Object>> doms = CertStudyGenerator.domains(c);
        if (doms.isEmpty() || n == null || n <= 0) return quotas;
        Decimal sumW = 0;
        List<Decimal> ws = new List<Decimal>();
        for (Map<String, Object> d : doms) {
            Decimal w = 1;
            try {
                if (d.get('weight_pct') != null) w = Decimal.valueOf(String.valueOf(d.get('weight_pct')));
            } catch (Exception e) {
                w = 1;
            }
            if (w <= 0) w = 1;
            ws.add(w);
            sumW += w;
        }
        Integer assigned = 0;
        List<Decimal> remainders = new List<Decimal>();
        for (Integer i = 0; i < doms.size(); i++) {
            Decimal exact = ws[i] / sumW * n;
            Integer fl = exact.round(System.RoundingMode.DOWN).intValue();
            quotas.put(String.valueOf(doms[i].get('name')), fl);
            remainders.add(exact - fl);
            assigned += fl;
        }
        while (assigned < n) {
            Integer best = 0;
            for (Integer i = 1; i < remainders.size(); i++) {
                if (remainders[i] > remainders[best]) best = i;
            }
            String name = String.valueOf(doms[best].get('name'));
            quotas.put(name, quotas.get(name) + 1);
            remainders[best] = -1;
            assigned++;
        }
        return quotas;
    }

    public static TestResult testResult(Study_Session__c s) {
        TestResult r = new TestResult();
        Set<String> codes = sessionCodes(s);
        List<Cert__c> certs = [
            SELECT Id, Name, Cert_Code__c, Num_Questions__c, Duration_Min__c, Passing_Score__c, Domains_JSON__c
            FROM Cert__c WHERE Cert_Code__c IN :codes LIMIT 1
        ];
        r.cert = certs.isEmpty() ? null : certs[0];
        r.target = s.Question_Target__c == null ? 0 : s.Question_Target__c.intValue();
        r.unscoredCount = r.target > 0 ? Math.min(unscoredCount(s), r.target) : 0;
        r.scoredTarget = r.target - r.unscoredCount;
        r.limitMin = s.Time_Limit_Min__c == null ? null : s.Time_Limit_Min__c.intValue();
        r.strictTimer = s.Timer_Mode__c == 'Strict';
        r.elapsedSeconds = elapsedSeconds(s);
        r.passingEstimated = r.cert == null || r.cert.Passing_Score__c == null;
        r.passing = r.passingEstimated ? DEFAULT_PASSING_SCORE : r.cert.Passing_Score__c.intValue();

        Map<String, DomainResult> byName = new Map<String, DomainResult>();
        if (r.cert != null) {
            Map<String, Integer> quotas = domainQuotas(r.cert, r.scoredTarget);
            for (Map<String, Object> d : CertStudyGenerator.domains(r.cert)) {
                DomainResult dr = new DomainResult();
                dr.name = String.valueOf(d.get('name'));
                try {
                    dr.weight = d.get('weight_pct') == null ? null : Decimal.valueOf(String.valueOf(d.get('weight_pct')));
                } catch (Exception e) {
                    dr.weight = null;
                }
                dr.quota = quotas.containsKey(dr.name) ? quotas.get(dr.name) : 0;
                byName.put(dr.name, dr);
                r.domains.add(dr);
            }
        }
        Integer scoredAnswered = 0;
        for (Answer__c a : [
            SELECT Is_Correct__c, Is_Unscored__c, User_Answer__c, Question__r.Stem__c, Question__r.Domain__c,
                Question__r.Correct_JSON__c, Question__r.Options_JSON__c, Question__r.Feedback_MD__c,
                Question__r.Cert__r.Name
            FROM Answer__c WHERE Study_Session__c = :s.Id ORDER BY Answered_At__c
        ]) {
            r.answered++;
            if (a.Is_Unscored__c == true) {
                // Shown for review like any other miss, but never counted in the score or the sections.
                if (!a.Is_Correct__c) r.missed.add(a);
                continue;
            }
            scoredAnswered++;
            if (a.Is_Correct__c) r.correct++;
            else r.missed.add(a);
            String dn = String.isBlank(a.Question__r.Domain__c) ? 'Other' : a.Question__r.Domain__c;
            DomainResult dr = byName.get(dn);
            if (dr == null) {
                dr = new DomainResult();
                dr.name = dn;
                byName.put(dn, dr);
                r.domains.add(dr);
            }
            dr.answered++;
            if (a.Is_Correct__c) dr.correct++;
        }
        r.unanswered = Math.max(0, r.target - r.answered);
        r.incomplete = r.unanswered > 0;
        r.officialPct = pct(r.correct, r.scoredTarget > 0 ? r.scoredTarget : scoredAnswered);
        r.passed = r.officialPct >= r.passing;
        r.answeredPct = pct(r.correct, scoredAnswered);
        r.answeredLikelyPass = scoredAnswered > 0 && r.answeredPct >= r.passing;

        // Recommendations: weakest high-weight sections first, then sections never reached.
        Map<String, String> ranked = new Map<String, String>();
        List<String> notReached = new List<String>();
        for (DomainResult dr : r.domains) {
            String weightText = dr.weight == null ? '' : ' (' + dr.weight.setScale(0) + '% of the exam)';
            if (dr.answered == 0) {
                if (dr.quota > 0) notReached.add(dr.name + (dr.weight == null ? '' : ' (' + dr.weight.setScale(0) + '%)'));
                continue;
            }
            Integer p = dr.pctOfAnswered();
            if (p < r.passing) {
                Decimal w = dr.weight == null ? 1 : dr.weight;
                Decimal priority = w * (r.passing - p);
                String sortKey = String.valueOf(100000000 - priority.setScale(0).intValue()).leftPad(10, '0') + '|' + dr.name;
                ranked.put(sortKey, 'Focus on ' + dr.name + weightText + ': you scored ' + p + '% (' + dr.correct + '/' + dr.answered + ') against a ' + r.passing + '% pass mark.');
            }
        }
        List<String> keys = new List<String>(ranked.keySet());
        keys.sort();
        for (String k : keys) {
            if (r.recommendations.size() >= MAX_RECOMMENDATIONS) break;
            r.recommendations.add(ranked.get(k));
        }
        if (keys.size() > MAX_RECOMMENDATIONS) {
            r.recommendations.add((keys.size() - MAX_RECOMMENDATIONS) + ' more section(s) were below the pass mark -- see the section list above.');
        }
        if (!notReached.isEmpty()) {
            r.recommendations.add('Not reached -- practice these before the real exam: ' + String.join(notReached, ', ') + '.');
        }
        if (r.recommendations.isEmpty()) {
            r.recommendations.add('You were at or above the pass mark in every section you attempted. Keep practicing to stay sharp.');
        }
        return r;
    }

    /** Ready-pool size to keep for a cert: larger while an active test needs it. */
    public static Integer poolTarget(Id certId) {
        String likeTerm = '%;' + String.valueOf(certId) + ';%';
        Integer tests = [
            SELECT COUNT() FROM Study_Session__c
            WHERE Status__c = :ACTIVE AND Mode__c = :MODE_TEST AND Cert_Codes__c LIKE :likeTerm
        ];
        return tests > 0 ? TEST_POOL_TARGET : CertStudyGenerator.POOL_SIZE;
    }

    /**
     * Highest minimum difficulty (1-5) among active sessions on this cert whose
     * claimable pool (unclaimed Ready rows at or above it) is below target;
     * null when every active session is covered. Minimum 1 is always checked
     * (it also covers tests). Generating for the highest unmet minimum first
     * means a high-minimum session is never starved by an easy backlog, and
     * the questions it adds also count toward every lower minimum.
     */
    public static Integer unmetMinDifficulty(Id certId, Integer target) {
        String likeTerm = '%;' + String.valueOf(certId) + ';%';
        Set<Integer> mins = new Set<Integer>{ 1 };
        for (Study_Session__c s : [
            SELECT Min_Difficulty__c FROM Study_Session__c
            WHERE Status__c = :ACTIVE AND Mode__c = :MODE_PRACTICE AND Cert_Codes__c LIKE :likeTerm
        ]) {
            mins.add(clampDifficulty(s.Min_Difficulty__c == null ? null : s.Min_Difficulty__c.intValue()));
        }
        List<Integer> ordered = new List<Integer>(mins);
        ordered.sort();
        for (Integer i = ordered.size() - 1; i >= 0; i--) {
            Integer m = ordered[i];
            Integer ready = m <= 1
                ? [SELECT COUNT() FROM Question__c WHERE Cert__c = :certId AND Status__c = 'Ready' AND Study_Session__c = null]
                : [SELECT COUNT() FROM Question__c WHERE Cert__c = :certId AND Status__c = 'Ready' AND Study_Session__c = null AND Difficulty__c >= :m];
            if (ready < target) return m;
        }
        return null;
    }

    /**
     * A generation lock this old is treated as stalled when a learner asks for a retry
     * (a healthy chain refreshes it every question, about every 10 seconds).
     */
    public static final Integer KICK_LOCK_MIN = 2;

    private static Integer minutesSince(DateTime t) {
        return Math.max(0, (Integer) ((DateTime.now().getTime() - t.getTime()) / 60000));
    }

    /**
     * Learner-facing reason no question is ready yet (no internal error text).
     * Null when there are no certs to check.
     */
    public static String waitMessage(Set<String> codes) {
        if (codes == null || codes.isEmpty()) return null;
        DateTime lockFresh = DateTime.now().addMinutes(-CertStudyPoolJob.LOCK_STALE_MINUTES);
        Integer cooldownLeft = 0;
        Boolean generating = false;
        for (Cert__c c : [
            SELECT Top_Up_Started_At__c, Last_Failure_At__c FROM Cert__c WHERE Cert_Code__c IN :codes
        ]) {
            if (c.Last_Failure_At__c != null) {
                Integer left = CertStudyPoolJob.FAILURE_COOLDOWN_MIN - minutesSince(c.Last_Failure_At__c);
                if (left > cooldownLeft) cooldownLeft = left;
            }
            if (c.Top_Up_Started_At__c != null && c.Top_Up_Started_At__c > lockFresh) generating = true;
        }
        if (cooldownLeft > 0) {
            return 'Question generation hit repeated errors and is paused for about ' + cooldownLeft
                + ' more minute' + (cooldownLeft == 1 ? '' : 's') + '. Press Check again to retry now.';
        }
        if (generating) return 'Your next question is being written now.';
        return 'Waiting for the question generator to start. Press Check again if this takes more than a minute.';
    }

    /**
     * Learner pressed Check again while waiting: drop the failure cooldown and any stalled
     * generation lock for these certs, then request a fresh top-up. A fresh lock (a chain that
     * is actually running) is left alone.
     */
    public static void kickGeneration(Set<String> codes) {
        if (codes == null || codes.isEmpty()) return;
        DateTime stalledBefore = DateTime.now().addMinutes(-KICK_LOCK_MIN);
        List<Cert__c> toClear = new List<Cert__c>();
        for (Cert__c c : [
            SELECT Id, Top_Up_Started_At__c, Last_Failure_At__c FROM Cert__c WHERE Cert_Code__c IN :codes
        ]) {
            Boolean changed = false;
            if (c.Last_Failure_At__c != null) {
                c.Last_Failure_At__c = null;
                changed = true;
            }
            if (c.Top_Up_Started_At__c != null && c.Top_Up_Started_At__c < stalledBefore) {
                c.Top_Up_Started_At__c = null;
                changed = true;
            }
            if (changed) toClear.add(c);
        }
        if (!toClear.isEmpty()) update toClear;
        CertStudyPoolJob.requestTopUpAsync(codes);
    }

    // ------------------------------------------------- agent (markdown) API

    public static String startSession(String userKey, String certCodesText, String prereqAnswersText) {
        return startSession(userKey, certCodesText, prereqAnswersText, null);
    }

    public static String startSession(String userKey, String certCodesText, String prereqAnswersText, Integer minDifficulty) {
        String key = resolveUserKey(userKey);
        StartOutcome res = startSessionCore(key, splitList(certCodesText), parseAnswers(prereqAnswersText), minDifficulty);
        if (res.error != null) return res.error;
        if (res.pendingCode != null) {
            return 'NEEDS_ANSWER (' + res.pendingCode + '): ' + res.pendingCertName + ' has prerequisite certifications: '
                + String.join(res.pendingPrereqNames, ', ') + '. Should questions on those prerequisites be included too? (yes/no)';
        }

        List<String> lines = new List<String>{ '**Practice session started.**', '' };
        for (Cert__c c : res.certs) {
            if (c.Is_Aggregate__c) {
                lines.add('- **' + c.Name + '** (credential earned via its prerequisites)');
                continue;
            }
            String detail = '';
            if (c.Num_Questions__c != null) {
                detail = ' -- real exam: ' + c.Num_Questions__c + ' questions, '
                    + c.Duration_Min__c + ' min, pass at ' + c.Passing_Score__c + '%';
            }
            lines.add('- **' + c.Name + '**' + detail);
            List<String> doms = new List<String>();
            for (Map<String, Object> d : CertStudyGenerator.domains(c)) {
                doms.add(String.valueOf(d.get('name')) + (d.get('weight_pct') != null ? ' (' + String.valueOf(d.get('weight_pct')) + '%)' : ''));
            }
            if (!doms.isEmpty()) lines.add('  Domains: ' + String.join(doms, '; '));
            lines.add('');
        }
        lines.add('');
        lines.add(serveNext(res.session));
        return String.join(lines, '\n');
    }

    public static String nextQuestion(String userKey) {
        Study_Session__c s = activeSession(resolveUserKey(userKey));
        if (s == null) return noSessionMessage();
        if (isTest(s)) return 'You have a mock test in progress. Tests run in the Cert Study app in Salesforce; open it to continue, or start a new practice session here (that ends the test).';
        return serveNext(s);
    }

    public static String submitAnswer(String userKey, String answerText) {
        Study_Session__c s = activeSession(resolveUserKey(userKey));
        if (s == null) return noSessionMessage();
        if (isTest(s)) return 'You have a mock test in progress. Tests run in the Cert Study app in Salesforce; open it to continue, or start a new practice session here (that ends the test).';

        GradeOutcome g = gradeCore(s, parseLetters(answerText));
        if (g.status == 'duplicate') {
            return DUPLICATE_PREFIX + ': this answer was already recorded moments ago. Do not show this to the learner; wait for their next reply.';
        }
        if (g.status == 'noQuestion') return 'There is no question waiting for an answer.\n\n' + serveNext(s);
        if (g.status == 'invalid') return 'Please answer with the option letter(s) shown, for example "B" or "B, D".';

        List<String> lines = new List<String>();
        lines.add(g.isCorrect
            ? '✅ **Correct!**'
            : '❌ **Not quite.** You chose ' + String.join(g.chosen, ', ') + '; the correct answer is ' + String.join(g.correct, ', ') + '.');
        lines.add('');
        lines.add('Score so far: ' + g.right + '/' + g.answered + ' (' + pct(g.right, g.answered) + '%)');
        lines.add('');
        lines.add('**Explanation**');
        lines.add('');
        lines.add(g.question.Feedback_MD__c);
        lines.add('');
        lines.add('---');
        lines.add('');
        lines.add(serveNext(s));
        return String.join(lines, '\n');
    }

    public static String sessionSummary(String userKey, Boolean endIt) {
        Study_Session__c s = latestSession(resolveUserKey(userKey));
        if (s == null) return 'You have no practice sessions yet. ' + noSessionMessage();
        if (isTest(s) && s.Status__c == ACTIVE) return 'You have a mock test in progress. Tests run in the Cert Study app in Salesforce; open it to continue, or start a new practice session here (that ends the test).';
        SummaryData d = summaryCore(s, endIt);

        List<String> lines = new List<String>();
        lines.add('**Session summary**' + (endIt ? ' (session ended)' : ''));
        lines.add('');
        lines.add('Answered: ' + d.answered + ' | Correct: ' + d.right + ' (' + pct(d.right, d.answered) + '%)');
        if (!d.areas.isEmpty()) {
            lines.add('');
            lines.add('**By area (weakest first)**');
            for (AreaStat st : d.areas) {
                String area = st.certName + (String.isBlank(st.domain) ? '' : ' / ' + st.domain);
                lines.add('- ' + st.pct() + '% -- ' + area + ' (' + st.right + '/' + st.total + ')');
            }
        }
        if (!d.missed.isEmpty()) {
            lines.add('');
            lines.add('**Questions to review**');
            Integer shown = 0;
            for (Answer__c a : d.missed) {
                if (shown++ >= 10) break;
                lines.add('- ' + a.Question__r.Stem__c.abbreviate(200) + '\n  Correct: '
                    + describeKeys(a.Question__r.Options_JSON__c, a.Question__r.Correct_JSON__c)
                    + ' | You chose: ' + a.User_Answer__c);
            }
        }
        return String.join(lines, '\n');
    }

    // ------------------------------------------------------------ internals

    /** Ends sessions and returns any served-but-unanswered questions to the pool. */
    public static void endSessions(List<Study_Session__c> sessions) {
        if (sessions == null || sessions.isEmpty()) return;
        Set<Id> ids = new Map<Id, Study_Session__c>(sessions).keySet();
        List<Question__c> unanswered = [
            SELECT Id FROM Question__c WHERE Study_Session__c IN :ids AND Status__c = 'Served'
        ];
        for (Question__c q : unanswered) {
            q.Study_Session__c = null;
            q.Status__c = 'Ready';
            q.Served_At__c = null;
        }
        update unanswered;
        List<Study_Session__c> toEnd = new List<Study_Session__c>();
        for (Id i : ids) toEnd.add(new Study_Session__c(Id = i, Status__c = ENDED));
        update toEnd;
    }

    public static Boolean isCertNeeded(Id certId) {
        String likeTerm = '%;' + String.valueOf(certId) + ';%';
        return [SELECT COUNT() FROM Study_Session__c WHERE Status__c = :ACTIVE AND Cert_Codes__c LIKE :likeTerm] > 0;
    }

    public static Set<String> activeCertCodes() {
        return codesForSessions([SELECT Cert_Codes__c FROM Study_Session__c WHERE Status__c = :ACTIVE]);
    }

    public static Study_Session__c activeSession(String key) {
        List<Study_Session__c> rows = [
            SELECT Id, Cert_Codes__c, Status__c, Started_At__c, Mode__c, Question_Target__c, Unscored_Positions__c, Timer_Mode__c, Time_Limit_Min__c, Elapsed_Seconds__c, Resumed_At__c, Paused__c, Completed_At__c,
                Min_Difficulty__c, Focus_Weak_Areas__c, Domain_Weights_JSON__c FROM Study_Session__c
            WHERE User_Key__c = :key AND Status__c = :ACTIVE
            ORDER BY Started_At__c DESC LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Question__c currentQuestion(Id sessionId) {
        List<Question__c> rows = [
            SELECT Id, Stem__c, Options_JSON__c, Correct_JSON__c, Feedback_MD__c, Domain__c,
                Difficulty__c, Format__c, Cert__c, Cert__r.Name
            FROM Question__c
            WHERE Study_Session__c = :sessionId AND Status__c = 'Served'
            ORDER BY Served_At__c DESC LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** Re-shows the unanswered question if there is one; otherwise claims the next Ready row. */
    private static String serveNext(Study_Session__c s) {
        Question__c claimed = nextQuestionRecord(s);
        if (claimed == null) {
            return '⏳ Your next question is still being generated (usually under a minute). Ask me for the next question again shortly.';
        }
        return formatQuestion(claimed, s.Id);
    }

    /**
     * Picks randomly across the whole Ready pool (not just the oldest rows),
     * preferring domains not seen in the session's last few questions, so a
     * session mixes topics. SOQL locking cannot be combined with ORDER BY, so
     * candidates are shuffled in Apex, then lock-and-rechecked one at a time.
     */
    private static Question__c claimFromPool(Id sessionId, Set<String> codes) {
        List<Study_Session__c> sess = [
            SELECT Id, Mode__c, Question_Target__c, Cert_Codes__c, Min_Difficulty__c,
                Focus_Weak_Areas__c, Domain_Weights_JSON__c, User_Key__c
            FROM Study_Session__c WHERE Id = :sessionId
        ];
        if (!sess.isEmpty() && isTest(sess[0])) return claimForTest(sess[0], codes);
        Integer minD = sess.isEmpty() ? 1 : clampDifficulty(sess[0].Min_Difficulty__c == null ? null : sess[0].Min_Difficulty__c.intValue());
        // Unrated (null-difficulty) legacy rows only count at the default minimum of 1.
        // "= :null" matches blanks; "= :-1" matches nothing.
        Integer unratedMatch = minD <= 1 ? null : -1;
        // Weak-area focus (Practice only): weighted pick by domain. With focus on, only the previous
        // question's domain is avoided, so the weights (not the rotation) decide how often weak ones appear.
        Map<String, Map<String, Decimal>> focusMap = (!sess.isEmpty() && sess[0].Focus_Weak_Areas__c == true)
            ? parseFocusWeights(sess[0].Domain_Weights_JSON__c)
            : new Map<String, Map<String, Decimal>>();
        Integer recentLimit = focusMap.isEmpty() ? 3 : 1;
        Set<String> recentDomains = new Set<String>();
        Id lastCert = null;
        for (Question__c r : [
            SELECT Domain__c, Cert__c FROM Question__c
            WHERE Study_Session__c = :sessionId ORDER BY Served_At__c DESC LIMIT :recentLimit
        ]) {
            if (lastCert == null) lastCert = r.Cert__c;
            if (String.isNotBlank(r.Domain__c)) recentDomains.add(r.Domain__c);
        }
        // Buckets, best first: new cert + new domain, new domain, new cert, neither.
        // In multi-cert sessions this rotates between certs; within a cert it mixes domains.
        List<List<Question__c>> buckets = new List<List<Question__c>>{
            new List<Question__c>(), new List<Question__c>(), new List<Question__c>(), new List<Question__c>()
        };
        for (Question__c c : [
            SELECT Id, Domain__c, Cert__c, Cert__r.Cert_Code__c FROM Question__c
            WHERE Study_Session__c = null AND Status__c = 'Ready' AND Cert__r.Cert_Code__c IN :codes
                AND (Difficulty__c >= :minD OR Difficulty__c = :unratedMatch)
            LIMIT 200
        ]) {
            Boolean sameCert = lastCert != null && c.Cert__c == lastCert;
            Boolean sameDomain = String.isNotBlank(c.Domain__c) && recentDomains.contains(c.Domain__c);
            Integer idx = sameCert ? (sameDomain ? 3 : 1) : (sameDomain ? 2 : 0);
            buckets[idx].add(c);
        }
        List<Question__c> candidates = new List<Question__c>();
        for (List<Question__c> b : buckets) {
            if (focusMap.isEmpty()) shuffleRecords(b);
            else weightedShuffleRecords(b, focusMap);
            candidates.addAll(b);
        }
        Question__c fresh = lockAndClaim(sessionId, candidates);
        if (fresh != null || sess.isEmpty()) return fresh;
        // Nothing fresh is ready: reuse a question other learners have already answered (never one this learner has seen).
        return claimReused(sess[0], codes, minD, unratedMatch, focusMap);
    }

    /**
     * Pool empty fallback (Practice only). Copies an answered question from another learner into this session,
     * so the learner keeps studying while new questions are written. Skips originals this learner already got
     * (their own, or an earlier copy, via Source_Question__c) and any question with a problem report.
     */
    private static Question__c claimReused(
        Study_Session__c s, Set<String> codes, Integer minD, Integer unratedMatch, Map<String, Map<String, Decimal>> focusMap
    ) {
        if (String.isBlank(s.User_Key__c)) return null;
        String key = s.User_Key__c;
        // Originals this learner has already been given a copy of (a same-object semi-join is not allowed in SOQL).
        Set<Id> seen = new Set<Id>();
        for (Question__c c : [
            SELECT Source_Question__c FROM Question__c
            WHERE Study_Session__r.User_Key__c = :key AND Source_Question__c != null
        ]) {
            seen.add(c.Source_Question__c);
        }
        List<Question__c> candidates = [
            SELECT Id, Domain__c, Cert__c, Cert__r.Cert_Code__c FROM Question__c
            WHERE Status__c = 'Answered' AND Source_Question__c = null
                AND Cert__r.Cert_Code__c IN :codes
                AND Study_Session__r.User_Key__c != :key
                AND (Difficulty__c >= :minD OR Difficulty__c = :unratedMatch)
                AND Id NOT IN :seen
                AND Id NOT IN (SELECT Question__c FROM Question_Report__c WHERE Question__c != null)
            LIMIT 200
        ];
        if (candidates.isEmpty()) return null;
        if (focusMap.isEmpty()) shuffleRecords(candidates);
        else weightedShuffleRecords(candidates, focusMap);
        Question__c o = [
            SELECT Id, Cert__c, Stem__c, Format__c, Difficulty__c, Domain__c, Style__c,
                Options_JSON__c, Correct_JSON__c, Feedback_MD__c
            FROM Question__c WHERE Id = :candidates[0].Id
        ];
        insert new Question__c(
            Cert__c = o.Cert__c, Stem__c = o.Stem__c, Format__c = o.Format__c, Difficulty__c = o.Difficulty__c,
            Domain__c = o.Domain__c, Style__c = o.Style__c, Options_JSON__c = o.Options_JSON__c,
            Correct_JSON__c = o.Correct_JSON__c, Feedback_MD__c = o.Feedback_MD__c,
            Source_Question__c = o.Id, Study_Session__c = s.Id, Status__c = 'Served', Served_At__c = DateTime.now()
        );
        return currentQuestion(s.Id);
    }

    // ------------------------------------------------ weak-area focus (Practice only)

    /** Shrinkage strength: a domain with few answers is pulled toward the cert's overall accuracy. */
    public static final Integer FOCUS_SHRINK = 5;
    /** weight = 1 + FOCUS_BOOST * (1 - accuracy): 100% right is 1.0 (neutral), 0% right is 3.0. */
    public static final Decimal FOCUS_BOOST = 2.0;
    /** A domain at or above this weight (accuracy about 75% or lower) counts as weak. */
    public static final Decimal FOCUS_WEAK_WEIGHT = 1.5;
    /** Keep at least this many unclaimed Ready questions in each weak domain while a focus session is active. */
    public static final Integer FOCUS_DOMAIN_READY = 3;

    /** Cert codes the learner has answered at least one question on, in Practice or Test mode. */
    public static Set<String> answeredCertCodes(String key) {
        Set<String> out = new Set<String>();
        for (AggregateResult ar : [
            SELECT Question__r.Cert__r.Cert_Code__c cc
            FROM Answer__c
            WHERE Study_Session__r.User_Key__c = :key
            GROUP BY Question__r.Cert__r.Cert_Code__c
        ]) {
            String c = (String) ar.get('cc');
            if (String.isNotBlank(c)) out.add(c);
        }
        return out;
    }

    /**
     * Per cert (with earlier answers), per domain weights from the learner's whole answer history
     * (Practice and Test). Certs with no history are omitted, so focus simply does not apply to them.
     */
    public static Map<String, Map<String, Decimal>> focusWeights(String key, Set<String> codes) {
        Map<String, Map<String, Decimal>> out = new Map<String, Map<String, Decimal>>();
        if (codes == null || codes.isEmpty()) return out;
        Map<String, Integer> certN = new Map<String, Integer>();
        Map<String, Integer> certRight = new Map<String, Integer>();
        Map<String, Map<String, Integer>> domN = new Map<String, Map<String, Integer>>();
        Map<String, Map<String, Integer>> domRight = new Map<String, Map<String, Integer>>();
        for (AggregateResult ar : [
            SELECT Question__r.Cert__r.Cert_Code__c cc, Question__r.Domain__c d, Is_Correct__c ok, COUNT(Id) n
            FROM Answer__c
            WHERE Study_Session__r.User_Key__c = :key AND Question__r.Cert__r.Cert_Code__c IN :codes
            GROUP BY Question__r.Cert__r.Cert_Code__c, Question__r.Domain__c, Is_Correct__c
        ]) {
            String cc = (String) ar.get('cc');
            String d = (String) ar.get('d');
            Integer n = (Integer) ar.get('n');
            Boolean ok = (Boolean) ar.get('ok');
            certN.put(cc, (certN.containsKey(cc) ? certN.get(cc) : 0) + n);
            if (ok == true) certRight.put(cc, (certRight.containsKey(cc) ? certRight.get(cc) : 0) + n);
            if (String.isBlank(d)) continue;
            if (!domN.containsKey(cc)) {
                domN.put(cc, new Map<String, Integer>());
                domRight.put(cc, new Map<String, Integer>());
            }
            Map<String, Integer> dn = domN.get(cc);
            Map<String, Integer> dr = domRight.get(cc);
            dn.put(d, (dn.containsKey(d) ? dn.get(d) : 0) + n);
            if (ok == true) dr.put(d, (dr.containsKey(d) ? dr.get(d) : 0) + n);
        }
        Set<String> withHistory = certN.keySet();
        for (Cert__c c : [SELECT Cert_Code__c, Domains_JSON__c FROM Cert__c WHERE Cert_Code__c IN :withHistory]) {
            String cc = c.Cert_Code__c;
            Decimal rightAll = certRight.containsKey(cc) ? certRight.get(cc) : 0;
            Decimal overall = certN.get(cc) == 0 ? 0.5 : rightAll / certN.get(cc);
            Set<String> names = new Set<String>();
            for (Map<String, Object> d : CertStudyGenerator.domains(c)) names.add(String.valueOf(d.get('name')));
            if (domN.containsKey(cc)) names.addAll(domN.get(cc).keySet());
            Map<String, Decimal> w = new Map<String, Decimal>();
            for (String name : names) {
                Integer n = domN.containsKey(cc) && domN.get(cc).containsKey(name) ? domN.get(cc).get(name) : 0;
                Integer right = domRight.containsKey(cc) && domRight.get(cc).containsKey(name) ? domRight.get(cc).get(name) : 0;
                Decimal adj = (right + FOCUS_SHRINK * overall) / (n + FOCUS_SHRINK);
                w.put(name, (1 + FOCUS_BOOST * (1 - adj)).setScale(2));
            }
            if (!w.isEmpty()) out.put(cc, w);
        }
        // Results from a failed exam replace the practice-history weights for that cert until the learner passes.
        Map<String, Map<String, Decimal>> exam = examWeights(userIdOrNull(key), codes);
        for (String cc : exam.keySet()) out.put(cc, exam.get(cc));
        return out;
    }

    public static Map<String, Map<String, Decimal>> parseFocusWeights(String jsonText) {
        Map<String, Map<String, Decimal>> out = new Map<String, Map<String, Decimal>>();
        if (String.isBlank(jsonText)) return out;
        try {
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
            for (String cc : raw.keySet()) {
                Map<String, Decimal> w = new Map<String, Decimal>();
                Map<String, Object> domainWeights = (Map<String, Object>) raw.get(cc);
                for (String d : domainWeights.keySet()) w.put(d, Decimal.valueOf(String.valueOf(domainWeights.get(d))));
                out.put(cc, w);
            }
        } catch (Exception e) {
            return new Map<String, Map<String, Decimal>>(); // a bad snapshot just turns focus off
        }
        return out;
    }

    private class WeightedItem implements Comparable {
        Question__c q;
        Double key;
        public Integer compareTo(Object other) {
            Double o = ((WeightedItem) other).key;
            return key == o ? 0 : (key > o ? -1 : 1); // largest key first
        }
    }

    /** Weighted random order (Efraimidis-Spirakis): a weight-3 domain comes up about three times as often as weight 1. */
    private static void weightedShuffleRecords(List<Question__c> items, Map<String, Map<String, Decimal>> weights) {
        List<WeightedItem> keyed = new List<WeightedItem>();
        for (Question__c q : items) {
            Decimal w = 1;
            String code = q.Cert__r == null ? null : q.Cert__r.Cert_Code__c;
            if (code != null && weights.containsKey(code) && q.Domain__c != null && weights.get(code).containsKey(q.Domain__c)) {
                w = weights.get(code).get(q.Domain__c);
            }
            WeightedItem wi = new WeightedItem();
            wi.q = q;
            Double ww = w.doubleValue();
            if (ww < 0.001) ww = 0.001;
            wi.key = Math.pow(Math.random(), 1 / ww);
            keyed.add(wi);
        }
        keyed.sort();
        for (Integer i = 0; i < keyed.size(); i++) items[i] = keyed[i].q;
    }

    /**
     * While a Practice session with weak-area focus is active on this cert: the weakest domain that has
     * fewer than FOCUS_DOMAIN_READY unclaimed Ready questions (so the pool generates for it), or null.
     */
    public static String focusDomainNeeded(Id certId, String certCode) {
        String likeTerm = '%;' + String.valueOf(certId) + ';%';
        Map<String, Decimal> weakest = new Map<String, Decimal>();
        for (Study_Session__c s : [
            SELECT Domain_Weights_JSON__c FROM Study_Session__c
            WHERE Status__c = :ACTIVE AND Mode__c = :MODE_PRACTICE AND Focus_Weak_Areas__c = true
                AND Cert_Codes__c LIKE :likeTerm
        ]) {
            Map<String, Decimal> w = parseFocusWeights(s.Domain_Weights_JSON__c).get(certCode);
            if (w == null) continue;
            for (String d : w.keySet()) {
                if (w.get(d) >= FOCUS_WEAK_WEIGHT && (!weakest.containsKey(d) || w.get(d) > weakest.get(d))) {
                    weakest.put(d, w.get(d));
                }
            }
        }
        if (weakest.isEmpty()) return null;
        Map<String, Integer> ready = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Domain__c d, COUNT(Id) n FROM Question__c
            WHERE Cert__c = :certId AND Status__c = 'Ready' AND Study_Session__c = null
            GROUP BY Domain__c
        ]) {
            ready.put((String) ar.get('d'), (Integer) ar.get('n'));
        }
        String best = null;
        for (String d : weakest.keySet()) {
            Integer have = ready.containsKey(d) ? ready.get(d) : 0;
            if (have >= FOCUS_DOMAIN_READY) continue;
            if (best == null || weakest.get(d) > weakest.get(best)) best = d;
        }
        return best;
    }

    /** One line for the session screen: the sections being emphasized. Null when focus is off. */
    public static String focusNote(Study_Session__c s) {
        if (s == null || s.Focus_Weak_Areas__c != true) return null;
        Map<String, Decimal> all = new Map<String, Decimal>();
        for (Map<String, Decimal> w : parseFocusWeights(s.Domain_Weights_JSON__c).values()) {
            for (String d : w.keySet()) {
                if (w.get(d) >= FOCUS_WEAK_WEIGHT && (!all.containsKey(d) || w.get(d) > all.get(d))) all.put(d, w.get(d));
            }
        }
        if (all.isEmpty()) return 'Weak-area focus is on, but your earlier answers show no clearly weak sections yet.';
        List<String> names = new List<String>(all.keySet());
        for (Integer i = 0; i < names.size(); i++) {
            for (Integer j = i + 1; j < names.size(); j++) {
                if (all.get(names[j]) > all.get(names[i])) {
                    String t = names[i];
                    names[i] = names[j];
                    names[j] = t;
                }
            }
        }
        List<String> top = new List<String>();
        for (String n : names) {
            if (top.size() >= 3) break;
            top.add(n);
        }
        return 'Focusing on your weaker sections: ' + String.join(top, ', ') + '.';
    }

    private static Question__c lockAndClaim(Id sessionId, List<Question__c> candidates) {
        for (Question__c c : candidates) {
            List<Question__c> locked = [
                SELECT Id FROM Question__c
                WHERE Id = :c.Id AND Study_Session__c = null AND Status__c = 'Ready'
                FOR UPDATE
            ];
            if (locked.isEmpty()) continue;
            Question__c q = locked[0];
            q.Study_Session__c = sessionId;
            q.Status__c = 'Served';
            q.Served_At__c = DateTime.now();
            update q;
            return currentQuestion(sessionId);
        }
        return null;
    }

    /**
     * Test mode: serve domains in proportion to the official weights. Prefers
     * the domain furthest below its quota; falls back to any Ready question
     * so the test never stalls on one domain's generation.
     */
    private static Question__c claimForTest(Study_Session__c s, Set<String> codes) {
        List<Cert__c> certs = [SELECT Id, Domains_JSON__c FROM Cert__c WHERE Cert_Code__c IN :codes LIMIT 1];
        Map<String, Integer> quotas = certs.isEmpty()
            ? new Map<String, Integer>()
            : domainQuotas(certs[0], s.Question_Target__c == null ? DEFAULT_TEST_QUESTIONS : s.Question_Target__c.intValue());
        Map<String, Integer> served = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Domain__c d, COUNT(Id) n FROM Question__c WHERE Study_Session__c = :s.Id GROUP BY Domain__c
        ]) {
            served.put((String) ar.get('d'), (Integer) ar.get('n'));
        }
        Map<String, List<Question__c>> byDomain = new Map<String, List<Question__c>>();
        List<Question__c> others = new List<Question__c>();
        for (Question__c c : [
            SELECT Id, Domain__c FROM Question__c
            WHERE Study_Session__c = null AND Status__c = 'Ready' AND Cert__r.Cert_Code__c IN :codes
            LIMIT 200
        ]) {
            if (c.Domain__c != null && quotas.containsKey(c.Domain__c)) {
                if (!byDomain.containsKey(c.Domain__c)) byDomain.put(c.Domain__c, new List<Question__c>());
                byDomain.get(c.Domain__c).add(c);
            } else {
                others.add(c);
            }
        }
        // order domains by remaining deficit (quota - served), largest first
        Map<String, String> orderMap = new Map<String, String>();
        for (String d : byDomain.keySet()) {
            Integer deficit = quotas.get(d) - (served.containsKey(d) ? served.get(d) : 0);
            orderMap.put(String.valueOf(1000 - deficit).leftPad(5, '0') + '|' + d, d);
        }
        List<String> keys = new List<String>(orderMap.keySet());
        keys.sort();
        List<Question__c> candidates = new List<Question__c>();
        for (String k : keys) {
            List<Question__c> domainGroup = byDomain.get(orderMap.get(k));
            shuffleRecords(domainGroup);
            candidates.addAll(domainGroup);
        }
        shuffleRecords(others);
        candidates.addAll(others);
        return lockAndClaim(s.Id, candidates);
    }

    private static void shuffleRecords(List<Question__c> items) {
        for (Integer i = items.size() - 1; i > 0; i--) {
            Integer j = (Integer) Math.floor(Math.random() * (i + 1));
            Question__c tmp = items[i];
            items[i] = items[j];
            items[j] = tmp;
        }
    }

    private static String formatQuestion(Question__c q, Id sessionId) {
        Integer n = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :sessionId] + 1;
        List<String> lines = new List<String>();
        String meta = q.Cert__r.Name
            + (String.isBlank(q.Domain__c) ? '' : ' · ' + q.Domain__c)
            + (q.Difficulty__c == null ? '' : ' · difficulty ' + q.Difficulty__c + '/5');
        lines.add('**Question ' + n + '** (' + meta + ')');
        lines.add('');
        lines.add(q.Stem__c);
        lines.add('');
        for (Map<String, String> o : options(q)) {
            lines.add('**' + o.get('key') + '.** ' + o.get('text'));
            lines.add(''); // chat surfaces collapse single newlines
        }
        Integer need = correctKeys(q).size();
        lines.add(need == 1
            ? '_Choose 1. Reply with the letter._'
            : '_Choose ' + need + '. Reply with the letters, e.g. "B, D"._');
        return String.join(lines, '\n');
    }

    public static List<Map<String, String>> options(Question__c q) {
        List<Map<String, String>> out = new List<Map<String, String>>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(q.Options_JSON__c)) {
            Map<String, Object> m = (Map<String, Object>) o;
            out.add(new Map<String, String>{
                'key' => String.valueOf(m.get('key')),
                'text' => String.valueOf(m.get('text'))
            });
        }
        return out;
    }

    public static List<String> correctKeys(Question__c q) {
        List<String> out = new List<String>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(q.Correct_JSON__c)) {
            out.add(String.valueOf(o).toUpperCase());
        }
        out.sort();
        return out;
    }

    private static String describeKeys(String optionsJson, String correctJson) {
        Question__c tmp = new Question__c(Options_JSON__c = optionsJson, Correct_JSON__c = correctJson);
        Map<String, String> textByKey = new Map<String, String>();
        for (Map<String, String> o : options(tmp)) textByKey.put(o.get('key'), o.get('text'));
        List<String> parts = new List<String>();
        for (String k : correctKeys(tmp)) parts.add(k + '. ' + textByKey.get(k));
        return String.join(parts, '; ');
    }

    /** Cert_Codes__c holds ;-delimited Cert__c Ids; returns the matching cert codes. */
    public static Set<String> sessionCodes(Study_Session__c s) {
        return codesForSessions(new List<Study_Session__c>{ s });
    }

    private static Set<String> codesForSessions(List<Study_Session__c> sessions) {
        Set<Id> certIds = new Set<Id>();
        for (Study_Session__c s : sessions) {
            if (String.isBlank(s.Cert_Codes__c)) continue;
            for (String part : s.Cert_Codes__c.split(';')) {
                if (String.isNotBlank(part)) certIds.add(Id.valueOf(part.trim()));
            }
        }
        Set<String> codes = new Set<String>();
        if (certIds.isEmpty()) return codes;
        for (Cert__c c : [SELECT Cert_Code__c FROM Cert__c WHERE Id IN :certIds]) codes.add(c.Cert_Code__c);
        return codes;
    }

    private static String noSessionMessage() {
        return 'You have no active practice session. Tell me which certification you want to practice and I will start one.';
    }

    public static Integer pct(Integer part, Integer whole) {
        if (whole == null || whole == 0) return 0;
        return (Integer) Math.round(100.0 * part / whole);
    }

    /**
     * Extracts option letters. Single-letter tokens count ("B and D" -> B,D;
     * the word "and" is ignored); a lone token made only of A-E letters is
     * split ("BD" -> B,D).
     */
    public static List<String> parseLetters(String input) {
        Set<String> out = new Set<String>();
        if (String.isBlank(input)) return new List<String>();
        List<String> tokens = new List<String>();
        for (String t : input.toUpperCase().split('[^A-Z]+')) {
            if (String.isNotBlank(t)) tokens.add(t);
        }
        if (tokens.size() == 1 && tokens[0].length() <= 5 && Pattern.matches('[A-E]+', tokens[0])) {
            for (Integer i = 0; i < tokens[0].length(); i++) out.add(tokens[0].substring(i, i + 1));
        } else {
            for (String t : tokens) {
                if (t.length() == 1 && 'ABCDE'.contains(t)) out.add(t);
            }
        }
        List<String> sorted = new List<String>(out);
        sorted.sort();
        return sorted;
    }

    private static List<String> splitList(String input) {
        List<String> out = new List<String>();
        if (String.isBlank(input)) return out;
        for (String t : input.split('[,;\\n]+')) {
            if (String.isNotBlank(t)) out.add(t.trim());
        }
        return out;
    }

    /** "AI-201=yes; DATA-CON-101=no" -> {AI-201: true, DATA-CON-101: false}. Codes may contain spaces/colons. */
    private static Map<String, Boolean> parseAnswers(String input) {
        Map<String, Boolean> out = new Map<String, Boolean>();
        if (String.isBlank(input)) return out;
        for (String pair : input.split('[,;]+')) {
            Integer eq = pair.lastIndexOf('=');
            if (eq < 1) continue;
            String v = pair.substring(eq + 1).trim().toLowerCase();
            out.put(pair.substring(0, eq).trim().toUpperCase(), v.startsWith('y') || v == 'true' || v == 'include');
        }
        return out;
    }
}
