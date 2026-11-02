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
                Passing_Score__c, Domains_JSON__c, Grounding_Chars__c
            FROM Cert__c
        ]) {
            certsByCode.put(c.Cert_Code__c.toUpperCase(), c);
        }
        return certsByCode;
    }

    public static StartOutcome startSessionCore(String key, List<String> requestedCodes, Map<String, Boolean> answers) {
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
            Status__c = ACTIVE,
            Started_At__c = DateTime.now(),
            Last_Activity__c = DateTime.now()
        );
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
        insert new Answer__c(
            Study_Session__c = s.Id,
            Question__c = q.Id,
            User_Answer__c = chosenKey,
            Is_Correct__c = out.isCorrect,
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
            SELECT Id, Cert_Codes__c, Status__c, Started_At__c, Mode__c, Question_Target__c, Timer_Mode__c, Time_Limit_Min__c, Elapsed_Seconds__c, Resumed_At__c, Paused__c, Completed_At__c
            FROM Study_Session__c
            WHERE User_Key__c = :key
            ORDER BY Started_At__c DESC
            LIMIT 1
        ];
        return sessions.isEmpty() ? null : sessions[0];
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
        public Integer target = 0;
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
        Study_Session__c s = new Study_Session__c(
            User_Key__c = key,
            User__c = userIdFor(key),
            Cert_Codes__c = ';' + c.Id + ';',
            Mode__c = MODE_TEST,
            Status__c = ACTIVE,
            Question_Target__c = c.Num_Questions__c != null ? c.Num_Questions__c : DEFAULT_TEST_QUESTIONS,
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
        if (s.Completed_At__c == null) {
            stopClock(s);
            s.Completed_At__c = DateTime.now();
            s.Paused__c = false;
            update s;
        }
        TestResult r = testResult(s);
        r.timedOut = timedOut == true;
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
        r.limitMin = s.Time_Limit_Min__c == null ? null : s.Time_Limit_Min__c.intValue();
        r.strictTimer = s.Timer_Mode__c == 'Strict';
        r.elapsedSeconds = elapsedSeconds(s);
        r.passingEstimated = r.cert == null || r.cert.Passing_Score__c == null;
        r.passing = r.passingEstimated ? DEFAULT_PASSING_SCORE : r.cert.Passing_Score__c.intValue();

        Map<String, DomainResult> byName = new Map<String, DomainResult>();
        if (r.cert != null) {
            Map<String, Integer> quotas = domainQuotas(r.cert, r.target);
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
        for (Answer__c a : [
            SELECT Is_Correct__c, User_Answer__c, Question__r.Stem__c, Question__r.Domain__c,
                Question__r.Correct_JSON__c, Question__r.Options_JSON__c, Question__r.Feedback_MD__c,
                Question__r.Cert__r.Name
            FROM Answer__c WHERE Study_Session__c = :s.Id ORDER BY Answered_At__c
        ]) {
            r.answered++;
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
        r.officialPct = pct(r.correct, r.target > 0 ? r.target : r.answered);
        r.passed = r.officialPct >= r.passing;
        r.answeredPct = pct(r.correct, r.answered);
        r.answeredLikelyPass = r.answered > 0 && r.answeredPct >= r.passing;

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

    // ------------------------------------------------- agent (markdown) API

    public static String startSession(String userKey, String certCodesText, String prereqAnswersText) {
        String key = resolveUserKey(userKey);
        StartOutcome res = startSessionCore(key, splitList(certCodesText), parseAnswers(prereqAnswersText));
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
            SELECT Id, Cert_Codes__c, Status__c, Started_At__c, Mode__c, Question_Target__c, Timer_Mode__c, Time_Limit_Min__c, Elapsed_Seconds__c, Resumed_At__c, Paused__c, Completed_At__c FROM Study_Session__c
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
            SELECT Id, Mode__c, Question_Target__c, Cert_Codes__c FROM Study_Session__c WHERE Id = :sessionId
        ];
        if (!sess.isEmpty() && isTest(sess[0])) return claimForTest(sess[0], codes);
        Set<String> recentDomains = new Set<String>();
        Id lastCert = null;
        for (Question__c r : [
            SELECT Domain__c, Cert__c FROM Question__c
            WHERE Study_Session__c = :sessionId ORDER BY Served_At__c DESC LIMIT 3
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
            SELECT Id, Domain__c, Cert__c FROM Question__c
            WHERE Study_Session__c = null AND Status__c = 'Ready' AND Cert__r.Cert_Code__c IN :codes
            LIMIT 200
        ]) {
            Boolean sameCert = lastCert != null && c.Cert__c == lastCert;
            Boolean sameDomain = String.isNotBlank(c.Domain__c) && recentDomains.contains(c.Domain__c);
            Integer idx = sameCert ? (sameDomain ? 3 : 1) : (sameDomain ? 2 : 0);
            buckets[idx].add(c);
        }
        List<Question__c> candidates = new List<Question__c>();
        for (List<Question__c> b : buckets) {
            shuffleRecords(b);
            candidates.addAll(b);
        }
        return lockAndClaim(sessionId, candidates);
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
