@IsTest
private class CertStudyRepliesTest {
    @TestSetup
    static void setup() {
        Cert__c c = new Cert__c(Name = 'Agentforce Specialist', Cert_Code__c = 'AI-201');
        insert c;
        Question__c q = new Question__c(
            Cert__c = c.Id, Stem__c = 'Which tool builds agents?', Format__c = 'single3', Difficulty__c = 2,
            Options_JSON__c = '[{"key":"A","text":"Alpha"},{"key":"B","text":"Bravo"},{"key":"C","text":"Charlie"}]',
            Correct_JSON__c = '["B"]', Status__c = 'Ready'
        );
        insert q;
        insert new Question_Report__c(Question__c = q.Id, Cert__c = c.Id, Reporter__c = UserInfo.getUserId(),
            Issue_Type__c = 'Outdated', Comment__c = 'Renamed', Status__c = 'New');
        insert new List<Contribution__c>{
            new Contribution__c(Kind__c = 'Suggestion', Title__c = 'Dark mode', Details__c = 'Please',
                Submitter__c = UserInfo.getUserId(), Status__c = 'New'),
            new Contribution__c(Kind__c = 'Study resource', Cert__c = c.Id, Title__c = 'My notes',
                Details__c = 'Agents are built in Agent Builder.', Submitter__c = UserInfo.getUserId(), Status__c = 'New')
        };
    }

    @IsTest
    static void fixedIssueEmailsTheReporterOnce() {
        Question_Report__c r = [SELECT Id FROM Question_Report__c LIMIT 1];
        Test.startTest();
        update new Question_Report__c(Id = r.Id, Status__c = 'Reviewing');
        Assert.isTrue(CertStudyReplies.lastBatch.isEmpty(), 'Reviewing is not a decision');

        update new Question_Report__c(Id = r.Id, Status__c = 'Fixed', Reviewer_Notes__c = 'internal only', Note_To_Learner__c = 'Updated the <guide>.');
        Assert.areEqual(1, CertStudyReplies.lastBatch.size());
        Messaging.SingleEmailMessage m = CertStudyReplies.lastBatch[0];
        Assert.areEqual(UserInfo.getUserId(), m.getTargetObjectId());
        Assert.isTrue(m.getSubject().endsWith(': fixed'), m.getSubject());
        Assert.isTrue(m.getPlainTextBody().contains('made a fix'));
        Assert.isTrue(m.getPlainTextBody().contains('Updated the <guide>.'));
        Assert.isTrue(m.getHtmlBody().contains('Updated the &lt;guide&gt;.'), 'notes are escaped in HTML');
        Assert.isTrue(m.getPlainTextBody().contains('Which tool builds agents?'));
        Assert.isFalse(m.getPlainTextBody().contains('internal only'), 'Reviewer Notes are never sent');
        Assert.isNotNull([SELECT Reply_Sent_At__c FROM Question_Report__c WHERE Id = :r.Id].Reply_Sent_At__c);

        CertStudyReplies.lastBatch = new List<Messaging.SingleEmailMessage>();
        update new Question_Report__c(Id = r.Id, Status__c = 'Dismissed');
        Assert.isTrue(CertStudyReplies.lastBatch.isEmpty(), 'only one reply per item');
        Test.stopTest();
    }

    @IsTest
    static void contributionDecisionsEmailTheSubmitter() {
        Map<String, Contribution__c> byKind = new Map<String, Contribution__c>();
        for (Contribution__c c : [SELECT Id, Kind__c FROM Contribution__c]) byKind.put(c.Kind__c, c);
        Test.startTest();
        update new Contribution__c(Id = byKind.get('Study resource').Id, Status__c = 'Approved');
        Assert.areEqual(1, CertStudyReplies.lastBatch.size());
        String body = CertStudyReplies.lastBatch[0].getPlainTextBody();
        Assert.isTrue(body.contains('We approved it'), body);
        Assert.isTrue(body.contains('Agentforce Specialist'), body);
        Assert.isNotNull([SELECT Cert_Resource__c FROM Contribution__c WHERE Id = :byKind.get('Study resource').Id].Cert_Resource__c,
            'approval still creates the Cert Resource');

        update new Contribution__c(Id = byKind.get('Suggestion').Id, Status__c = 'Rejected');
        Assert.areEqual(1, CertStudyReplies.lastBatch.size());
        Assert.isTrue(CertStudyReplies.lastBatch[0].getSubject().contains('suggestion'));
        Assert.isTrue(CertStudyReplies.lastBatch[0].getPlainTextBody().contains('not to take it forward'));
        Test.stopTest();
    }

    @IsTest
    static void bulkDecisionsSendOneBatch() {
        List<Contribution__c> rows = [SELECT Id FROM Contribution__c];
        for (Contribution__c c : rows) c.Status__c = 'Rejected';
        Test.startTest();
        update rows;
        Assert.areEqual(2, CertStudyReplies.lastBatch.size());
        Assert.isTrue(Limits.getEmailInvocations() <= 1);
        Test.stopTest();
    }

    @IsTest
    static void greetingFallsBackWithoutAFirstName() {
        Messaging.SingleEmailMessage m = CertStudyReplies.mail(UserInfo.getUserId(), 's', null, 'Intro.', 'Outcome.',
            new List<String>(), null);
        Assert.isTrue(m.getPlainTextBody().startsWith('Hi there,'));
        Assert.isFalse(m.getPlainTextBody().contains('Note from the reviewer'));
    }
}
