@IsTest
private class CertStudyControllerTest {
    private class NoopLlm implements CertStudyLlm.Client {
        public String generate(String prompt) {
            return '{}';
        }
    }

    @TestSetup
    static void setup() {
        Cert__c ai = new Cert__c(Name = 'Agentforce Specialist', Cert_Code__c = 'AI-201',
            Num_Questions__c = 60, Duration_Min__c = 105, Passing_Score__c = 72,
            Domains_JSON__c = '[{"name":"AI Agents","weight_pct":35},{"name":"Prompting","weight_pct":65}]');
        Cert__c found = new Cert__c(Name = 'Platform Foundations', Cert_Code__c = 'FOUND-101');
        insert new List<Cert__c>{ ai, found };
        insert new Cert_Prerequisite__c(Cert__c = ai.Id, Prereq_Cert__c = found.Id);
        insert new Cert_Resource__c(Cert__c = ai.Id, Role__c = 'Primary', Content__c = 'Guide text.');
        List<Question__c> qs = new List<Question__c>();
        for (Integer i = 0; i < 3; i++) {
            qs.add(new Question__c(
                Cert__c = ai.Id, Stem__c = 'Stem ' + i, Format__c = 'single3', Difficulty__c = 2,
                Domain__c = i == 0 ? 'AI Agents' : 'Prompting',
                Options_JSON__c = '[{"key":"A","text":"Alpha"},{"key":"B","text":"Bravo"},{"key":"C","text":"Charlie"}]',
                Correct_JSON__c = '["B"]',
                Feedback_MD__c = '**A. Alpha** -- Incorrect: Alpha is wrong.\n\n**B. Bravo** -- Correct: Bravo is right.\n\n**C. Charlie** -- Incorrect: Charlie is wrong.',
                Status__c = 'Ready'
            ));
        }
        insert qs;
    }

    @IsTest
    static void listCertsCarriesRetirementStatus() {
        Id certId = [SELECT Id FROM Cert__c WHERE Cert_Code__c = 'AI-201'].Id;
        update new Cert__c(
            Id = certId,
            Exam_Status__c = 'Retiring',
            Retires_On__c = Date.newInstance(2027, 2, 1),
            Path_Forward__c = 'Take the replacement exam.'
        );
        List<CertStudyController.CertOption> certs = CertStudyController.listCerts();
        Assert.areEqual(1, certs.size());
        Assert.areEqual('Retiring', certs[0].status);
        Assert.areEqual('Feb 1, 2027', certs[0].retiresOn);
        Assert.areEqual('Take the replacement exam.', certs[0].pathForward);
        Assert.isFalse(certs[0].prereqs.isEmpty(), 'AI-201 has a prerequisite in the test data');
    }

