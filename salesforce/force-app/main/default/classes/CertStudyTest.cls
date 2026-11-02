@IsTest
private class CertStudyTest {
    private class FakeException extends Exception {}

    private class FakeLlm implements CertStudyLlm.Client {
        public Boolean fail = false;
        public Boolean biased = false;
        public Integer calls = 0;
        public String generate(String prompt) {
            calls++;
            if (fail) throw new FakeException('boom');
            if (prompt.contains('exam overview')) {
                return '{"duration_min":105,"num_questions":60,"passing_score":73,'
                    + '"domain_names":["Prompting","Agents"],"domain_weights":[40,60]}';
            }
            Integer n = prompt.contains('MULTI-select') ? 5 : (prompt.contains('EXACTLY 3 options') ? 3 : 4);
            return questionJson(n, biased);
        }
    }

    private static String questionJson(Integer n, Boolean biased) {
        Boolean multi = n == 5;
        List<String> keys = new List<String>{ 'A', 'B', 'C', 'D', 'E' };
        while (keys.size() > n) keys.remove(keys.size() - 1);
        List<String> texts = new List<String>();
        List<String> expl = new List<String>();
        for (String k : keys) {
            texts.add('Option text ' + k);
            expl.add('Explanation for option ' + k + ' that is long enough to pass the minimum feedback length check.');
        }
        if (biased) texts[0] = 'Option text A that is very much longer than every other option in this question';
        Map<String, Object> m = new Map<String, Object>{
            'stem' => 'Which feature grounds agent responses in trusted data?',
            'option_keys' => keys,
            'option_texts' => texts,
            'correct' => multi ? new List<String>{ 'A', 'B' } : new List<String>{ 'A' },
            'option_explanations' => expl
        };
        return 'Sure:\n```json\n' + JSON.serialize(m) + '\n```';
    }

    @TestSetup
    static void setup() {
        Cert__c ai = new Cert__c(Name = 'Agentforce Specialist', Cert_Code__c = 'AI-201');
        Cert__c found = new Cert__c(Name = 'Platform Foundations', Cert_Code__c = 'FOUND-101');
        Cert__c agg = new Cert__c(Name = 'Agentforce Architect', Cert_Code__c = 'AGG-1', Is_Aggregate__c = true);
        Cert__c empty = new Cert__c(Name = 'No Content Cert', Cert_Code__c = 'EMPTY-1');
        insert new List<Cert__c>{ ai, found, agg, empty };
        insert new List<Cert_Prerequisite__c>{
            new Cert_Prerequisite__c(Cert__c = ai.Id, Prereq_Cert__c = found.Id),
            new Cert_Prerequisite__c(Cert__c = agg.Id, Prereq_Cert__c = ai.Id)
        };
        insert new List<Cert_Resource__c>{
            new Cert_Resource__c(Cert__c = ai.Id, Role__c = 'Primary', URL__c = 'https://example.com/ai',
                Content__c = 'Agentforce exam guide content. Prompt Builder grounds prompts.'),
            new Cert_Resource__c(Cert__c = ai.Id, Role__c = 'Additional', Content__c = 'Extra notes.'),
            new Cert_Resource__c(Cert__c = found.Id, Role__c = 'Primary', Content__c = 'Foundations guide.')
        };
    }

