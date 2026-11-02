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

    // ------------------------------------------------------------- identity

    public static String resolveUserKey(String userKey) {
        String k = String.isBlank(userKey) ? UserInfo.getUserEmail() : userKey;
        return k.trim().toLowerCase();
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

    public static String startSession(String userKey, String certCodesText, String prereqAnswersText) {
        String key = resolveUserKey(userKey);

        Map<String, Cert__c> certsByCode = new Map<String, Cert__c>();
        for (Cert__c c : [
            SELECT Id, Name, Cert_Code__c, Is_Aggregate__c, Duration_Min__c, Num_Questions__c,
                Passing_Score__c, Domains_JSON__c, Grounding_Chars__c
            FROM Cert__c
        ]) {
            certsByCode.put(c.Cert_Code__c.toUpperCase(), c);
        }

        List<String> selected = new List<String>();
        List<String> unknown = new List<String>();
        for (String token : splitList(certCodesText)) {
            String code = token.toUpperCase();
            if (certsByCode.containsKey(code)) {
                if (!selected.contains(code)) selected.add(code);
            } else {
                unknown.add(token);
            }
        }
        if (!unknown.isEmpty() || selected.isEmpty()) {
            return 'I could not find these certification codes: ' + String.join(unknown, ', ')
                + '. Use Find Certifications to look up the exact code.';
        }

        Resolution res = resolveCerts(selected, parseAnswers(prereqAnswersText));
        if (res.pendingPrompt != null) {
            Cert__c c = certsByCode.get(res.pendingPrompt);
            List<String> names = new List<String>();
            for (Cert_Prerequisite__c e : [
                SELECT Prereq_Cert__r.Name FROM Cert_Prerequisite__c WHERE Cert__c = :c.Id
            ]) {
                names.add(e.Prereq_Cert__r.Name);
            }
            return 'NEEDS_ANSWER (' + res.pendingPrompt + '): ' + c.Name + ' has prerequisite certifications: '
                + String.join(names, ', ') + '. Should questions on those prerequisites be included too? (yes/no)';
        }

        List<String> codes = new List<String>(res.resolved);
        codes.sort();
        List<String> ids = new List<String>();
        for (String code : codes) {
            if (certsByCode.containsKey(code)) ids.add(String.valueOf(certsByCode.get(code).Id));
        }
        String delimited = ';' + String.join(ids, ';') + ';';
        if (delimited.length() > 255) {
            return 'That selection expands to too many certifications for one session. Please pick fewer.';
        }

        endSessions([SELECT Id FROM Study_Session__c WHERE User_Key__c = :key AND Status__c = :ACTIVE]);

        Study_Session__c s = new Study_Session__c(
            User_Key__c = key,
            Cert_Codes__c = delimited,
            Status__c = ACTIVE,
            Started_At__c = DateTime.now(),
            Last_Activity__c = DateTime.now()
        );
        insert s;
        CertStudyPoolJob.requestTopUp(new Set<String>(codes));

        List<String> lines = new List<String>{ '**Practice session started.**', '' };
        for (String code : codes) {
            Cert__c c = certsByCode.get(code);
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
        lines.add(serveNext(s));
        return String.join(lines, '\n');
    }

    public static String nextQuestion(String userKey) {
        Study_Session__c s = activeSession(resolveUserKey(userKey));
        if (s == null) return noSessionMessage();
        return serveNext(s);
    }

    public static String submitAnswer(String userKey, String answerText) {
        Study_Session__c s = activeSession(resolveUserKey(userKey));
        if (s == null) return noSessionMessage();

        Question__c q = currentQuestion(s.Id);
        if (q == null) {
            return 'There is no question waiting for an answer.\n\n' + serveNext(s);
        }

        List<String> chosen = parseLetters(answerText);
        Set<String> validKeys = new Set<String>();
        for (Map<String, String> o : options(q)) validKeys.add(o.get('key'));
        if (chosen.isEmpty() || !validKeys.containsAll(chosen)) {
            return 'Please answer with the option letter(s) shown, for example "B" or "B, D".';
        }

        List<String> correct = correctKeys(q);
        Boolean isCorrect = new Set<String>(chosen).equals(new Set<String>(correct));

        insert new Answer__c(
            Study_Session__c = s.Id,
            Question__c = q.Id,
            User_Answer__c = String.join(chosen, ','),
            Is_Correct__c = isCorrect,
            Answered_At__c = DateTime.now()
        );
        q.Status__c = 'Answered';
        update q;
        s.Last_Activity__c = DateTime.now();
        update s;

        Integer total = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id];
        Integer right = [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id AND Is_Correct__c = true];

        List<String> lines = new List<String>();
        lines.add(isCorrect
            ? '✅ **Correct!**'
            : '❌ **Not quite.** You chose ' + String.join(chosen, ', ') + '; the correct answer is ' + String.join(correct, ', ') + '.');
        lines.add('');
        lines.add('Score so far: ' + right + '/' + total + ' (' + pct(right, total) + '%)');
        lines.add('');
        lines.add('**Explanation**');
        lines.add('');
        lines.add(q.Feedback_MD__c);
        lines.add('');
        lines.add('---');
        lines.add('');
        lines.add(serveNext(s));
        return String.join(lines, '\n');
    }

    public static String sessionSummary(String userKey, Boolean endIt) {
        String key = resolveUserKey(userKey);
        List<Study_Session__c> sessions = [
            SELECT Id, Cert_Codes__c, Status__c, Started_At__c
            FROM Study_Session__c
            WHERE User_Key__c = :key
            ORDER BY Started_At__c DESC
            LIMIT 1
        ];
        if (sessions.isEmpty()) return 'You have no practice sessions yet. ' + noSessionMessage();
        Study_Session__c s = sessions[0];

        List<Answer__c> answers = [
            SELECT Is_Correct__c, User_Answer__c, Question__r.Stem__c, Question__r.Domain__c,
                Question__r.Correct_JSON__c, Question__r.Options_JSON__c, Question__r.Cert__r.Name
            FROM Answer__c
            WHERE Study_Session__c = :s.Id
            ORDER BY Answered_At__c
        ];

        Integer right = 0;
        Map<String, Integer[]> byArea = new Map<String, Integer[]>(); // area -> [right, total]
        List<String> missed = new List<String>();
        for (Answer__c a : answers) {
            if (a.Is_Correct__c) right++;
            String area = a.Question__r.Cert__r.Name
                + (String.isBlank(a.Question__r.Domain__c) ? '' : ' / ' + a.Question__r.Domain__c);
            if (!byArea.containsKey(area)) byArea.put(area, new Integer[]{ 0, 0 });
            Integer[] counts = byArea.get(area);
            if (a.Is_Correct__c) counts[0] = counts[0] + 1;
            counts[1] = counts[1] + 1;
            if (!a.Is_Correct__c && missed.size() < 10) {
                missed.add('- ' + a.Question__r.Stem__c.abbreviate(200) + '\n  Correct: '
                    + describeKeys(a.Question__r.Options_JSON__c, a.Question__r.Correct_JSON__c)
                    + ' | You chose: ' + a.User_Answer__c);
            }
        }

        if (endIt && s.Status__c == ACTIVE) {
            endSessions(new List<Study_Session__c>{ s });
        }

        List<String> lines = new List<String>();
        lines.add('**Session summary**' + (endIt ? ' (session ended)' : ''));
        lines.add('');
        lines.add('Answered: ' + answers.size() + ' | Correct: ' + right + ' (' + pct(right, answers.size()) + '%)');
        if (!byArea.isEmpty()) {
            List<String> areaLines = new List<String>();
            for (String area : byArea.keySet()) {
                Integer[] c = byArea.get(area);
                // zero-padded sort key so a plain string sort puts the weakest first
                areaLines.add(String.valueOf(pct(c[0], c[1])).leftPad(3, '0') + '|'
                    + pct(c[0], c[1]) + '% -- ' + area + ' (' + c[0] + '/' + c[1] + ')');
            }
            areaLines.sort();
            lines.add('');
            lines.add('**By area (weakest first)**');
            for (String l : areaLines) lines.add('- ' + l.substringAfter('|'));
        }
        if (!missed.isEmpty()) {
            lines.add('');
            lines.add('**Questions to review**');
            lines.addAll(missed);
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

    private static Study_Session__c activeSession(String key) {
        List<Study_Session__c> rows = [
            SELECT Id, Cert_Codes__c, Status__c FROM Study_Session__c
            WHERE User_Key__c = :key AND Status__c = :ACTIVE
            ORDER BY Started_At__c DESC LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Question__c currentQuestion(Id sessionId) {
        List<Question__c> rows = [
            SELECT Id, Stem__c, Options_JSON__c, Correct_JSON__c, Feedback_MD__c, Domain__c,
                Difficulty__c, Format__c, Cert__r.Name
            FROM Question__c
            WHERE Study_Session__c = :sessionId AND Status__c = 'Served'
            ORDER BY Served_At__c DESC LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** Re-shows the unanswered question if there is one; otherwise claims the next Ready row. */
    private static String serveNext(Study_Session__c s) {
        Question__c current = currentQuestion(s.Id);
        if (current != null) return formatQuestion(current, s.Id);

        Set<String> codes = sessionCodes(s);
        Question__c claimed = claimFromPool(s.Id, codes);
        CertStudyPoolJob.requestTopUp(codes);
        if (claimed == null) {
            return '⏳ Your next question is still being generated (usually under a minute). Ask me for the next question again shortly.';
        }
        return formatQuestion(claimed, s.Id);
    }

    /**
     * SOQL locking cannot be combined with ORDER BY, so: read a batch of the
     * oldest candidates, shuffle (mixes certs in multi-cert sessions), then
     * lock-and-recheck one at a time until a claim succeeds.
     */
    private static Question__c claimFromPool(Id sessionId, Set<String> codes) {
        List<Question__c> candidates = [
            SELECT Id FROM Question__c
            WHERE Study_Session__c = null AND Status__c = 'Ready' AND Cert__r.Cert_Code__c IN :codes
            ORDER BY CreatedDate LIMIT 20
        ];
        for (Integer i = candidates.size() - 1; i > 0; i--) {
            Integer j = (Integer) Math.floor(Math.random() * (i + 1));
            Question__c tmp = candidates[i];
            candidates[i] = candidates[j];
            candidates[j] = tmp;
        }
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

    private static List<Map<String, String>> options(Question__c q) {
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

    private static List<String> correctKeys(Question__c q) {
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
    private static Set<String> sessionCodes(Study_Session__c s) {
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

    private static Integer pct(Integer part, Integer whole) {
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
