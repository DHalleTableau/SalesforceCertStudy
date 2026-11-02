/**
 * Question generation: prompt building, response parsing, option shuffle,
 * validation, and cert-overview derivation. Port of claude_client.py and
 * the validation half of worker.py. All lessons from HISTORY.md carry over:
 * flat parallel arrays (never nested objects), exact option counts checked
 * in code, artifact stripping, per-option explanations assembled into
 * feedback AFTER the shuffle, length-bias rejection with least-biased
 * fallback.
 */
public without sharing class CertStudyGenerator {
    public static final Integer POOL_SIZE = 5;
    public static final Integer MAX_GROUNDING_CHARS = 60000;
    public static final Integer AVOID_STEMS_LIMIT = 40;
    public static final Integer MIN_FEEDBACK_LENGTH = 100;
    public static final Integer MIN_SENTENCE_LENGTH_FOR_DUPLICATE_CHECK = 15;
    public static final Decimal LENGTH_BIAS_MARGIN = 1.6;

    private static final List<String> KEY_LETTERS = new List<String>{ 'A', 'B', 'C', 'D', 'E' };
    private static final List<String> ARTIFACT_MARKERS = new List<String>{
        '</feedback_md>', '</invoke>', '<parameter', '</parameter>',
        '<function_calls>', '</function_calls>', '<invoke'
    };

    public class GeneratedQuestion {
        public String stem = '';
        public List<String> optionKeys = new List<String>();
        public List<String> optionTexts = new List<String>();
        public List<String> correct = new List<String>();
        public String feedbackMd = '';
        public Integer rawOptionCount = 0;
        public Boolean correctKeysValid = true;
        public String format;
        public Integer difficulty;
        public String domain;
        public String style;
    }

    // ---------------------------------------------------------------- rotation

    /** Mixed pool, no per-user ramp: cycles 1-5 (same as worker.py). */
    public static Integer nextDifficulty(Integer total) {
        return Math.mod(total, 5) + 1;
    }

    /** Every 6th question is multi-select. */
    public static String nextFormat(Integer total) {
        return Math.mod(total, 6) == 5 ? 'multi' : 'single';
    }

    /** 8-slot cycle: 5 terminology + one each of three scenario flavors. */
    public static String nextStyle(Integer total) {
        Integer slot = Math.mod(total, 8);
        if (slot == 5) return 'scenario-general';
        if (slot == 6) return 'scenario-first-action';
        if (slot == 7) return 'scenario-root-cause';
        return 'terminology';
    }

    /** Round-robin through the cert's derived domains; null = model chooses. */
    public static String nextDomain(Cert__c cert, Integer total) {
        List<Map<String, Object>> doms = domains(cert);
        if (doms.isEmpty()) return null;
        return String.valueOf(doms[Math.mod(total, doms.size())].get('name'));
    }

    public static List<Map<String, Object>> domains(Cert__c cert) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (cert == null || String.isBlank(cert.Domains_JSON__c)) return out;
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(cert.Domains_JSON__c)) {
                out.add((Map<String, Object>) o);
            }
        } catch (Exception e) {
            return new List<Map<String, Object>>();
        }
        return out;
    }

    // --------------------------------------------------------------- grounding

    /**
     * Primary sources first (labeled PRIMARY SOURCE), then additional, each
     * group shuffled; a random contiguous window if over maxChars so calls
     * do not always see the same prefix.
     */
    public static String assembleGrounding(Id certId, Integer maxChars) {
        List<Cert_Resource__c> primary = new List<Cert_Resource__c>();
        List<Cert_Resource__c> additional = new List<Cert_Resource__c>();
        for (Cert_Resource__c r : [
            SELECT URL__c, Role__c, Content__c
            FROM Cert_Resource__c
            WHERE Cert__c = :certId AND Content_Length__c > 0
        ]) {
            if (r.Role__c == 'Primary') {
                primary.add(r);
            } else {
                additional.add(r);
            }
        }
        shuffle(primary);
        shuffle(additional);
        List<Cert_Resource__c> ordered = new List<Cert_Resource__c>(primary);
        ordered.addAll(additional);

        List<String> sections = new List<String>();
        for (Cert_Resource__c r : ordered) {
            if (String.isBlank(r.Content__c)) continue;
            String label = r.Role__c == 'Primary' ? 'PRIMARY SOURCE' : 'ADDITIONAL SOURCE';
            String src = String.isBlank(r.URL__c) ? '(pasted material)' : r.URL__c;
            sections.add('=== ' + label + ': ' + src + ' ===\n' + r.Content__c.trim());
        }
        String full = String.join(sections, '\n\n');
        if (full.length() <= maxChars) return full;
        Integer start = (Integer) Math.floor(Math.random() * (full.length() - maxChars + 1));
        return full.substring(start, start + maxChars);
    }

    // ----------------------------------------------------------------- prompts

    public static String buildQuestionPrompt(
        String certName, String domain, Integer difficulty, String format,
        String style, String grounding, List<String> avoidStems
    ) {
        Integer numOptions = format == 'single' ? 4 : 5;
        String formatInstruction = format == 'single'
            ? 'This must be a SINGLE-select question: EXACTLY 4 options, EXACTLY 1 correct answer. Not 3, not 5 -- exactly 4 options.'
            : 'This must be a MULTI-select question: EXACTLY 5 options, EXACTLY 2 or 3 correct answers (graded all-or-nothing). Not 4, not 6 -- exactly 5 options.';
        String domainInstruction = String.isNotBlank(domain)
            ? 'Focus specifically on the domain/category: ' + domain + '.'
            : 'Choose an appropriate domain from the grounding content below.';

        String styleInstruction;
        if (style == 'scenario-general') {
            styleInstruction = 'Write this as a REALISTIC WORK SCENARIO question: describe a specific situation, request, or problem someone in this role would face, then ask what the correct action/approach is. Do NOT write a plain definition-recall question -- the user should have to apply the concept to the scenario, not just identify a term.';
        } else if (style == 'scenario-first-action') {
            styleInstruction = 'Write this as a PRIORITIZATION scenario: describe a specific situation, then ask what the FASTEST or FIRST thing to do is -- not just a correct action in the abstract, but the right first/immediate step among several plausible next steps. The wrong options should be things that are eventually reasonable but wrong AS THE FIRST STEP (wrong order, premature, or address a lower-priority concern first).';
        } else if (style == 'scenario-root-cause') {
            styleInstruction = 'Write this as a ROOT-CAUSE DIAGNOSIS scenario: describe a situation where something went wrong (an error, unexpected behavior, a failed outcome), then ask what the team/client MOST LIKELY did wrong to cause it. The wrong options should be plausible-sounding but incorrect explanations for the same observed symptom.';
        } else {
            styleInstruction = 'Emphasize terminology precision -- the user has identified terminology as their weakest area.';
        }

        List<String> lines = new List<String>();
        lines.add('You are writing one practice exam question for the Salesforce certification "' + certName + '".');
        lines.add('');
        lines.add(formatInstruction);
        lines.add(domainInstruction);
        lines.add('Difficulty: ' + difficulty + '/5 (1 = foundational recall, 5 = nuanced/scenario-based). At every difficulty level, wrong options must be genuinely plausible -- not throwaway distractors -- since real exam feedback on this cert found the actual exam options frequently very close together. At difficulty 4-5 specifically, make the options nearly tied: more than one may seem individually defensible, but exactly one is the MOST correct per the exam content, and its option_explanations entry must explain precisely why that one edges out the other close options.');
        lines.add(styleInstruction);
        if (avoidStems != null && !avoidStems.isEmpty()) {
            lines.add('');
            lines.add('Already asked -- cover a DIFFERENT aspect, term, or scenario, not a rephrasing of any of these:');
            for (String s : avoidStems) {
                lines.add('- ' + s.abbreviate(400));
            }
        }
        lines.add('');
        lines.add('Four common mistakes to avoid:');
        lines.add('1. Do NOT make the correct option(s) noticeably longer or more detailed than the wrong ones -- keep every option roughly the same length and level of detail, so length itself is never a clue to the answer.');
        lines.add('2. Do NOT restate, list, or describe the answer options within the stem itself -- the stem presents the scenario or question only.');
        lines.add('3. Each option text must be SHORT: a single phrase or at most one sentence, matching real Salesforce exam options. Put all reasoning in option_explanations, never in the option text.');
        lines.add('4. Keep the stem SHORT -- around 40-60 words (2-3 sentences). Only go longer if a scenario genuinely needs it, and stay well under 100 words.');
        lines.add('5. Do NOT write mirror-image options: no two options may be the same statement with terms swapped or reversed (e.g. "X defines A; Y builds B" vs "Y defines A; X builds B"). A swapped pair tells a test-savvy reader the answer is one of the two. Each wrong option must be wrong for a DIFFERENT reason (wrong term, wrong scope, wrong product area, wrong sequence).');
        lines.add('');
        lines.add('Ground the question in this exam content (do not invent facts outside it):');
        lines.add('---');
        lines.add(grounding);
        lines.add('---');
        lines.add('');
        lines.add('Respond with ONLY a single JSON object -- no markdown fences, no commentary before or after. Use exactly these keys, all flat arrays of plain strings (no nested objects):');
        lines.add('{');
        lines.add('  "stem": "the question text",');
        lines.add('  "option_keys": [exactly ' + numOptions + ' letters, e.g. "A","B",...],');
        lines.add('  "option_texts": [exactly ' + numOptions + ' option texts, same order as option_keys],');
        lines.add('  "correct": [the key(s) of the correct option(s)],');
        lines.add('  "option_explanations": [exactly ' + numOptions + ' explanations, same order as option_keys]');
        lines.add('}');
        lines.add('option_explanations must have one entry per option: for a correct option explain why it is correct; for each wrong option explain specifically why it is wrong. Each entry is a full, terminology-focused explanation, not a short summary -- it is shown to the user after they answer. Do not begin an explanation with a verdict word like "Correct" or "Incorrect" -- the app adds that label itself.');
        return String.join(lines, '\n');
    }

    public static String buildOverviewPrompt(String certName, String grounding) {
        List<String> lines = new List<String>();
        lines.add('Extract the exam overview details for the Salesforce certification "' + certName + '" from its exam guide text below.');
        lines.add('');
        lines.add('Exam guide text:');
        lines.add('---');
        lines.add(grounding);
        lines.add('---');
        lines.add('');
        lines.add('Respond with ONLY a single JSON object, no markdown fences, with exactly these keys:');
        lines.add('{"duration_min": integer, "num_questions": integer, "passing_score": integer percent, "domain_names": [strings], "domain_weights": [numbers, same order as domain_names, summing to ~100]}');
        lines.add('Use the numbers actually stated in the text; only estimate if a field genuinely is not stated.');
        return String.join(lines, '\n');
    }

    // ----------------------------------------------------------------- parsing

    public static GeneratedQuestion parseQuestion(
        String raw, String format, Integer difficulty, String domain, String style
    ) {
        GeneratedQuestion q = new GeneratedQuestion();
        q.format = format;
        q.difficulty = difficulty;
        q.domain = domain;
        q.style = style;

        Map<String, Object> m = parseJsonObject(raw);
        if (m == null) return q;

        q.stem = cleanText(asString(m.get('stem')));
        List<String> keys = normalizeKeys(asStringList(m.get('option_keys')));
        List<String> texts = asStringList(m.get('option_texts'));
        List<String> expl = asStringList(m.get('option_explanations'));
        Set<String> rawCorrect = new Set<String>(normalizeKeys(asStringList(m.get('correct'))));

        q.rawOptionCount = keys.size();
        if (keys.size() != texts.size() || keys.size() > KEY_LETTERS.size()) {
            return q; // count mismatch -> fails structural validation
        }
        q.correctKeysValid = new Set<String>(keys).containsAll(rawCorrect);

        Map<String, String> explByKey = new Map<String, String>();
        for (Integer i = 0; i < keys.size() && i < expl.size(); i++) {
            explByKey.put(keys[i], expl[i]);
        }

        // Shuffle which letter lands on which option, then build feedback
        // from per-option explanations using the FINAL letters.
        List<Integer> order = new List<Integer>();
        for (Integer i = 0; i < keys.size(); i++) order.add(i);
        shuffleInts(order);

        List<String> feedbackParts = new List<String>();
        for (Integer n = 0; n < order.size(); n++) {
            Integer i = order[n];
            String newKey = KEY_LETTERS[n];
            String optText = cleanText(texts[i]);
            Boolean isCorrect = rawCorrect.contains(keys[i]);
            q.optionKeys.add(newKey);
            q.optionTexts.add(optText);
            if (isCorrect) q.correct.add(newKey);
            String e = explByKey.containsKey(keys[i]) ? stripVerdict(cleanText(explByKey.get(keys[i]))) : '';
            if (String.isNotBlank(e)) {
                feedbackParts.add('**' + newKey + '. ' + optText + '** -- ' + (isCorrect ? 'Correct' : 'Incorrect') + ': ' + e);
            }
        }
        q.feedbackMd = String.join(feedbackParts, '\n\n');
        return q;
    }

    /** Applies derived overview fields to cert; returns false if unparseable. */
    public static Boolean applyOverview(String raw, Cert__c cert) {
        Map<String, Object> m = parseJsonObject(raw);
        if (m == null) return false;
        try {
            cert.Duration_Min__c = toDecimal(m.get('duration_min'));
            cert.Num_Questions__c = toDecimal(m.get('num_questions'));
            cert.Passing_Score__c = toDecimal(m.get('passing_score'));
            List<String> names = asStringList(m.get('domain_names'));
            List<String> weights = asStringList(m.get('domain_weights'));
            List<Map<String, Object>> doms = new List<Map<String, Object>>();
            for (Integer i = 0; i < names.size(); i++) {
                Map<String, Object> d = new Map<String, Object>{ 'name' => names[i] };
                if (i < weights.size()) d.put('weight_pct', toDecimal(weights[i]));
                doms.add(d);
            }
            if (!doms.isEmpty()) cert.Domains_JSON__c = JSON.serialize(doms);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    // -------------------------------------------------------------- validation

    /** Null if valid except possibly length bias; else the rejection reason. */
    public static String structuralReason(GeneratedQuestion q) {
        Integer expected = q.format == 'single' ? 4 : 5;
        if (q.rawOptionCount != expected || q.optionKeys.size() != expected) {
            return 'expected ' + expected + ' options, got ' + q.rawOptionCount;
        }
        Integer minC = q.format == 'single' ? 1 : 2;
        Integer maxC = q.format == 'single' ? 1 : 3;
        if (q.correct.size() < minC || q.correct.size() > maxC) {
            return 'expected ' + minC + '-' + maxC + ' correct, got ' + q.correct.size();
        }
        if (!q.correctKeysValid) return 'correct keys not a subset of option keys';
        if (String.isBlank(q.stem)) return 'missing stem';
        if (q.feedbackMd.length() < MIN_FEEDBACK_LENGTH) {
            return 'feedback too short after cleanup: ' + q.feedbackMd.length() + ' chars';
        }
        if (hasDuplicateSentence(q.stem)) return 'stem contains a duplicated sentence';
        return null;
    }

    /** Avg correct-option length / avg wrong-option length; null if n/a. */
    public static Decimal lengthBiasRatio(GeneratedQuestion q) {
        Set<String> correctSet = new Set<String>(q.correct);
        Decimal cSum = 0, wSum = 0;
        Integer cN = 0, wN = 0;
        for (Integer i = 0; i < q.optionKeys.size(); i++) {
            Integer len = q.optionTexts[i].length();
            if (correctSet.contains(q.optionKeys[i])) {
                cSum += len;
                cN++;
            } else {
                wSum += len;
                wN++;
            }
        }
        if (cN == 0 || wN == 0 || wSum == 0) return null;
        return (cSum / cN) / (wSum / wN);
    }

    public static String validityReason(GeneratedQuestion q) {
        String reason = structuralReason(q);
        if (reason != null) return reason;
        Decimal ratio = lengthBiasRatio(q);
        if (ratio != null && ratio > LENGTH_BIAS_MARGIN) {
            return 'length bias: correct options ' + ratio.setScale(2) + 'x longer than wrong ones';
        }
        return null;
    }

    public static Boolean hasDuplicateSentence(String value) {
        if (String.isBlank(value)) return false;
        Set<String> seen = new Set<String>();
        for (String s : value.split('(?<=[.?!])\\s+')) {
            String t = s.trim();
            if (t.length() < MIN_SENTENCE_LENGTH_FOR_DUPLICATE_CHECK) continue;
            if (seen.contains(t)) return true;
            seen.add(t);
        }
        return false;
    }

    public static Question__c toRecord(GeneratedQuestion q, Id certId) {
        List<Map<String, String>> options = new List<Map<String, String>>();
        for (Integer i = 0; i < q.optionKeys.size(); i++) {
            options.add(new Map<String, String>{ 'key' => q.optionKeys[i], 'text' => q.optionTexts[i] });
        }
        return new Question__c(
            Cert__c = certId,
            Domain__c = q.domain == null ? null : q.domain.abbreviate(255),
            Difficulty__c = q.difficulty,
            Format__c = q.format,
            Style__c = q.style,
            Stem__c = q.stem.abbreviate(32768),
            Options_JSON__c = JSON.serialize(options),
            Correct_JSON__c = JSON.serialize(q.correct),
            Feedback_MD__c = q.feedbackMd.abbreviate(131072),
            Status__c = 'Ready'
        );
    }

    // ----------------------------------------------------------------- helpers

    public static String stripArtifacts(String value) {
        if (value == null) return '';
        Integer earliest = value.length();
        for (String marker : ARTIFACT_MARKERS) {
            Integer idx = value.indexOf(marker);
            if (idx != -1 && idx < earliest) earliest = idx;
        }
        return value.substring(0, earliest);
    }

    /** Drops a leading "Correct." / "Incorrect:" etc. -- the feedback line already carries the label. */
    public static String stripVerdict(String value) {
        if (value == null) return '';
        return value.replaceFirst('(?i)^\\s*(correct|incorrect|wrong|right)\\s*[.!:\\-]*\\s+', '');
    }

    private static String cleanText(String value) {
        return stripArtifacts(value).trim();
    }

    /** Tolerates fences/commentary: parses from first { to last }. */
    public static Map<String, Object> parseJsonObject(String raw) {
        if (String.isBlank(raw)) return null;
        Integer s = raw.indexOf('{');
        Integer e = raw.lastIndexOf('}');
        if (s < 0 || e <= s) return null;
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(raw.substring(s, e + 1));
        } catch (Exception ex) {
            return null;
        }
    }

    private static String asString(Object o) {
        return o == null ? '' : String.valueOf(o);
    }

    private static List<String> asStringList(Object o) {
        List<String> out = new List<String>();
        if (o instanceof List<Object>) {
            for (Object item : (List<Object>) o) {
                if (item != null) out.add(String.valueOf(item));
            }
        }
        return out;
    }

    private static List<String> normalizeKeys(List<String> keys) {
        List<String> out = new List<String>();
        for (String k : keys) out.add(k.trim().toUpperCase());
        return out;
    }

    private static Decimal toDecimal(Object o) {
        if (o == null) return null;
        return Decimal.valueOf(String.valueOf(o).trim());
    }

    private static void shuffle(List<SObject> items) {
        for (Integer i = items.size() - 1; i > 0; i--) {
            Integer j = (Integer) Math.floor(Math.random() * (i + 1));
            SObject tmp = items[i];
            items[i] = items[j];
            items[j] = tmp;
        }
    }

    private static void shuffleInts(List<Integer> items) {
        for (Integer i = items.size() - 1; i > 0; i--) {
            Integer j = (Integer) Math.floor(Math.random() * (i + 1));
            Integer tmp = items[i];
            items[i] = items[j];
            items[j] = tmp;
        }
    }
}
