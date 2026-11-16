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
        addReady(code, n, format, 1);
    }

    private static void addReady(String code, Integer n, String format, Integer difficulty) {
        Id cid = certId(code);
        List<Question__c> qs = new List<Question__c>();
        for (Integer i = 0; i < n; i++) {
            qs.add(new Question__c(
                Cert__c = cid,
                Stem__c = 'Stem ' + i,
                Format__c = format,
                Difficulty__c = difficulty,
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
    static void topUpWaitsWhenConcurrencyCapReached() {
        markOverviewDone('AI-201');
        activeSession('AI-201');
        CertStudyPoolJob.maxConcurrent = 1;
        update new Cert__c(Id = certId('FOUND-101'), Top_Up_Started_At__c = DateTime.now());
        CertStudyPoolJob.requestTopUp(new Set<String>{ 'AI-201' });
        Assert.isNull(cert('AI-201').Top_Up_Started_At__c, 'cap reached, so this cert waits for a free slot');
    }

    @IsTest
    static void topUpStartsWhenBelowConcurrencyCap() {
        markOverviewDone('AI-201');
        activeSession('AI-201');
        CertStudyPoolJob.maxConcurrent = 1;
        CertStudyPoolJob.requestTopUp(new Set<String>{ 'AI-201' });
        Assert.isNotNull(cert('AI-201').Top_Up_Started_At__c, 'a slot was free');
    }

    @IsTest
    static void topUpSkipsCertInFailureCooldown() {
        markOverviewDone('AI-201');
        activeSession('AI-201');
        update new Cert__c(Id = certId('AI-201'), Last_Failure_At__c = DateTime.now());
        CertStudyPoolJob.requestTopUp(new Set<String>{ 'AI-201' });
        Assert.isNull(cert('AI-201').Top_Up_Started_At__c, 'recently gave up, so no immediate retry');
    }

    @IsTest
    static void repeatedModelFailuresStartCooldown() {
        FakeLlm fake = new FakeLlm();
        fake.fail = true;
        CertStudyLlm.instance = fake;
        markOverviewDone('AI-201');
        activeSession('AI-201');
        CertStudyPoolJob job = new CertStudyPoolJob(certId('AI-201'));
        Cert__c c = cert('AI-201');
        for (Integer i = 0; i < CertStudyPoolJob.MAX_ATTEMPTS; i++) {
            job.runOnce(c);
        }
        Assert.isNotNull(c.Last_Failure_At__c, 'giving up records the failure time');
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

    // ------------------------------------------------- upcoming exams (study goals)

    @IsTest
    static void goalsAddUpdateAndRejectBadCerts() {
        Id uid = UserInfo.getUserId();
        List<CertStudyService.GoalRow> rows = CertStudyService.saveGoal(uid, 'AI-201', Date.today().addDays(10));
        Assert.areEqual(1, rows.size());
        Assert.areEqual('AI-201', rows[0].certCode);
        Assert.areEqual(Date.today().addDays(10), rows[0].examDate);
        Assert.isFalse(rows[0].overdue);

        rows = CertStudyService.saveGoal(uid, 'AI-201', null);
        Assert.areEqual(1, rows.size(), 'the same cert updates its open goal instead of adding another');
        Assert.isNull(rows[0].examDate, 'a blank date clears it');

        for (String bad : new List<String>{ 'AGG-1', 'NOPE-9', '' }) {
            try {
                CertStudyService.saveGoal(uid, bad, null);
                Assert.fail('expected an error for ' + bad);
            } catch (CertStudyService.ServiceException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        Assert.areEqual(1, CertStudyService.openGoals(uid).size());
    }

    @IsTest
    static void goalsGoOverdueThenRecordOutcome() {
        Id uid = UserInfo.getUserId();
        List<CertStudyService.GoalRow> rows = CertStudyService.saveGoal(uid, 'AI-201', Date.today().addDays(-2));
        Assert.isTrue(rows[0].overdue, 'the exam date has passed');

        rows = CertStudyService.recordOutcome(uid, String.valueOf(rows[0].id), false);
        Assert.isTrue(rows.isEmpty(), 'a recorded goal is no longer open');
        Study_Goal__c g = [SELECT Status__c, Outcome_Recorded_On__c FROM Study_Goal__c];
        Assert.areEqual('Not passed', g.Status__c);
        Assert.areEqual(Date.today(), g.Outcome_Recorded_On__c);
        Assert.isTrue(CertStudyService.earnedCertCodes(uid).isEmpty(), 'not passing earns nothing');

        // A retake is a new goal; passing marks the cert earned.
        rows = CertStudyService.saveGoal(uid, 'AI-201', Date.today().addDays(-1));
        CertStudyService.recordOutcome(uid, String.valueOf(rows[0].id), true);
        Assert.isTrue(CertStudyService.earnedCertCodes(uid).contains('AI-201'));
        Assert.areEqual(1, [SELECT COUNT() FROM Study_Goal__c WHERE Status__c = 'Passed']);
        Assert.areEqual(1, [SELECT COUNT() FROM Study_Goal__c WHERE Status__c = 'Not passed'], 'history is kept');
    }

    @IsTest
    static void goalsAreRemovedSoftlyAndSettledByEarning() {
        Id uid = UserInfo.getUserId();
        List<CertStudyService.GoalRow> rows = CertStudyService.saveGoal(uid, 'AI-201', null);
        rows = CertStudyService.removeGoal(uid, String.valueOf(rows[0].id));
        Assert.isTrue(rows.isEmpty());
        Assert.areEqual('Dropped', [SELECT Status__c FROM Study_Goal__c].Status__c, 'kept, not deleted');

        CertStudyService.saveGoal(uid, 'AI-201', null);
        CertStudyService.setEarned(uid, 'AI-201', true);
        Assert.isTrue(CertStudyService.openGoals(uid).isEmpty(), 'marking a cert earned settles its open goal');
        Assert.areEqual(1, [SELECT COUNT() FROM Study_Goal__c WHERE Status__c = 'Passed']);
    }

    @IsTest
    static void goalsBelongToTheirOwner() {
        Id uid = UserInfo.getUserId();
        List<CertStudyService.GoalRow> rows = CertStudyService.saveGoal(uid, 'AI-201', null);
        Id other = '005000000000001'; // some other user's Id (this goal is not theirs)
        try {
            CertStudyService.removeGoal(other, String.valueOf(rows[0].id));
            Assert.fail('another learner must not be able to change this goal');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
        Assert.isTrue(CertStudyService.openGoals(other).isEmpty());
        Assert.areEqual(1, CertStudyService.openGoals(uid).size());
    }

    // ------------------------------------------------- exam section scores

    private static final String EXAM_REPORT =
        'Section Name: Section Score\n'
        + 'Prompt Engineering: 83%\n'
        + 'Data 360 Fundamentals: 58%\n'
        + 'AI Agents: 67%\n'
        + 'Testing, Deployment and Maintenance: 67%\n'
        + 'Governance and Observability: 67%\n'
        + 'Multi-Agent Orchestration 100%\n'
        + 'Overall: 120%\n';

    private static void examDomains() {
        Cert__c c = cert('AI-201');
        c.Passing_Score__c = 73;
        c.Domains_JSON__c = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'name' => 'Prompt Engineering', 'weight' => 20 },
            new Map<String, Object>{ 'name' => 'Data 360 Fundamentals', 'weight' => 20 },
            new Map<String, Object>{ 'name' => 'Agents', 'weight' => 20 },
            new Map<String, Object>{ 'name' => 'Testing and Deployment', 'weight' => 20 },
            new Map<String, Object>{ 'name' => 'Governance and Observability', 'weight' => 20 }
        });
        update c;
    }

    private static Id failedGoal() {
        Id uid = UserInfo.getUserId();
        List<CertStudyService.GoalRow> rows = CertStudyService.saveGoal(uid, 'AI-201', Date.today().addDays(-1));
        Id gid = rows[0].id;
        CertStudyService.recordOutcome(uid, String.valueOf(gid), false);
        return gid;
    }

    @IsTest
    static void parsesPastedExamReport() {
        List<CertStudyService.ScoreRow> rows = CertStudyService.parseSectionScores(EXAM_REPORT);
        Assert.areEqual(6, rows.size(), 'header, no-percent and over-100 lines are ignored');
        Assert.areEqual('Prompt Engineering', rows[0].name);
        Assert.areEqual(83, rows[0].pct);
        Assert.areEqual('Testing, Deployment and Maintenance', rows[3].name);
        Assert.areEqual('Multi-Agent Orchestration', rows[5].name);
        Assert.areEqual(100, rows[5].pct);
        Assert.isTrue(CertStudyService.parseSectionScores(null).isEmpty());
        Assert.isTrue(CertStudyService.parseSectionScores('nothing useful here').isEmpty());
    }

    @IsTest
    static void matchesExamSectionNamesToAppSections() {
        List<String> d = new List<String>{ 'Prompt Engineering', 'Agents', 'Testing and Deployment', 'Data Cloud' };
        Assert.areEqual('Prompt Engineering', CertStudyService.matchDomain('prompt engineering', d), 'exact, any case');
        Assert.areEqual('Agents', CertStudyService.matchDomain('AI Agents', d), 'one section name inside the other');
        Assert.areEqual('Testing and Deployment', CertStudyService.matchDomain('Testing, Deployment and Maintenance', d));
        Assert.isNull(CertStudyService.matchDomain('Multi-Agent Orchestration', d), 'no clear match stays blank');
        Assert.isNull(CertStudyService.matchDomain('', d));
    }

    @IsTest
    static void examWeightsScaleWithTheGapToThePassMark() {
        String json = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'name' => 'a', 'pct' => 58, 'domain' => 'Data' },
            new Map<String, Object>{ 'name' => 'b', 'pct' => 67, 'domain' => 'Agents' },
            new Map<String, Object>{ 'name' => 'c', 'pct' => 100, 'domain' => 'Orch' },
            new Map<String, Object>{ 'name' => 'd', 'pct' => 20, 'domain' => 'Deep' },
            new Map<String, Object>{ 'name' => 'e', 'pct' => 10, 'domain' => null }
        });
        Map<String, Decimal> w = CertStudyService.weightsFromScores(json, 73);
        Assert.areEqual(2.4, w.get('Data'));
        Assert.areEqual(1.86, w.get('Agents'));
        Assert.areEqual(0.5, w.get('Orch'), 'passed sections come up about half as often');
        Assert.areEqual(3.0, w.get('Deep'), 'capped at 25 points under');
        Assert.areEqual(4, w.size(), 'unmatched lines do not affect weighting');
        Assert.areEqual(1.5, CertStudyService.weightsFromScores(
            '[{"name":"x","pct":69.99,"domain":"D"}]', null).get('D'), 'default pass mark is 70');
        Assert.areEqual(0.5, CertStudyService.weightsFromScores(
            '[{"name":"x","pct":70,"domain":"D"}]', null).get('D'));
        Assert.isTrue(CertStudyService.weightsFromScores('not json', 73).isEmpty());
    }

    @IsTest
    static void previewAndSaveExamResults() {
        examDomains();
        Id uid = UserInfo.getUserId();
        Id gid = failedGoal();

        CertStudyService.ScorePreview p = CertStudyService.previewScores(uid, String.valueOf(gid), EXAM_REPORT);
        Assert.areEqual(73, p.passingScore);
        Assert.isFalse(p.passingEstimated);
        Assert.areEqual(5, p.domains.size());
        Assert.areEqual(6, p.rows.size());
        Assert.areEqual('Prompt Engineering', p.rows[0].domain);
        Assert.areEqual('Testing and Deployment', p.rows[3].domain);
        Assert.isNull(p.rows[5].domain, 'Multi-Agent Orchestration has no section here');
        Assert.isNull([SELECT Section_Scores_JSON__c FROM Study_Goal__c WHERE Id = :gid].Section_Scores_JSON__c, 'preview saves nothing');

        String msg = CertStudyService.saveScores(uid, String.valueOf(gid), p.rows);
        Assert.isTrue(msg.contains('Data 360 Fundamentals'), msg);
        Assert.isNotNull([SELECT Section_Scores_JSON__c FROM Study_Goal__c WHERE Id = :gid].Section_Scores_JSON__c);

        // Scores can be entered only for a recorded "Not passed" exam, by its owner, with valid values.
        try {
            CertStudyService.saveScores(uid, String.valueOf(gid), new List<CertStudyService.ScoreRow>());
            Assert.fail('rows are required');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('at least one'));
        }
        CertStudyService.ScoreRow bad = new CertStudyService.ScoreRow();
        bad.name = 'x';
        bad.pct = 50;
        bad.domain = 'Not A Section';
        try {
            CertStudyService.saveScores(uid, String.valueOf(gid), new List<CertStudyService.ScoreRow>{ bad });
            Assert.fail('unknown section');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('not a section'));
        }
        bad.domain = null;
        bad.pct = 101;
        try {
            CertStudyService.saveScores(uid, String.valueOf(gid), new List<CertStudyService.ScoreRow>{ bad });
            Assert.fail('bad score');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('between 0 and 100'));
        }
        try {
            CertStudyService.previewScores('005000000000001', String.valueOf(gid), EXAM_REPORT);
            Assert.fail('not their exam');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
    }

    @IsTest
    static void completedExamsStayReachableAndScoresCanBeEditedLater() {
        examDomains();
        Id uid = UserInfo.getUserId();
        Id gid = failedGoal();
        Assert.isTrue(CertStudyService.openGoals(uid).isEmpty(), 'a completed exam leaves the open list');

        List<CertStudyService.ExamRow> hist = CertStudyService.examHistory(uid);
        Assert.areEqual(1, hist.size());
        Assert.areEqual('Not passed', hist[0].status);
        Assert.isFalse(hist[0].hasScores);
        Assert.isTrue(CertStudyService.savedScores(uid, String.valueOf(gid)).rows.isEmpty(), 'nothing saved yet');

        CertStudyService.ScorePreview p = CertStudyService.previewScores(uid, String.valueOf(gid), EXAM_REPORT);
        CertStudyService.saveScores(uid, String.valueOf(gid), p.rows);
        Assert.isTrue(CertStudyService.examHistory(uid)[0].hasScores);

        // Reopen, change one score, save again: the newest scores replace the old ones.
        CertStudyService.ScorePreview saved = CertStudyService.savedScores(uid, String.valueOf(gid));
        Assert.areEqual(6, saved.rows.size());
        Assert.areEqual('Prompt Engineering', saved.rows[0].domain);
        saved.rows[0].pct = 40;
        CertStudyService.saveScores(uid, String.valueOf(gid), saved.rows);
        Assert.areEqual(40, CertStudyService.savedScores(uid, String.valueOf(gid)).rows[0].pct);

        // Deleting a completed record removes it for good; open exams and other learners' records are untouched.
        try {
            CertStudyService.deleteCompletedExam('005000000000001', String.valueOf(gid));
            Assert.fail('not their exam');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
        Assert.isTrue(CertStudyService.deleteCompletedExam(uid, String.valueOf(gid)).isEmpty());
        Assert.areEqual(0, [SELECT COUNT() FROM Study_Goal__c WHERE Id = :gid]);
        failedGoal(); // a retake, so the rest of this test still has a not-passed record

        // A passed exam shows in history but cannot carry scores.
        CertStudyService.saveGoal(uid, 'AI-201', Date.today().addDays(-1));
        Id passedId = CertStudyService.openGoals(uid)[0].id;
        CertStudyService.recordOutcome(uid, String.valueOf(passedId), true);
        Assert.areEqual(2, CertStudyService.examHistory(uid).size());
        try {
            CertStudyService.savedScores(uid, String.valueOf(passedId));
            Assert.fail('only a not-passed exam has scores');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
    }

    @IsTest
    static void pastAttemptsCanBeAddedDirectly() {
        examDomains();
        Id uid = UserInfo.getUserId();
        Id gid = CertStudyService.addPastExam(uid, 'AI-201', Date.today().addDays(-30), false);
        Study_Goal__c g = [SELECT Status__c, Exam_Date__c, Outcome_Recorded_On__c FROM Study_Goal__c WHERE Id = :gid];
        Assert.areEqual('Not passed', g.Status__c);
        Assert.areEqual(Date.today().addDays(-30), g.Outcome_Recorded_On__c, 'attempts sort by when they happened');
        Assert.isTrue(CertStudyService.openGoals(uid).isEmpty(), 'it is history, not an upcoming exam');
        CertStudyService.ScorePreview p = CertStudyService.previewScores(uid, String.valueOf(gid), EXAM_REPORT);
        CertStudyService.saveScores(uid, String.valueOf(gid), p.rows);
        Assert.areEqual(1, CertStudyService.examFocusRows(uid).size(), 'its scores drive focus');

        // A booked retake can sit in the upcoming list at the same time.
        CertStudyService.saveGoal(uid, 'AI-201', Date.today().addDays(20));
        Assert.areEqual(1, CertStudyService.openGoals(uid).size());
        Assert.areEqual(1, CertStudyService.examFocusRows(uid).size());

        try {
            CertStudyService.addPastExam(uid, 'AI-201', Date.today().addDays(3), false);
            Assert.fail('future date');
        } catch (CertStudyService.ServiceException e) {
            Assert.isTrue(e.getMessage().contains('future'));
        }
        try {
            CertStudyService.addPastExam(uid, 'AGG-1', null, false);
            Assert.fail('aggregate');
        } catch (CertStudyService.ServiceException e) {
            Assert.isNotNull(e.getMessage());
        }
        CertStudyService.addPastExam(uid, 'AI-201', null, true);
        Assert.isTrue(CertStudyService.earnedCertCodes(uid).contains('AI-201'), 'a past pass marks the cert earned');
    }

    @IsTest
    static void examResultsReplaceHistoryWeightsUntilPassed() {
        examDomains();
        Id uid = UserInfo.getUserId();
        // History says Agents is the weak spot; the exam says Data 360 Fundamentals is.
        answerHistory(String.valueOf(uid), 'AI-201', 'Agents', 1, 9);
        answerHistory(String.valueOf(uid), 'AI-201', 'Prompt Engineering', 9, 1);
        Set<String> codes = new Set<String>{ 'AI-201' };
        Map<String, Decimal> before = CertStudyService.focusWeights(String.valueOf(uid), codes).get('AI-201');
        Assert.isTrue(before.get('Agents') >= CertStudyService.FOCUS_WEAK_WEIGHT);

        Id gid = failedGoal();
        CertStudyService.ScorePreview p = CertStudyService.previewScores(uid, String.valueOf(gid), EXAM_REPORT);
        CertStudyService.saveScores(uid, String.valueOf(gid), p.rows);

        Map<String, Decimal> after = CertStudyService.focusWeights(String.valueOf(uid), codes).get('AI-201');
        Assert.areEqual(2.4, after.get('Data 360 Fundamentals'));
        Assert.areEqual(0.5, after.get('Prompt Engineering'));
        Assert.isFalse(after.containsKey('Agents') && after.get('Agents') >= 2.9, 'history weights are replaced');
        Assert.areEqual(1, CertStudyService.examFocusRows(uid).size());
        Assert.areEqual('AI-201', CertStudyService.examFocusRows(uid)[0].certCode);

        CertStudyService.setEarned(uid, 'AI-201', true);
        Assert.isTrue(CertStudyService.examFocusRows(uid).isEmpty(), 'passing ends the override');
        Map<String, Decimal> restored = CertStudyService.focusWeights(String.valueOf(uid), codes).get('AI-201');
        Assert.areEqual(before.get('Agents'), restored.get('Agents'), 'history weights are back');
    }

    // ------------------------------------------------- per-cert formats and unscored test questions

    @IsTest
    static void formatMixFollowsTheCert() {
        Cert__c classic = new Cert__c(Format_Mix__c = '1of4|2of4|2of5');
        Map<String, Integer> counts = new Map<String, Integer>();
        for (Integer i = 0; i < 10; i++) {
            String f = CertStudyGenerator.nextFormat(classic, i);
            counts.put(f, (counts.containsKey(f) ? counts.get(f) : 0) + 1);
        }
        Assert.areEqual(6, counts.get('single'));
        Assert.areEqual(2, counts.get('2of4'));
        Assert.areEqual(2, counts.get('2of5'));

        for (Integer i = 0; i < 10; i++) {
            Assert.areEqual('single3', CertStudyGenerator.nextFormat(new Cert__c(Format_Mix__c = '1of3'), i));
        }
        for (String generic : new List<String>{ null, '', 'NONE', 'bogus' }) {
            Assert.areEqual(CertStudyGenerator.nextFormat(9), CertStudyGenerator.nextFormat(new Cert__c(Format_Mix__c = generic), 9),
                'blank, NONE and unknown mixes use the generic rotation');
        }
        Assert.areEqual(3, CertStudyGenerator.optionCount('single3'));
        Assert.areEqual(4, CertStudyGenerator.optionCount('2of4'));
        Assert.areEqual(5, CertStudyGenerator.optionCount('3of5'));
        Assert.areEqual(3, CertStudyGenerator.minCorrect('3of5'));
        Assert.areEqual(2, CertStudyGenerator.maxCorrect('2of5'));
        Assert.areEqual(3, CertStudyGenerator.maxCorrect('multi'));
    }

    @IsTest
    static void newFormatsGetExactPromptsAndValidation() {
        String prompt = CertStudyGenerator.buildQuestionPrompt('Cert', 'Agents', 2, '2of5', 'terminology', 'grounding', new List<String>());
        Assert.isTrue(prompt.contains('EXACTLY 5 options, EXACTLY 2 correct'), prompt);
        prompt = CertStudyGenerator.buildQuestionPrompt('Cert', 'Agents', 2, '2of4', 'terminology', 'grounding', new List<String>());
        Assert.isTrue(prompt.contains('EXACTLY 4 options, EXACTLY 2 correct'));

        CertStudyGenerator.GeneratedQuestion q = new CertStudyGenerator.GeneratedQuestion();
        q.format = '2of5';
        q.stem = 'Which two features ground agent responses in trusted data?';
        q.feedbackMd = 'Explanation. '.repeat(40);
        q.rawOptionCount = 5;
        q.optionKeys = new List<String>{ 'A', 'B', 'C', 'D', 'E' };
        q.correct = new List<String>{ 'A', 'B' };
        Assert.isNull(CertStudyGenerator.structuralReason(q));
        q.correct = new List<String>{ 'A', 'B', 'C' };
        Assert.isNotNull(CertStudyGenerator.structuralReason(q), 'a pick-two question must have exactly two correct answers');
        q.format = '3of5';
        Assert.isNull(CertStudyGenerator.structuralReason(q));
    }

    @IsTest
    static void testsDeliverExtraQuestionsAndLeaveFiveUnscored() {
        Cert__c scoredOnly = new Cert__c(Num_Questions__c = 60);
        Assert.areEqual(65, CertStudyService.deliveredQuestions(scoredOnly), 'scored count plus 5');
        Assert.areEqual(65, CertStudyService.deliveredQuestions(new Cert__c(Num_Questions__c = 60, Delivered_Questions__c = 65)));
        Assert.areEqual(65, CertStudyService.deliveredQuestions(new Cert__c(Delivered_Questions__c = 65)));
        String picked = CertStudyService.pickUnscored(65);
        Set<String> parts = new Set<String>(picked.split(';'));
        parts.remove('');
        Assert.areEqual(5, parts.size(), 'five distinct positions: ' + picked);
        for (String p : parts) Assert.isTrue(Integer.valueOf(p) >= 1 && Integer.valueOf(p) <= 65);
    }

    @IsTest
    static void unscoredQuestionsAreReviewedButNotScored() {
        CertStudyLlm.instance = new FakeLlm();
        CertStudyService.unscoredExtra = 2; // a small exam keeps this test inside the query limits
        update new Cert__c(Id = certId('AI-201'), Num_Questions__c = 3, Duration_Min__c = 30, Passing_Score__c = 70);
        addReady('AI-201', 8, 'single');
        CertStudyService.StartOutcome o = CertStudyService.startTestCore('unscored@example.com', 'AI-201', false);
        Assert.isNull(o.error);
        Study_Session__c s = CertStudyService.activeSession('unscored@example.com');
        Assert.areEqual(5, s.Question_Target__c.intValue(), '3 scored + 2 unscored');
        Assert.areEqual(2, CertStudyService.unscoredCount(s));

        Set<Integer> unscored = new Set<Integer>();
        for (String p : s.Unscored_Positions__c.split(';')) if (String.isNotBlank(p)) unscored.add(Integer.valueOf(p));
        Test.startTest();
        for (Integer position = 1; position <= 5; position++) {
            Assert.isNotNull(CertStudyService.nextQuestionRecord(s));
            // right on every scored question, wrong on every unscored one
            CertStudyService.gradeCore(s, new List<String>{ unscored.contains(position) ? 'B' : 'A' }, false);
        }
        Assert.areEqual(2, [SELECT COUNT() FROM Answer__c WHERE Study_Session__c = :s.Id AND Is_Unscored__c = true]);

        CertStudyService.TestResult r = CertStudyService.finishTest(s, false);
        Test.stopTest();
        Assert.areEqual(5, r.target);
        Assert.areEqual(3, r.scoredTarget);
        Assert.areEqual(2, r.unscoredCount);
        Assert.areEqual(3, r.correct);
        Assert.areEqual(100, r.officialPct, 'wrong answers on unscored questions do not hurt the score');
        Assert.isTrue(r.passed);
        Assert.areEqual(2, r.missed.size(), 'unscored misses are still reviewed');
        Assert.isFalse(r.incomplete);
    }

    // ------------------------------------------------- reuse of other learners' answered questions

    private static void pauseGeneration() {
        update new Cert__c(Id = certId('AI-201'), Last_Failure_At__c = DateTime.now());
    }

    @IsTest
    static void emptyPoolReusesQuestionsOthersAnsweredOnlyOnce() {
        pauseGeneration();
        answerHistory('someone@example.com', 'AI-201', 'Agents', 2, 0);
        Study_Session__c s = practiceSession(null); // learner min@example.com
        Question__c first = CertStudyService.nextQuestionRecord(s);
        Assert.isNotNull(first, 'a question another learner answered is served when nothing fresh is ready');
        Question__c copy = [SELECT Source_Question__c, Study_Session__c, Status__c FROM Question__c WHERE Id = :first.Id];
        Assert.isNotNull(copy.Source_Question__c);
        Assert.areEqual(s.Id, copy.Study_Session__c);
        Assert.areEqual('Served', copy.Status__c);
        Assert.areEqual('Answered', [SELECT Status__c FROM Question__c WHERE Id = :copy.Source_Question__c].Status__c,
            'the original stays with the first learner');

        CertStudyService.gradeCore(s, new List<String>{ 'A' }, false);
        Question__c second = CertStudyService.nextQuestionRecord(s);
        Assert.isNotNull(second);
        Assert.areNotEqual(copy.Source_Question__c,
            [SELECT Source_Question__c FROM Question__c WHERE Id = :second.Id].Source_Question__c, 'a different original');
        CertStudyService.gradeCore(s, new List<String>{ 'A' }, false);
        Assert.isNull(CertStudyService.nextQuestionRecord(s), 'both originals have now been seen');
    }

    @IsTest
    static void reuseSkipsOwnReportedAndTooEasyQuestions() {
        pauseGeneration();
        answerHistory('min@example.com', 'AI-201', 'Agents', 2, 0); // this learner's own answers
        Study_Session__c s = practiceSession(null);
        Assert.isNull(CertStudyService.nextQuestionRecord(s), 'own questions are never reused');

        answerHistory('someone@example.com', 'AI-201', 'Agents', 1, 0);
        Question__c theirs = [
            SELECT Id FROM Question__c WHERE Study_Session__r.User_Key__c = 'someone@example.com'
        ];
        insert new Question_Report__c(
            Question__c = theirs.Id, Cert__c = certId('AI-201'), Reporter__c = UserInfo.getUserId(), Issue_Type__c = 'Inaccurate'
        );
        Assert.isNull(CertStudyService.nextQuestionRecord(s), 'a reported question is not recirculated');
        delete [SELECT Id FROM Question_Report__c];

        Study_Session__c hard = practiceSession(4);
        Assert.isNull(CertStudyService.nextQuestionRecord(hard), 'minimum difficulty still applies (these are level 1)');
    }

    // ------------------------------------------------- weak-area focus

    /** An ended Practice session with right + wrong answered questions in one domain. */
    private static void answerHistory(String key, String code, String domain, Integer right, Integer wrong) {
        Id cid = certId(code);
        Study_Session__c s = new Study_Session__c(
            User_Key__c = key, Cert_Codes__c = ids(new List<String>{ code }), Mode__c = 'Practice',
            Status__c = 'Ended', Started_At__c = DateTime.now().addDays(-1), Last_Activity__c = DateTime.now().addDays(-1)
        );
        insert s;
        List<Question__c> qs = new List<Question__c>();
        for (Integer i = 0; i < right + wrong; i++) {
            qs.add(new Question__c(
                Cert__c = cid, Stem__c = 'History ' + domain + ' ' + i, Format__c = 'single', Difficulty__c = 1,
                Domain__c = domain,
                Options_JSON__c = '[{"key":"A","text":"Alpha"},{"key":"B","text":"Bravo"}]',
                Correct_JSON__c = '["A"]', Feedback_MD__c = 'f', Status__c = 'Answered', Study_Session__c = s.Id
            ));
        }
        insert qs;
        List<Answer__c> answers = new List<Answer__c>();
        for (Integer i = 0; i < qs.size(); i++) {
            answers.add(new Answer__c(
                Study_Session__c = s.Id, Question__c = qs[i].Id, User_Answer__c = 'A',
                Is_Correct__c = i < right, Answered_At__c = DateTime.now()
            ));
        }
        insert answers;
    }

    private static Map<String, Boolean> noPrereqs() {
        return new Map<String, Boolean>{ 'AI-201' => false };
    }

    @IsTest
    static void focusWeightsFavorLowAccuracyDomains() {
        answerHistory('focus@example.com', 'AI-201', 'Agents', 5, 0);
        answerHistory('focus@example.com', 'AI-201', 'Data', 0, 5);
        Map<String, Map<String, Decimal>> w = CertStudyService.focusWeights('focus@example.com', new Set<String>{ 'AI-201' });
        Decimal agents = w.get('AI-201').get('Agents');
        Decimal data = w.get('AI-201').get('Data');
        Assert.isTrue(data > agents, 'the weaker domain gets the higher weight');
        // overall accuracy is 50%: Data (0/5) shrinks to 25% => 2.5, Agents (5/5) to 75% => 1.5
        Assert.isTrue(Math.abs(data - 2.5) < 0.01, String.valueOf(data));
        Assert.isTrue(Math.abs(agents - 1.5) < 0.01, String.valueOf(agents));

        Assert.isTrue(CertStudyService.answeredCertCodes('focus@example.com').contains('AI-201'));
        Assert.isTrue(CertStudyService.answeredCertCodes('someone.else@example.com').isEmpty());
        Assert.isTrue(CertStudyService.focusWeights('nobody@example.com', new Set<String>{ 'AI-201' }).isEmpty());
        Assert.isTrue(CertStudyService.parseFocusWeights('not json').isEmpty(), 'a bad snapshot turns focus off');
    }

    @IsTest
    static void focusOnlyAppliesToCertsWithHistory() {
        CertStudyLlm.instance = new FakeLlm();
        CertStudyService.StartOutcome none = CertStudyService.startSessionCore(
            'f1@example.com', new List<String>{ 'AI-201' }, noPrereqs(), null, true
        );
        Assert.isNull(none.error);
        Study_Session__c s0 = [SELECT Focus_Weak_Areas__c, Domain_Weights_JSON__c FROM Study_Session__c WHERE Id = :none.session.Id];
        Assert.isFalse(s0.Focus_Weak_Areas__c, 'no history, so focus stays off');
        Assert.isNull(s0.Domain_Weights_JSON__c);

        answerHistory('f2@example.com', 'AI-201', 'Agents', 1, 4);
        CertStudyService.StartOutcome o = CertStudyService.startSessionCore(
            'f2@example.com', new List<String>{ 'AI-201' }, noPrereqs(), null, true
        );
        Study_Session__c s = [SELECT Focus_Weak_Areas__c, Domain_Weights_JSON__c FROM Study_Session__c WHERE Id = :o.session.Id];
        Assert.isTrue(s.Focus_Weak_Areas__c);
        Assert.isTrue(s.Domain_Weights_JSON__c.contains('Agents'));
        Assert.isTrue(CertStudyService.focusNote(s).contains('Agents'), CertStudyService.focusNote(s));
        Assert.isNull(CertStudyService.focusNote(s0), 'no note when focus is off');
    }

    @IsTest
    static void focusedPracticePrefersTheWeakDomain() {
        CertStudyLlm.instance = new FakeLlm();
        // Extreme weights make the outcome effectively deterministic.
        addReadyDomain('AI-201', 'Agents', 1);
        addReadyDomain('AI-201', 'Data', 1);
        CertStudyService.StartOutcome o = CertStudyService.startSessionCore(
            'f3@example.com', new List<String>{ 'AI-201' }, noPrereqs(), null, false
        );
        Study_Session__c s = o.session;
        s.Focus_Weak_Areas__c = true;
        s.Domain_Weights_JSON__c = '{"AI-201":{"Data":1000,"Agents":0.001}}';
        update s;
        Question__c first = CertStudyService.nextQuestionRecord(s);
        Assert.areEqual('Data', first.Domain__c, 'the heavily weighted domain is served first');
    }

    @IsTest
    static void testModeIgnoresFocusSettings() {
        CertStudyLlm.instance = new FakeLlm();
        addReadyDomain('AI-201', 'Agents', 2);
        update new Cert__c(Id = certId('AI-201'), Num_Questions__c = 2, Duration_Min__c = 30, Passing_Score__c = 70);
        CertStudyService.StartOutcome o = CertStudyService.startTestCore('t@example.com', 'AI-201', false);
        Assert.isNull(o.error);
        Assert.isFalse([SELECT Focus_Weak_Areas__c FROM Study_Session__c WHERE Id = :o.session.Id].Focus_Weak_Areas__c);
    }

    @IsTest
    static void poolGeneratesForShortWeakDomain() {
        CertStudyLlm.instance = new FakeLlm();
        CertStudyService.StartOutcome o = CertStudyService.startSessionCore(
            'f4@example.com', new List<String>{ 'AI-201' }, noPrereqs(), null, false
        );
        Study_Session__c s = o.session;
        s.Focus_Weak_Areas__c = true;
        s.Domain_Weights_JSON__c = '{"AI-201":{"Data":2.5,"Agents":1.0}}';
        update s;
        Id cid = certId('AI-201');
        Assert.areEqual('Data', CertStudyService.focusDomainNeeded(cid, 'AI-201'), 'weak domain has no ready questions');
        addReadyDomain('AI-201', 'Data', CertStudyService.FOCUS_DOMAIN_READY);
        Assert.isNull(CertStudyService.focusDomainNeeded(cid, 'AI-201'), 'enough ready in the weak domain');
    }

    private static void addReadyDomain(String code, String domain, Integer n) {
        Id cid = certId(code);
        List<Question__c> qs = new List<Question__c>();
        for (Integer i = 0; i < n; i++) {
            qs.add(new Question__c(
                Cert__c = cid, Stem__c = 'Ready ' + domain + ' ' + i, Format__c = 'single', Difficulty__c = 1,
                Domain__c = domain,
                Options_JSON__c = '[{"key":"A","text":"Alpha"},{"key":"B","text":"Bravo"},{"key":"C","text":"Charlie"},{"key":"D","text":"Delta"}]',
                Correct_JSON__c = '["A"]', Feedback_MD__c = '**A. Alpha** -- Correct: because.', Status__c = 'Ready'
            ));
        }
        insert qs;
    }

    // ------------------------------------------------- waiting reason and retry

    @IsTest
    static void waitMessageExplainsCooldownAndKickClearsIt() {
        CertStudyLlm.instance = new FakeLlm();
        Id cid = certId('AI-201');
        update new Cert__c(Id = cid, Last_Failure_At__c = DateTime.now().addMinutes(-3));
        String msg = CertStudyService.waitMessage(new Set<String>{ 'AI-201' });
        Assert.isTrue(msg.contains('paused for about 7 more minutes'), msg);
        Assert.isFalse(msg.contains('Exception'), 'no internal error text is shown to learners');

        CertStudyService.kickGeneration(new Set<String>{ 'AI-201' });
        Assert.isNull(
            [SELECT Last_Failure_At__c FROM Cert__c WHERE Id = :cid].Last_Failure_At__c,
            'retry clears the failure cooldown'
        );
    }

    @IsTest
    static void kickClearsOnlyStalledLocks() {
        CertStudyLlm.instance = new FakeLlm();
        Id cid = certId('AI-201');
        update new Cert__c(Id = cid, Top_Up_Started_At__c = DateTime.now().addMinutes(-5));
        Assert.isTrue(CertStudyService.waitMessage(new Set<String>{ 'AI-201' }).contains('being written'));
        CertStudyService.kickGeneration(new Set<String>{ 'AI-201' });
        // The stalled lock was released (a new chain may have re-taken it, which is a later timestamp).
        DateTime lock = cert('AI-201').Top_Up_Started_At__c;
        Assert.isTrue(lock == null || lock > DateTime.now().addMinutes(-1), 'old lock must not survive a retry');
    }

    @IsTest
    static void waitMessageWithNothingWrongAsksToCheckAgain() {
        update new Cert__c(Id = certId('AI-201'), Top_Up_Started_At__c = null, Last_Failure_At__c = null);
        String msg = CertStudyService.waitMessage(new Set<String>{ 'AI-201' });
        Assert.isTrue(msg.contains('Check again'), msg);
        Assert.isNull(CertStudyService.waitMessage(new Set<String>()));
    }

    // ------------------------------------------------- minimum difficulty

    private static void addReadyAt(String code, Integer n, Integer difficulty) {
        addReady(code, n, 'single', difficulty);
    }

    private static Study_Session__c practiceSession(Integer minDifficulty) {
        CertStudyLlm.instance = new FakeLlm();
        // AI-201 has a prerequisite, so answer the prerequisite prompt up front ("no").
        CertStudyService.StartOutcome res = CertStudyService.startSessionCore(
            'min@example.com', new List<String>{ 'AI-201' }, new Map<String, Boolean>{ 'AI-201' => false }, minDifficulty
        );
        Assert.isNull(res.error);
        Assert.isNull(res.pendingCode);
        return [SELECT Id, Cert_Codes__c, Min_Difficulty__c, Mode__c FROM Study_Session__c WHERE Id = :res.session.Id];
    }

    @IsTest
    static void nextDifficultyRespectsMinimum() {
        Assert.areEqual(1, CertStudyGenerator.nextDifficulty(0, 1));
        Assert.areEqual(5, CertStudyGenerator.nextDifficulty(4, 1));
        for (Integer total = 0; total < 20; total++) {
            Integer d = CertStudyGenerator.nextDifficulty(total, 4);
            Assert.isTrue(d == 4 || d == 5, 'min 4 only yields 4 or 5, got ' + d);
        }
        Assert.areEqual(5, CertStudyGenerator.nextDifficulty(7, 5));
        Assert.areEqual(1, CertStudyGenerator.nextDifficulty(5, 0), 'out-of-range minimum clamps to 1');
    }

    @IsTest
    static void minDifficultyDefaultsToOneAndClamps() {
        Assert.areEqual(1, practiceSession(null).Min_Difficulty__c.intValue(), 'no selection means 1');
        Assert.areEqual(5, practiceSession(9).Min_Difficulty__c.intValue(), 'clamped to 5');
        Assert.areEqual(1, practiceSession(-3).Min_Difficulty__c.intValue(), 'clamped to 1');
        Assert.areEqual(3, practiceSession(3).Min_Difficulty__c.intValue());
    }

    @IsTest
    static void practiceOnlyServesQuestionsAtOrAboveMinimum() {
        addReadyAt('AI-201', 3, 2);
        addReadyAt('AI-201', 1, 4);
        Study_Session__c s = practiceSession(4);
        Question__c first = CertStudyService.nextQuestionRecord(s);
        Assert.isNotNull(first);
        Assert.areEqual(4, first.Difficulty__c.intValue());
        // Answer it so the next call claims a new row; only difficulty 2 rows remain.
        CertStudyService.gradeCore(s, new List<String>{ 'A' });
        Assert.isNull(CertStudyService.nextQuestionRecord(s), 'easier questions are not served at minimum 4');
        Assert.areEqual(3, [SELECT COUNT() FROM Question__c WHERE Status__c = 'Ready'], 'easier questions stay cached');
    }

    @IsTest
    static void defaultMinimumServesAnyDifficulty() {
        addReadyAt('AI-201', 1, 2);
        Study_Session__c s = practiceSession(null);
        Assert.areEqual(2, CertStudyService.nextQuestionRecord(s).Difficulty__c.intValue());
    }

    @IsTest
    static void topUpTargetsHighestUnmetMinimum() {
        practiceSession(4);
        Id cid = certId('AI-201');
        Integer target = CertStudyGenerator.POOL_SIZE;
        // Plenty of easy questions: minimum 1 is covered but minimum 4 is not.
        addReadyAt('AI-201', target, 2);
        Assert.areEqual(4, CertStudyService.unmetMinDifficulty(cid, target));
        // Enough hard questions too: nothing left to generate.
        addReadyAt('AI-201', target, 5);
        Assert.isNull(CertStudyService.unmetMinDifficulty(cid, target));
    }

    @IsTest
    static void poolJobGeneratesAtOrAboveMinimum() {
        markOverviewDone('AI-201');
        practiceSession(4);
        addReadyAt('AI-201', CertStudyGenerator.POOL_SIZE, 1);
        CertStudyPoolJob job = new CertStudyPoolJob(certId('AI-201'));
        job.runOnce(cert('AI-201'));
        // The seeded rows are all difficulty 1, so exactly one new row at 4 or above proves the target.
        Assert.areEqual(
            1, [SELECT COUNT() FROM Question__c WHERE Difficulty__c >= 4],
            'generated for the session minimum despite a full easy pool'
        );
    }
}
