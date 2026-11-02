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

    @IsTest
    static void errorsAndFallbacks() {
        CertStudyLlm.instance = new NoopLlm();
        Assert.isNotNull(CertStudyController.startPractice(new List<String>{ 'NOPE' }, null).error);
        Assert.isFalse(CertStudyController.getSummary(false).hasSession);
        Assert.isTrue(CertStudyController.splitFeedback('free text without structure').isEmpty());
        Assert.areEqual('x', CertStudyController.splitFeedback('**C. Opt** -- Correct: x').get('C'));
    }
}