    private static List<Map<String, Object>> toMaps(String jsonText) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(jsonText)) out.add((Map<String, Object>) o);
        return out;
    }

    private static Id certId(String code) {
        return [SELECT Id FROM Cert__c WHERE Cert_Code__c = :code].Id;
    }

    private static Cert__c cert(String code) {
        return [
            SELECT Id, Name, Cert_Code__c, Domains_JSON__c, Overview_Derived_At__c, Duration_Min__c,
                Num_Questions__c, Passing_Score__c, Last_Generation_Error__c, Top_Up_Started_At__c,
                Grounding_Chars__c
            FROM Cert__c WHERE Cert_Code__c = :code
        ];
    }

    private static void addReady(String code, Integer n, String format) {
        Id cid = certId(code);
        List<Question__c> qs = new List<Question__c>();
        for (Integer i = 0; i < n; i++) {
            qs.add(new Question__c(
                Cert__c = cid,
                Stem__c = 'Stem ' + i,
                Format__c = format,
                Difficulty__c = 1,
                Domain__c = 'Agents',
                Options_JSON__c = '[{"key":"A","text":"Alpha"},{"key":"B","text":"Bravo"},{"key":"C","text":"Charlie"},{"key":"D","text":"Delta"}]',
                Correct_JSON__c = format == 'multi' ? '["A","C"]' : '["A"]',
                Feedback_MD__c = '**A. Alpha** -- Correct: because.',
                Status__c = 'Ready'
            ));
        }
        insert qs;
    }

    /** Sessions store ;-delimited Cert__c Ids. */
    private static String ids(List<String> codes) {
        List<String> out = new List<String>();
        for (String c : codes) out.add(String.valueOf(certId(c)));
        return ';' + String.join(out, ';') + ';';
    }

    private static void activeSession(String code) {
        insert new Study_Session__c(
            User_Key__c = 'job@example.com', Cert_Codes__c = ids(new List<String>{ code }),
            Status__c = 'Active', Started_At__c = DateTime.now(), Last_Activity__c = DateTime.now()
        );
    }

    private static void markOverviewDone(String code) {
        Cert__c c = cert(code);
        c.Overview_Derived_At__c = DateTime.now();
        c.Domains_JSON__c = '[{"name":"Agents","weight_pct":100}]';
        update c;
    }

    @IsTest
    static void triggerFeedsRollup() {
        Assert.isTrue(cert('AI-201').Grounding_Chars__c > 0);
        Decimal empty = cert('EMPTY-1').Grounding_Chars__c;
        Assert.isTrue(empty == null || empty == 0);
    }

    @IsTest
    static void findCertsListsOnlyUsable() {
        String all = CertStudyService.findCerts(null);
        Assert.isTrue(all.contains('AI-201'));
        Assert.isTrue(all.contains('AGG-1'));
        Assert.isFalse(all.contains('EMPTY-1'));
        Assert.isTrue(CertStudyService.findCerts('agentforce spec').contains('AI-201'));
        Assert.isTrue(CertStudyService.findCerts('zzz').contains('No certifications'));

        CertStudy_FindCerts.Request r = new CertStudy_FindCerts.Request();
        r.searchText = 'AI';
        Assert.isTrue(CertStudy_FindCerts.run(new List<CertStudy_FindCerts.Request>{ r })[0].message.contains('AI-201'));
    }

    @IsTest
    static void aggregateWalksSilentlyAndPromptsAtNonAggregateLevel() {
        CertStudyLlm.instance = new FakeLlm();
        String msg = CertStudyService.startSession('learner@example.com', 'agg-1', null);
        Assert.isTrue(msg.startsWith('NEEDS_ANSWER (AI-201)'), msg);

        msg = CertStudyService.startSession('learner@example.com', 'AGG-1', 'AI-201=no');
        Assert.isTrue(msg.contains('Practice session started'), msg);
        Assert.areEqual(ids(new List<String>{ 'AGG-1', 'AI-201' }), [
            SELECT Cert_Codes__c FROM Study_Session__c WHERE Status__c = 'Active'
        ].Cert_Codes__c);

        msg = CertStudyService.startSession('learner@example.com', 'AI-201', 'AI-201=yes');
        List<Study_Session__c> active = [SELECT Cert_Codes__c FROM Study_Session__c WHERE Status__c = 'Active'];
        Assert.areEqual(1, active.size(), 'starting a new session ends the old one');
        Assert.areEqual(ids(new List<String>{ 'AI-201', 'FOUND-101' }), active[0].Cert_Codes__c);

        Assert.isTrue(CertStudyService.startSession('learner@example.com', 'NOPE', null).contains('could not find'));
    }

    @IsTest
    static void fullNameCodesWithSpacesAndColons() {
        CertStudyLlm.instance = new FakeLlm();
        Cert__c named = new Cert__c(Name = 'Consumer Goods Cloud: Trade Promotion', Cert_Code__c = 'Consumer Goods Cloud: Trade Promotion');
        insert named;
        insert new Cert_Prerequisite__c(Cert__c = named.Id, Prereq_Cert__c = certId('AI-201'));
        insert new Cert_Resource__c(Cert__c = named.Id, Role__c = 'Primary', Content__c = 'Guide text.');
        String key = 'names@example.com';
        String msg = CertStudyService.startSession(key, 'consumer goods cloud: trade promotion', null);
        Assert.isTrue(msg.startsWith('NEEDS_ANSWER (CONSUMER GOODS CLOUD: TRADE PROMOTION)'), msg);
        msg = CertStudyService.startSession(key, 'Consumer Goods Cloud: Trade Promotion', 'Consumer Goods Cloud: Trade Promotion=no');
        Assert.isTrue(msg.contains('Practice session started'), msg);
        Assert.isTrue(CertStudyService.findCerts('Consumer').contains('- Consumer Goods Cloud: Trade Promotion'));
        Assert.isTrue(CertStudyService.isCertNeeded(named.Id));
    }

    @IsTest
    static void serveGradeAndSummarize() {
        CertStudyLlm.instance = new FakeLlm();
        addReady('AI-201', 3, 'single');
        String key = 'learner@example.com';

        String msg = CertStudyService.startSession(key, 'AI-201', 'AI-201=no');
        Assert.isTrue(msg.contains('**Question 1**'), msg);
        Assert.isTrue(CertStudyService.nextQuestion(key).contains('**Question 1**'), 'unanswered question is re-shown');
        Assert.isTrue(CertStudyService.submitAnswer(key, 'xyz').contains('Please answer'));

        msg = CertStudyService.submitAnswer(key, 'a');
        Assert.isTrue(msg.contains('Correct!'), msg);
        Assert.isTrue(msg.contains('**Question 2**'), msg);

        msg = CertStudyService.submitAnswer(key, 'I pick B');
        Assert.isTrue(msg.contains('Not quite'), msg);
        Assert.isTrue(msg.contains('Score so far: 1/2'), msg);

        msg = CertStudyService.sessionSummary(key, true);
        Assert.isTrue(msg.contains('Answered: 2'), msg);
        Assert.isTrue(msg.contains('Questions to review'), msg);
        Assert.isTrue(msg.contains('session ended'), msg);
        Assert.areEqual(1, [
            SELECT COUNT() FROM Question__c WHERE Status__c = 'Ready' AND Study_Session__c = null
        ], 'served-but-unanswered question goes back to the pool');

        Assert.isTrue(CertStudyService.nextQuestion(key).contains('no active practice session'));
        Assert.isTrue(CertStudyService.submitAnswer(key, 'A').contains('no active practice session'));
    }

    @IsTest
    static void multiSelectNeedsAllCorrectKeys() {
        CertStudyLlm.instance = new FakeLlm();
        addReady('AI-201', 2, 'multi');
        String key = 'multi@example.com';
        Assert.isTrue(CertStudyService.startSession(key, 'AI-201', 'AI-201=no').contains('Choose 2'));
        Assert.isTrue(CertStudyService.submitAnswer(key, 'A').contains('Not quite'), 'partial is wrong');
        Assert.isTrue(CertStudyService.submitAnswer(key, 'C, A').contains('Correct!'));
        // An agent re-calling SubmitAnswer with the same letters right away is ignored, not graded again.
        Assert.isTrue(CertStudyService.submitAnswer(key, 'A, C').startsWith(CertStudyService.DUPLICATE_PREFIX));
        Assert.areEqual(2, [SELECT COUNT() FROM Answer__c]);
    }

    @IsTest
    static void emptyPoolShowsWaitingAndLocksTopUp() {
        CertStudyLlm.instance = new FakeLlm();
        String msg = CertStudyService.startSession('learner@example.com', 'AI-201', 'AI-201=no');
        Assert.isTrue(msg.contains('still being generated'), msg);
        Assert.isNotNull(cert('AI-201').Top_Up_Started_At__c);
        Assert.isNull(cert('EMPTY-1').Top_Up_Started_At__c);
    }

    @IsTest
    static void invocableWrappers() {
        CertStudyLlm.instance = new FakeLlm();
        addReady('AI-201', 2, 'single');

        CertStudy_StartSession.Request s = new CertStudy_StartSession.Request();
        s.certCodes = 'AI-201';
        s.prerequisiteAnswers = 'AI-201=no';
        s.userKey = 'U123SLACK';
        Assert.isTrue(CertStudy_StartSession.run(new List<CertStudy_StartSession.Request>{ s })[0].message.contains('Question 1'));

        CertStudy_NextQuestion.Request n = new CertStudy_NextQuestion.Request();
        n.userKey = 'U123SLACK';
        Assert.isTrue(CertStudy_NextQuestion.run(new List<CertStudy_NextQuestion.Request>{ n })[0].message.contains('Question 1'));

        CertStudy_SubmitAnswer.Request a = new CertStudy_SubmitAnswer.Request();
        a.userKey = 'U123SLACK';
        a.answer = 'A';
        Assert.isTrue(CertStudy_SubmitAnswer.run(new List<CertStudy_SubmitAnswer.Request>{ a })[0].message.contains('Correct!'));

        CertStudy_SessionSummary.Request sum = new CertStudy_SessionSummary.Request();
        sum.userKey = 'U123SLACK';
        sum.endSession = false;
        Assert.isTrue(CertStudy_SessionSummary.run(new List<CertStudy_SessionSummary.Request>{ sum })[0].message.contains('Answered: 1'));
        Assert.isTrue(CertStudyService.sessionSummary('nobody@example.com', false).contains('no practice sessions'));
    }

    @IsTest
    static void poolJobDerivesOverviewFirst() {
        CertStudyLlm.instance = new FakeLlm();
        activeSession('AI-201');
        Test.startTest();
        System.enqueueJob(new CertStudyPoolJob(certId('AI-201')));
        Test.stopTest();

        Cert__c c = cert('AI-201');
        Assert.areEqual(60, c.Num_Questions__c.intValue());
        Assert.areEqual(73, c.Passing_Score__c.intValue());
        Assert.isNotNull(c.Overview_Derived_At__c);
        Assert.isTrue(c.Domains_JSON__c.contains('Agents'));
        Assert.isNotNull(c.Top_Up_Started_At__c, 'chain continues to generation');
    }

    @IsTest
    static void poolJobGeneratesValidQuestion() {
        CertStudyLlm.instance = new FakeLlm();
        markOverviewDone('AI-201');
        activeSession('AI-201');
        Test.startTest();
        System.enqueueJob(new CertStudyPoolJob(certId('AI-201')));
        Test.stopTest();

        Question__c q = [SELECT Status__c, Format__c, Domain__c, Options_JSON__c, Correct_JSON__c, Feedback_MD__c FROM Question__c];
        Assert.areEqual('Ready', q.Status__c);
        Assert.areEqual('single3', q.Format__c, 'first slot in the mix is a 3-option question');
        Assert.areEqual('Agents', q.Domain__c);
        Assert.areEqual(3, ((List<Object>) JSON.deserializeUntyped(q.Options_JSON__c)).size());
        Assert.isTrue(q.Feedback_MD__c.contains('-- Correct:'));
        Cert__c c = cert('AI-201');
        Assert.isNull(c.Last_Generation_Error__c);
        Assert.isNotNull(c.Top_Up_Started_At__c, 'pool not full yet, so chain continues');
    }

    @IsTest
    static void poolJobSchedulesRestartAtChainDepthLimit() {
        CertStudyLlm.instance = new FakeLlm();
        markOverviewDone('AI-201');
        activeSession('AI-201');
        CertStudyPoolJob.forceAtMaxDepth = true;
        Test.startTest();
        System.enqueueJob(new CertStudyPoolJob(certId('AI-201')));
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM Question__c], 'work done before stopping is kept');
        // Either the one-off restart is still pending, or it already ran inside
        // Test.stopTest() and re-armed the pool (lock taken by a fresh chain).
        String pattern = CertStudyPoolJob.RESTART_JOB_PREFIX + '%';
        Integer pendingRestarts = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :pattern];
        Boolean reArmed = cert('AI-201').Top_Up_Started_At__c != null;
        Assert.isTrue(pendingRestarts == 1 || reArmed, 'chain restart was scheduled or already ran');
    }

    @IsTest
    static void poolJobIdlesWithoutActiveSession() {
        FakeLlm fake = new FakeLlm();
        CertStudyLlm.instance = fake;
        markOverviewDone('AI-201');
        Test.startTest();
        System.enqueueJob(new CertStudyPoolJob(certId('AI-201')));
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM Question__c]);
        Assert.areEqual(0, fake.calls, 'no model calls when nobody needs the cert');
        Assert.isNull(cert('AI-201').Top_Up_Started_At__c);
    }

    @IsTest
    static void poolJobRecordsModelFailure() {
        FakeLlm fake = new FakeLlm();
        fake.fail = true;
        CertStudyLlm.instance = fake;
        markOverviewDone('AI-201');
        activeSession('AI-201');
        Test.startTest();
        System.enqueueJob(new CertStudyPoolJob(certId('AI-201')));
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM Question__c]);
        Assert.isTrue(cert('AI-201').Last_Generation_Error__c.contains('model call failed'));
    }

    @IsTest
    static void poolJobReportsMissingContent() {
        CertStudyLlm.instance = new FakeLlm();
        activeSession('EMPTY-1');
        Test.startTest();
        System.enqueueJob(new CertStudyPoolJob(certId('EMPTY-1')));
        Test.stopTest();
        Assert.isTrue(cert('EMPTY-1').Last_Generation_Error__c.contains('No resource content'));
    }

    @IsTest
    static void topUpEventStartsGenerationViaTrigger() {
        CertStudyLlm.instance = new FakeLlm();
        markOverviewDone('AI-201');
        activeSession('AI-201');
        CertStudyPoolJob.useEventInTest = true;
        Test.startTest();
        CertStudyPoolJob.requestTopUpAsync(new Set<String>{ 'AI-201' });
        Test.getEventBus().deliver();
        Test.stopTest();
        Assert.isTrue([SELECT COUNT() FROM Question__c WHERE Cert__c = :certId('AI-201')] >= 1, 'trigger started the pool job');
    }

    @IsTest
    static void lengthBiasedCandidatesFallBackAfterMaxAttempts() {
        FakeLlm fake = new FakeLlm();
        fake.biased = true;
        CertStudyLlm.instance = fake;
        markOverviewDone('AI-201');
        activeSession('AI-201');
        CertStudyPoolJob job = new CertStudyPoolJob(certId('AI-201'));
        Cert__c c = cert('AI-201');
        for (Integer i = 0; i < CertStudyPoolJob.MAX_ATTEMPTS; i++) {
            job.runOnce(c);
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Question__c], 'least-biased fallback inserted');
        Assert.areEqual(CertStudyPoolJob.MAX_ATTEMPTS, fake.calls);
    }

    @IsTest
    static void validationAndParsing() {
        CertStudyGenerator.GeneratedQuestion wrongCount = CertStudyGenerator.parseQuestion(
            questionJson(5, false), 'single', 1, null, 'terminology'
        );
        Assert.isTrue(CertStudyGenerator.validityReason(wrongCount).contains('expected 4 options'));
        CertStudyGenerator.GeneratedQuestion three = CertStudyGenerator.parseQuestion(
            questionJson(3, false), 'single3', 1, null, 'terminology'
        );
        Assert.isNull(CertStudyGenerator.validityReason(three));
        Assert.areEqual(3, three.optionKeys.size());

        CertStudyGenerator.GeneratedQuestion garbage = CertStudyGenerator.parseQuestion('not json', 'single', 1, null, 'terminology');
        Assert.isNotNull(CertStudyGenerator.validityReason(garbage));

        CertStudyGenerator.GeneratedQuestion multi = CertStudyGenerator.parseQuestion(
            questionJson(5, false), 'multi', 3, 'Agents', 'scenario-general'
        );
        Assert.isNull(CertStudyGenerator.validityReason(multi));
        Assert.areEqual(2, multi.correct.size());

        CertStudyGenerator.GeneratedQuestion biased = CertStudyGenerator.parseQuestion(
            questionJson(4, true), 'single', 1, null, 'terminology'
        );
        Assert.isTrue(CertStudyGenerator.validityReason(biased).contains('length bias'));

        Assert.isTrue(CertStudyGenerator.hasDuplicateSentence('This sentence is repeated here. This sentence is repeated here.'));
        Assert.areEqual('Good text', CertStudyGenerator.stripArtifacts('Good text</invoke> junk'));
        Assert.areEqual('This reverses it.', CertStudyGenerator.stripVerdict('Incorrect. This reverses it.'));
        Assert.areEqual('Maps the objective.', CertStudyGenerator.stripVerdict('Correct: Maps the objective.'));
        Assert.areEqual('Correctly scoped option.', CertStudyGenerator.stripVerdict('Correctly scoped option.'));
        Assert.isTrue(CertStudyGenerator.buildQuestionPrompt('X', null, 1, 'single', 'terminology', 'g', null).contains('mirror-image'));

        Assert.areEqual(new List<String>{ 'B', 'D' }, CertStudyService.parseLetters('B and D'));
        Assert.areEqual(new List<String>{ 'B', 'D' }, CertStudyService.parseLetters('bd'));
        Assert.areEqual(new List<String>{ 'A' }, CertStudyService.parseLetters('I pick A'));

        Assert.areEqual('single3', CertStudyGenerator.nextFormat(0));
        Assert.areEqual('single', CertStudyGenerator.nextFormat(1));
        Assert.areEqual('multi', CertStudyGenerator.nextFormat(9));
        Assert.isTrue(CertStudyGenerator.buildQuestionPrompt('X', null, 1, 'single3', 'terminology', 'g', null).contains('EXACTLY 3 options'));
        Assert.areEqual('scenario-first-action', CertStudyGenerator.nextStyle(6));
        Assert.areEqual('scenario-root-cause', CertStudyGenerator.nextStyle(7));
        Assert.areEqual(5, CertStudyGenerator.nextDifficulty(4));
        List<String> seq = CertStudyGenerator.weightedDomainSequence(
            toMaps('[{"name":"Big","weight_pct":75},{"name":"Small","weight_pct":25}]'), 20
        );
        Integer big = 0;
        for (String d : seq) if (d == 'Big') big++;
        Assert.areEqual(15, big, 'weights are honoured: 75% of 20');

        String prompt = CertStudyGenerator.buildQuestionPrompt('X', null, 2, 'multi', 'scenario-root-cause', 'g', new List<String>{ 'old stem' });
        Assert.isTrue(prompt.contains('MULTI-select') && prompt.contains('old stem'));
    }

    @IsTest
    static void schedulerEndsIdleSessions() {
        CertStudyLlm.instance = new FakeLlm();
        insert new Study_Session__c(
            User_Key__c = 'idle@example.com', Cert_Codes__c = ids(new List<String>{ 'AI-201' }), Status__c = 'Active',
            Started_At__c = DateTime.now().addHours(-30), Last_Activity__c = DateTime.now().addHours(-30)
        );
        Test.startTest();
        CertStudyScheduler.run();
        String jobId = CertStudyScheduler.scheduleHourly();
        Test.stopTest();
        Assert.isNotNull(jobId);
        Assert.areEqual('Ended', [SELECT Status__c FROM Study_Session__c WHERE User_Key__c = 'idle@example.com'].Status__c);
    }
}
