@IsTest
private class CertStudyDigestTest {
    @TestSetup
    static void setup() {
        Cert__c c = new Cert__c(Name = 'Agentforce Specialist', Cert_Code__c = 'AI-201');
        Cert__c broken = new Cert__c(Name = 'Platform Foundations', Cert_Code__c = 'FOUND-101');
        insert new List<Cert__c>{ c, broken };
        insert new Question__c(
            Cert__c = c.Id, Stem__c = 'Which tool builds agents?', Format__c = 'single3', Difficulty__c = 2,
            Options_JSON__c = '[{"key":"A","text":"Alpha"},{"key":"B","text":"Bravo"},{"key":"C","text":"Charlie"}]',
            Correct_JSON__c = '["B"]', Status__c = 'Ready'
        );
    }

    private static void seedOpenItems() {
        Cert__c c = [SELECT Id FROM Cert__c WHERE Cert_Code__c = 'AI-201'];
        Question__c q = [SELECT Id FROM Question__c LIMIT 1];
        Question_Report__c fresh = new Question_Report__c(Question__c = q.Id, Cert__c = c.Id, Reporter__c = UserInfo.getUserId(),
            Issue_Type__c = 'Outdated', Comment__c = 'Renamed last release <b>', Status__c = 'New');
        Question_Report__c old = new Question_Report__c(Question__c = q.Id, Cert__c = c.Id, Reporter__c = UserInfo.getUserId(),
            Issue_Type__c = 'Inaccurate', Status__c = 'New');
        Question_Report__c done = new Question_Report__c(Question__c = q.Id, Cert__c = c.Id, Reporter__c = UserInfo.getUserId(),
            Issue_Type__c = 'Other', Comment__c = 'x', Status__c = 'Fixed');
        insert new List<Question_Report__c>{ fresh, old, done };
        Test.setCreatedDate(old.Id, DateTime.now().addDays(-3));
        insert new List<Contribution__c>{
            new Contribution__c(Kind__c = 'Suggestion', Title__c = 'Dark mode', Details__c = 'Please', Submitter__c = UserInfo.getUserId(), Status__c = 'New'),
            new Contribution__c(Kind__c = 'Suggestion', Title__c = 'Already handled', Submitter__c = UserInfo.getUserId(), Status__c = 'Rejected')
        };
        update new Cert__c(Id = [SELECT Id FROM Cert__c WHERE Cert_Code__c = 'FOUND-101'].Id,
            Last_Failure_At__c = DateTime.now().addHours(-2), Last_Generation_Error__c = 'Callout failed');
    }

    @IsTest
    static void nothingOpenMeansNoEmail() {
        Test.startTest();
        Assert.isTrue(CertStudyDigest.build(DateTime.now()).isEmpty());
        Assert.areEqual(0, CertStudyDigest.sendNow());
        Assert.areEqual(0, Limits.getEmailInvocations());
        Test.stopTest();
    }

    @IsTest
    static void digestListsOpenItemsAndFlagsOverdue() {
        seedOpenItems();
        CertStudyDigest.Digest d = CertStudyDigest.build(DateTime.now());
        Assert.areEqual(2, d.issueTotal, 'Fixed issues are left out');
        Assert.areEqual(1, d.contributionTotal, 'Rejected contributions are left out');
        Assert.areEqual(1, d.failures.size());
        Assert.areEqual(1, d.overdueTotal);
        Assert.isTrue(d.issues[0].overdue, 'oldest first, and it is past 48h');
        Assert.isFalse(d.issues[1].overdue);
        Assert.areEqual(2, d.issuesByCert.get('Agentforce Specialist'));

        String subject = CertStudyDigest.subjectFor(d);
        Assert.isTrue(subject.contains('2 question issues'), subject);
        Assert.isTrue(subject.contains('1 contribution'), subject);
        Assert.isTrue(subject.contains('1 past 48h'), subject);
        String html = CertStudyDigest.htmlFor(d);
        Assert.isTrue(html.contains('OVERDUE'));
        Assert.isTrue(html.contains('Dark mode'));
        Assert.isTrue(html.contains('&lt;b&gt;'), 'comments are HTML-escaped');
        Assert.isTrue(CertStudyDigest.textFor(d).contains('Callout failed'));
    }

    @IsTest
    static void sendsToAdmins() {
        seedOpenItems();
        Id me = UserInfo.getUserId();
        System.runAs(new User(Id = me)) {
            Id ps = [SELECT Id FROM PermissionSet WHERE Name = :CertStudyDigest.ADMIN_PERM_SET].Id;
            if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :me AND PermissionSetId = :ps] == 0) {
                insert new PermissionSetAssignment(AssigneeId = me, PermissionSetId = ps);
            }
        }
        Test.startTest();
        Integer sent = CertStudyDigest.sendNow();
        Test.stopTest();
        if (CertStudyDigest.lastError == null) {
            Assert.areEqual(CertStudyDigest.adminUserIds().size(), sent);
            Assert.isTrue(sent >= 1);
        } else {
            // e.g. org deliverability is off: the digest must fail quietly, not throw.
            Assert.isTrue(sent < CertStudyDigest.adminUserIds().size());
        }
    }

    @IsTest
    static void scheduleDailyIsIdempotent() {
        Test.startTest();
        String first = CertStudyDigest.scheduleDaily();
        Assert.areEqual(first, CertStudyDigest.scheduleDaily());
        Test.stopTest();
    }

    @IsTest
    static void sendsOnlyAt3pmPacific() {
        // 23:00 UTC on Jan 15 = 15:00 PST; 22:00 UTC on Jul 15 = 15:00 PDT.
        Assert.isTrue(CertStudyDigest.isSendHour(DateTime.newInstanceGmt(2027, 1, 15, 23, 0, 0)));
        Assert.isTrue(CertStudyDigest.isSendHour(DateTime.newInstanceGmt(2027, 7, 15, 22, 0, 0)));
        Assert.isFalse(CertStudyDigest.isSendHour(DateTime.newInstanceGmt(2027, 1, 15, 22, 0, 0)));
        Assert.isFalse(CertStudyDigest.isSendHour(DateTime.newInstanceGmt(2027, 1, 15, 14, 0, 0)));
    }

    @IsTest
    static void ageTextReadsNaturally() {
        Assert.areEqual('under 1h old', CertStudyDigest.ageText(0));
        Assert.areEqual('5h old', CertStudyDigest.ageText(5));
        Assert.areEqual('3 days old', CertStudyDigest.ageText(72));
    }
}