    @IsTest
    static void earnedCertsAreStoredPerUser() {
        Assert.isTrue(CertStudyController.getEarnedCerts().isEmpty());

        List<String> after = CertStudyController.setCertEarned('AI-201', true);
        Assert.areEqual(new List<String>{ 'AI-201' }, after);
        // Marking it again must not create a duplicate row.
        CertStudyController.setCertEarned('AI-201', true);
        Assert.areEqual(1, [SELECT COUNT() FROM User_Cert__c]);
        Assert.areEqual('Self-reported', [SELECT Source__c FROM User_Cert__c].Source__c);

        // A different user sees none of it.
        User other = new User(
            Alias = 'other', Email = 'other@example.com', Username = 'other.earned@example.com.test',
            LastName = 'Other', ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert other;
        System.runAs(other) {
            Assert.isTrue(CertStudyController.getEarnedCerts().isEmpty());
        }

        Assert.isTrue(CertStudyController.setCertEarned('AI-201', false).isEmpty());
        Assert.areEqual(0, [SELECT COUNT() FROM User_Cert__c]);
    }

    @IsTest
    static void earnedCertRejectsUnknownCert() {
        try {
            CertStudyController.setCertEarned('NOPE-999', true);
            Assert.fail('expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
    }

    @IsTest
    static void questionReportsAreValidatedScopedAndDeduplicated() {
        CertStudyLlm.instance = new NoopLlm();
        CertStudyController.SessionView v = CertStudyController.startPractice(new List<String>{ 'AI-201' }, null);
        v = CertStudyController.startPractice(new List<String>{ 'AI-201' }, '{"AI-201": false}');
        String qid = v.question.id;

        // Validation
        for (List<String> bad : new List<List<String>>{
            new List<String>{ qid, null, 'x' }, new List<String>{ qid, 'Bogus', 'x' }, new List<String>{ qid, 'Other', ' ' }
        }) {
            try {
                CertStudyController.reportQuestion(bad[0], bad[1], bad[2]);
                Assert.fail('expected an error');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        try {
            CertStudyController.reportQuestion('not-an-id', 'Inaccurate', 'x');
            Assert.fail('expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }

        CertStudyController.reportQuestion(qid, 'Inaccurate', 'Option B is wrong');
        Question_Report__c r = [
            SELECT Issue_Type__c, Comment__c, Status__c, Reporter__c, Cert__c, Question__c FROM Question_Report__c
        ];
        Assert.areEqual('Inaccurate', r.Issue_Type__c);
        Assert.areEqual('New', r.Status__c);
        Assert.areEqual(UserInfo.getUserId(), r.Reporter__c);
        Assert.isNotNull(r.Cert__c);

        // A second report on the same question is appended to the open one; nothing is overwritten.
        CertStudyController.reportQuestion(qid, 'Multiple correct answers', 'C is also right');
        Assert.areEqual(1, [SELECT COUNT() FROM Question_Report__c]);
        Question_Report__c again = [SELECT Issue_Type__c, Comment__c FROM Question_Report__c];
        Assert.areEqual('Inaccurate', again.Issue_Type__c, 'original type kept');
        Assert.isTrue(again.Comment__c.startsWith('Option B is wrong'), 'original text kept');
        Assert.isTrue(again.Comment__c.contains('follow-up: Multiple correct answers'));
        Assert.isTrue(again.Comment__c.contains('C is also right'));

        // Another learner cannot report a question from someone else's session.
        User other = new User(
            Alias = 'rep2', Email = 'rep2@example.com', Username = 'rep2.report@example.com.test',
            LastName = 'Other', ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert other;
        System.runAs(other) {
            try {
                CertStudyController.reportQuestion(qid, 'Inaccurate', 'x');
                Assert.fail('expected an error');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not found'));
            }
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Question_Report__c]);
    }

    @IsTest
    static void contributionsAreValidatedAndApprovedResourcesBecomeCertResources() {
        // Validation
        List<List<String>> bad = new List<List<String>>{
            new List<String>{ 'Bogus', 'AI-201', 't', 'https://x.example', 'd' },
            new List<String>{ 'Study resource', null, 't', 'https://x.example', null },
            new List<String>{ 'Study resource', 'NOPE-999', 't', 'https://x.example', null },
            new List<String>{ 'Study resource', 'AI-201', 't', null, null },
            new List<String>{ 'Study resource', 'AI-201', 't', 'javascript:alert(1)', null },
            new List<String>{ 'Suggestion', null, 'idea', null, '  ' }
        };
        for (List<String> b : bad) {
            try {
                CertStudyController.submitContribution(b[0], b[1], b[2], b[3], b[4]);
                Assert.fail('expected an error for ' + b);
            } catch (AuraHandledException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Contribution__c]);

        CertStudyController.submitContribution('Study resource', 'AI-201', 'Exam guide notes', 'https://example.com/guide', 'Key points...');
        CertStudyController.submitContribution('Suggestion', null, null, null, 'Add a dark mode');
        Assert.areEqual(2, [SELECT COUNT() FROM Contribution__c WHERE Status__c = 'New' AND Submitter__c = :UserInfo.getUserId()]);

        Integer before = [SELECT COUNT() FROM Cert_Resource__c];
        Contribution__c res = [SELECT Id FROM Contribution__c WHERE Kind__c = 'Study resource'];
        update new Contribution__c(Id = res.Id, Status__c = 'Approved');
        res = [SELECT Cert_Resource__c FROM Contribution__c WHERE Id = :res.Id];
        Assert.isNotNull(res.Cert_Resource__c, 'approval creates a Cert Resource');
        Cert_Resource__c cr = [SELECT Role__c, URL__c, Content__c, Cert__r.Cert_Code__c FROM Cert_Resource__c WHERE Id = :res.Cert_Resource__c];
        Assert.areEqual('Additional', cr.Role__c);
        Assert.areEqual('AI-201', cr.Cert__r.Cert_Code__c);
        Assert.isTrue(cr.Content__c.startsWith('Exam guide notes'));

        // Re-saving an approved row does not create a second resource; suggestions never do.
        update new Contribution__c(Id = res.Id, Reviewer_Notes__c = 'ok');
        Contribution__c sug = [SELECT Id FROM Contribution__c WHERE Kind__c = 'Suggestion'];
        update new Contribution__c(Id = sug.Id, Status__c = 'Approved');
        Assert.areEqual(before + 1, [SELECT COUNT() FROM Cert_Resource__c]);
    }

    @IsTest
    static void studyLinksShowAtSessionEndAndBuildADedupedRunningList() {
        Cert__c ai = [SELECT Id FROM Cert__c WHERE Cert_Code__c = 'AI-201'];
        insert new List<Study_Link__c>{
            new Study_Link__c(Cert__c = ai.Id, Title__c = 'Prep trailmix', URL__c = 'https://trailhead.example/mix', Sort_Order__c = 1, Link_Type__c = 'Trailmix'),
            new Study_Link__c(Cert__c = ai.Id, Title__c = 'Prompting module', URL__c = 'https://trailhead.example/prompt', Sort_Order__c = 2, Domain__c = 'Prompting', Link_Type__c = 'Module'),
            new Study_Link__c(Cert__c = ai.Id, Title__c = 'Old link', URL__c = 'https://trailhead.example/old', Sort_Order__c = 0, Active__c = false)
        };

        // Ordering: a weak-section link jumps the queue; inactive links never show.
        List<Study_Link__c> picked = CertStudyService.studyLinksFor(new Set<Id>{ ai.Id }, new Set<String>{ 'prompting ' });
        Assert.areEqual(2, picked.size());
        Assert.areEqual('Prompting module', picked[0].Title__c);
        Assert.areEqual('Prep trailmix', CertStudyService.studyLinksFor(new Set<Id>{ ai.Id }, null)[0].Title__c);

        CertStudyLlm.instance = new NoopLlm();
        CertStudyController.startPractice(new List<String>{ 'AI-201' }, '{"AI-201": false}');
        CertStudyController.submitAnswer(new List<String>{ 'b' });
        CertStudyController.SummaryView s = CertStudyController.getSummary(true);
        Assert.areEqual(2, s.studyLinks.size(), 'practice summary shows the cert\'s links');
        Assert.areEqual(2, [SELECT COUNT() FROM User_Study_Link__c WHERE User__c = :UserInfo.getUserId()]);

        // Seeing them again (re-opening the summary) does not duplicate the running list.
        CertStudyController.getSummary(false);
        Assert.areEqual(2, [SELECT COUNT() FROM User_Study_Link__c]);
        CertStudyController.HistoryView h = CertStudyController.getHistory();
        Assert.areEqual(2, h.suggestedLinks.size());
        Assert.isNotNull(h.suggestedLinks[0].firstSuggested);
    }

    @IsTest
    static void fullPracticeFlow() {
        CertStudyLlm.instance = new NoopLlm();
        List<CertStudyController.CertOption> certs = CertStudyController.listCerts();
        Assert.areEqual(1, certs.size(), 'only certs with content or aggregates are listed');

        Assert.isFalse(CertStudyController.getActiveSession().hasActiveSession);

        CertStudyController.SessionView v = CertStudyController.startPractice(new List<String>{ 'AI-201' }, null);
        Assert.areEqual('AI-201', v.pendingCode, 'prerequisite prompt first');

        v = CertStudyController.startPractice(new List<String>{ 'AI-201' }, '{"AI-201": false}');
        Assert.isTrue(v.hasActiveSession);
        Assert.areEqual(72, v.certs[0].passingScore);
        Assert.isNotNull(v.question);
        Assert.areEqual(3, v.question.options.size());
        Assert.isNull(v.question.options[0].isCorrect, 'answers are not sent before grading');
        Assert.isNull(v.question.options[0].explanation);

        Assert.isNotNull(CertStudyController.getActiveSession().question, 'resume shows the same question');

        CertStudyController.GradeView g = CertStudyController.submitAnswer(new List<String>{ 'b' });
        Assert.areEqual('ok', g.status);
        Assert.isTrue(g.isCorrect);
        Assert.areEqual('Bravo is right.', g.question.options[1].explanation);
        Assert.isTrue(g.question.options[1].isCorrect);
        Assert.isNull(g.rawFeedback);

        CertStudyController.SessionView next = CertStudyController.nextQuestion();
        Assert.areEqual(2, next.question.questionNumber);
        g = CertStudyController.submitAnswer(new List<String>{ 'A' });
        Assert.isFalse(g.isCorrect);

        CertStudyController.SummaryView s = CertStudyController.getSummary(false);
        Assert.areEqual(2, s.answered);
        Assert.areEqual(50, s.pct);
        Assert.areEqual(1, s.missed.size());
        Assert.isTrue(s.sessionActive);

        s = CertStudyController.getSummary(true);
        Assert.isFalse(s.sessionActive);
        Assert.areEqual('noSession', CertStudyController.submitAnswer(new List<String>{ 'A' }).status);
        Assert.isFalse(CertStudyController.nextQuestion().hasActiveSession);
    }

    private static void shortExam(Integer questions, Integer minutes) {
        Cert__c c = [SELECT Id FROM Cert__c WHERE Cert_Code__c = 'AI-201'];
        c.Num_Questions__c = questions;
        c.Duration_Min__c = minutes;
        update c;
    }

    @IsTest
    static void testModeFullRun() {
        CertStudyLlm.instance = new NoopLlm();
        shortExam(3, 105);

        CertStudyController.SessionView v = CertStudyController.startTest('AI-201', false);
        Assert.isTrue(v.isTest);
        Assert.areEqual(3, v.questionTarget);
        Assert.isNotNull(v.question);
        Assert.isNull(v.correct, 'running score hidden during a test');
        Assert.isTrue(v.clockRunning);
        Assert.isFalse(v.strictTimer);
        Assert.isNotNull(CertStudyController.getSummary(false).error, 'no peeking at results mid-test');

        v = CertStudyController.submitTestAnswer(new List<String>{ 'B' });
        Assert.areEqual(2, v.question.questionNumber);
        Assert.isNull(v.question.options[0].isCorrect, 'no feedback between test questions');

        v = CertStudyController.pauseTest();
        Assert.isTrue(v.isPaused);
        Assert.isNull(v.question, 'paused test hides the question');
        Assert.isFalse(v.clockRunning);

        v = CertStudyController.resumeTest();
        Assert.isFalse(v.isPaused);
        Assert.isNotNull(v.question);
        Assert.isTrue(v.clockRunning);

        v = CertStudyController.submitTestAnswer(new List<String>{ 'A' });
        v = CertStudyController.submitTestAnswer(new List<String>{ 'B' });
        Assert.isNotNull(v.testResult, 'scored after the last question');
        Assert.areEqual(3, v.testResult.answered);
        Assert.areEqual(2, v.testResult.correct);
        Assert.areEqual(67, v.testResult.officialPct);
        Assert.areEqual(72, v.testResult.passing);
        Assert.isFalse(v.testResult.passed);
        Assert.isFalse(v.testResult.incomplete);
        Assert.areEqual(1, v.testResult.missed.size());
        Assert.isFalse(v.testResult.domains.isEmpty());
        Assert.isFalse(v.testResult.recommendations.isEmpty());
        Assert.isFalse(CertStudyController.getActiveSession().hasActiveSession);
        Assert.isNotNull(CertStudyController.getSummary(false), 'completed test summary is allowed');
    }

    @IsTest
    static void testModeEarlyFinishAndStrictTimeout() {
        CertStudyLlm.instance = new NoopLlm();
        shortExam(3, 105);
        CertStudyController.startTest('AI-201', true);
        CertStudyController.submitTestAnswer(new List<String>{ 'B' });
        CertStudyController.SessionView v = CertStudyController.finishTest();
        CertStudyController.TestResultView r = v.testResult;
        Assert.isTrue(r.incomplete);
        Assert.areEqual(2, r.unanswered);
        Assert.areEqual(33, r.officialPct, 'unanswered count as wrong');
        Assert.areEqual(100, r.answeredPct);
        Assert.isTrue(r.answeredLikelyPass);
        Assert.isFalse(r.passed);
        Boolean mentionsNotReached = false;
        for (String rec : r.recommendations) if (rec.startsWith('Not reached')) mentionsNotReached = true;
        Assert.isTrue(mentionsNotReached, 'sections never reached are called out');

        // strict timer: time already used up -> scored as timed out on next load
        CertStudyController.startTest('AI-201', true);
        Study_Session__c s = [SELECT Id FROM Study_Session__c WHERE Status__c = 'Active' AND Mode__c = 'Test'];
        s.Elapsed_Seconds__c = 105 * 60;
        s.Resumed_At__c = null;
        update s;
        v = CertStudyController.getActiveSession();
        Assert.isNotNull(v.testResult);
        Assert.isTrue(v.testResult.timedOut);
    }

    @IsTest
    static void testModeQuotasAndErrors() {
        CertStudyLlm.instance = new NoopLlm();
        Assert.isNotNull(CertStudyController.startTest('FOUND-101', false).error, 'no study material');
        Assert.isNotNull(CertStudyController.startTest(null, false).error);
        Cert__c c = [SELECT Id, Domains_JSON__c FROM Cert__c WHERE Cert_Code__c = 'AI-201'];
        Map<String, Integer> q = CertStudyService.domainQuotas(c, 60);
        Assert.areEqual(21, q.get('AI Agents'));
        Assert.areEqual(39, q.get('Prompting'));
        Assert.areEqual(CertStudyGenerator.POOL_SIZE, CertStudyService.poolTarget(c.Id), 'normal pool size when no test is running');
    }

    private class OverviewLlm implements CertStudyLlm.Client {
        public String generate(String prompt) {
            return '{"duration_min":105,"num_questions":60,"passing_score":65,'
                + '"domain_names":["Configuration","Security","Automation"],"domain_weights":[40,35,25]}';
        }
    }

    private static User makeUser(String suffix) {
        Profile p = [SELECT Id FROM Profile WHERE Name IN ('Standard User', 'System Administrator') ORDER BY Name DESC LIMIT 1];
        return new User(
            LastName = 'Learner ' + suffix, Alias = 'lrn' + suffix,
            Email = 'same.email@example.com', // deliberately identical: identity must not depend on email
            Username = 'certstudy.learner' + suffix + '.' + DateTime.now().getTime() + '@example.com',
            ProfileId = p.Id, EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US', TimeZoneSidKey = 'America/Los_Angeles'
        );
    }

    @IsTest
    static void twoUsersSameCertSameTimeStaySeparate() {
        CertStudyLlm.instance = new NoopLlm();
        User u1 = makeUser('1');
        User u2 = makeUser('2');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ u1, u2 };
        }
        CertStudyController.SessionView v1;
        CertStudyController.SessionView v2;
        System.runAs(u1) {
            v1 = CertStudyController.startPractice(new List<String>{ 'AI-201' }, '{"AI-201": false}');
        }
        System.runAs(u2) {
            v2 = CertStudyController.startPractice(new List<String>{ 'AI-201' }, '{"AI-201": false}');
        }
        Assert.areNotEqual(v1.question.id, v2.question.id, 'two learners never get the same question row');
        System.runAs(u1) {
            CertStudyController.submitAnswer(new List<String>{ 'B' });
        }
        System.runAs(u2) {
            CertStudyController.SessionView mine = CertStudyController.getActiveSession();
            Assert.areEqual(0, mine.answered, 'another learner\'s answer does not show up in my session');
            Assert.areEqual(v2.question.id, mine.question.id);
        }
        List<Study_Session__c> sessions = [SELECT User_Key__c, User__c FROM Study_Session__c WHERE Status__c = 'Active'];
        Assert.areEqual(2, sessions.size(), 'starting a session does not end the other learner\'s session');
        Assert.areNotEqual(sessions[0].User_Key__c, sessions[1].User_Key__c);
        for (Study_Session__c s : sessions) Assert.areEqual(s.User_Key__c, String.valueOf(s.User__c));
    }

    @IsTest
    static void overviewRederiveFixesObjectiveLists() {
        Cert__c c = [SELECT Id FROM Cert__c WHERE Cert_Code__c = 'AI-201'];
        List<Map<String, Object>> bad = new List<Map<String, Object>>();
        for (Integer i = 0; i < 28; i++) bad.add(new Map<String, Object>{ 'name' => 'Objective ' + i, 'weight_pct' => 3.57 });
        c.Domains_JSON__c = JSON.serialize(bad);
        c.Overview_Derived_At__c = DateTime.now();
        update c;
        CertStudyLlm.instance = new OverviewLlm();
        Test.startTest();
        Assert.areEqual(1, CertStudyOverviewJob.rederiveSuspect());
        Test.stopTest();
        Cert__c after = [SELECT Domains_JSON__c, Passing_Score__c FROM Cert__c WHERE Id = :c.Id];
        Assert.areEqual(3, CertStudyGenerator.domains(after).size());
        Assert.areEqual(65, after.Passing_Score__c.intValue());
        Cert__c tooMany = new Cert__c(Name = 'x', Cert_Code__c = 'x');
        String rawMany = '{"duration_min":1,"num_questions":1,"passing_score":1,"domain_names":["1","2","3","4","5","6","7","8","9","10","11","12","13"],"domain_weights":[]}';
        Assert.isFalse(CertStudyGenerator.applyOverview(rawMany, tooMany), 'objective lists are rejected');
    }

    // History is checked across three tests: each session start/finish now also picks
    // Trailhead study links, so one transaction holding everything goes past 100 SOQL queries.
    // (In the app each click is its own transaction.)

    private static void practiceTwoAnswers() {
        CertStudyController.startPractice(new List<String>{ 'AI-201' }, '{"AI-201": false}');
        CertStudyController.submitAnswer(new List<String>{ 'B' });
        CertStudyController.nextQuestion();
        CertStudyController.submitAnswer(new List<String>{ 'A' });
        CertStudyController.getSummary(true);
    }

    private static void failedShortTest() {
        shortExam(3, 105);
        CertStudyController.startTest('AI-201', false);
        CertStudyController.submitTestAnswer(new List<String>{ 'B' });
        CertStudyController.finishTest();
    }

    private static CertStudyController.HistorySession findRow(CertStudyController.HistoryView h, Boolean isTest) {
        for (CertStudyController.HistorySession hs : h.sessions) {
            if (hs.isTest == isTest) return hs;
        }
        return null;
    }

    @IsTest
    static void historyAcrossSessions() {
        CertStudyLlm.instance = new NoopLlm();
        Assert.areEqual(0, CertStudyController.getHistory().sessionsCount);
        practiceTwoAnswers();

        Test.startTest();
        failedShortTest();
        CertStudyController.HistoryView h = CertStudyController.getHistory();
        Test.stopTest();

        Assert.areEqual(2, h.sessionsCount);
        Assert.areEqual(3, h.totalAnswered);
        Assert.areEqual(2, h.totalCorrect);
        Assert.areEqual(1, h.testsTaken);
        Assert.areEqual(0, h.testsPassed);
        Assert.isFalse(h.weakAreas.isEmpty(), 'areas with 2+ answers are ranked');
        CertStudyController.HistorySession testRow = findRow(h, true);
        Assert.areEqual(33, testRow.officialPct);
        Assert.isTrue(testRow.completed);
        Assert.areEqual(50, findRow(h, false).pct);
    }

    @IsTest
    static void historyReopensPracticeOnlyForOwner() {
        CertStudyLlm.instance = new NoopLlm();
        practiceTwoAnswers();
        User other = makeUser('3');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert other;
        }

        Test.startTest();
        CertStudyController.HistorySession practiceRow = findRow(CertStudyController.getHistory(), false);
        Assert.isNotNull(CertStudyController.getSessionDetail(practiceRow.id).practice);
        System.runAs(other) {
            Assert.isNotNull(CertStudyController.getSessionDetail(practiceRow.id).error, 'cannot open someone else\'s session');
            Assert.areEqual(0, CertStudyController.getHistory().sessionsCount);
        }
        Test.stopTest();
    }

    @IsTest
    static void historyReopensTestResult() {
        CertStudyLlm.instance = new NoopLlm();
        failedShortTest();

        Test.startTest();
        CertStudyController.HistorySession testRow = findRow(CertStudyController.getHistory(), true);
        Assert.isNotNull(CertStudyController.getSessionDetail(testRow.id).test);
        Test.stopTest();
        Study_Session__c stored = [SELECT Score_Pct__c, Passed__c FROM Study_Session__c WHERE Id = :testRow.id];
        Assert.areEqual(33, stored.Score_Pct__c, 'score is stored for reporting');
        Assert.isFalse(stored.Passed__c);
    }

    @IsTest
    static void errorsAndFallbacks() {
        CertStudyLlm.instance = new NoopLlm();
        Assert.isNotNull(CertStudyController.startPractice(new List<String>{ 'NOPE' }, null).error);
        Assert.isFalse(CertStudyController.getSummary(false).hasSession);
        Assert.isTrue(CertStudyController.splitFeedback('free text without structure').isEmpty());
        Assert.areEqual('x', CertStudyController.splitFeedback('**C. Opt** -- Correct: x').get('C'));
    }
}
