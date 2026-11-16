@IsTest
private class CertStudyRemindersTest {
    private static User learner;

    private static void makeLearner() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String uniq = String.valueOf(Math.abs(Crypto.getRandomLong()));
            learner = new User(
                FirstName = 'Rem', LastName = 'Learner', Alias = 'remlrn', Email = 'rem' + uniq + '@example.com',
                Username = 'rem' + uniq + '@example.com.certstudy', ProfileId = UserInfo.getProfileId(),
                TimeZoneSidKey = 'GMT', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert learner;
        }
    }

    private static Cert__c makeCert() {
        Cert__c c = new Cert__c(Name = 'Reminder Cert', Cert_Code__c = 'REM-1',
            Domains_JSON__c = '[{"name":"Agents","weight_pct":100}]');
        insert c;
        return c;
    }

    private static void goal(Cert__c c, Date examDate) {
        insert new Study_Goal__c(User__c = learner.Id, Cert__c = c.Id, Exam_Date__c = examDate, Status__c = 'Studying');
    }

    private static Reminder_Setting__c setting(String cadence, String day, Boolean ramp) {
        Reminder_Setting__c s = new Reminder_Setting__c(
            Unique_Key__c = String.valueOf(learner.Id), User__c = learner.Id, Email_Enabled__c = true,
            Cadence__c = cadence, Weekly_Day__c = day, Ramp_Final_Week__c = ramp
        );
        insert s;
        return s;
    }

    private static void otherLearnersAnsweredQuestion(Cert__c c) {
        Study_Session__c ss = new Study_Session__c(
            User_Key__c = 'other@example.com', Cert_Codes__c = ';' + c.Id + ';', Status__c = 'Active',
            Started_At__c = DateTime.now(), Last_Activity__c = DateTime.now()
        );
        insert ss;
        insert new Question__c(
            Study_Session__c = ss.Id, Cert__c = c.Id, Stem__c = 'Which tool grounds prompts?', Format__c = 'single',
            Difficulty__c = 1, Domain__c = 'Agents', Status__c = 'Answered',
            Options_JSON__c = '[{"key":"A","text":"Prompt Builder"},{"key":"B","text":"Flow"}]',
            Correct_JSON__c = '["A"]', Feedback_MD__c = 'A is right.'
        );
    }

    @IsTest
    static void cadenceRulesFollowTheCalendar() {
        Date wed = Date.newInstance(2026, 11, 18);
        System.assertEquals(3, CertStudyReminders.weekdayIndex(wed));
        System.assert(CertStudyReminders.isDueToday('Daily', 'Monday', false, wed, null));
        System.assert(CertStudyReminders.isDueToday('Weekdays', 'Monday', false, wed, null));
        System.assert(!CertStudyReminders.isDueToday('Weekdays', 'Monday', false, Date.newInstance(2026, 11, 21), null));
        System.assert(!CertStudyReminders.isDueToday('Twice a week', 'Monday', false, wed, null));
        System.assert(CertStudyReminders.isDueToday('Twice a week', 'Monday', false, Date.newInstance(2026, 11, 19), null));
        System.assert(CertStudyReminders.isDueToday('Weekly', 'Wednesday', false, wed, null));
        System.assert(!CertStudyReminders.isDueToday('Weekly', 'Monday', false, wed, null));
        // final-week ramp overrides the cadence, but only inside 7 days
        System.assert(CertStudyReminders.isDueToday('Weekly', 'Monday', true, wed, wed.addDays(5)));
        System.assert(!CertStudyReminders.isDueToday('Weekly', 'Monday', true, wed, wed.addDays(20)));
        System.assert(!CertStudyReminders.isDueToday('Weekly', 'Monday', false, wed, wed.addDays(5)));
    }

    @IsTest
    static void settingsSaveWithDefaultsAndValidation() {
        System.assertEquals(false, CertStudyReminders.getSetting(UserInfo.getUserId()).emailEnabled);
        CertStudyReminders.Setting s = CertStudyReminders.saveSetting(UserInfo.getUserId(), true, 'Weekdays', 'Monday', false);
        System.assertEquals(true, s.emailEnabled);
        System.assertEquals('Weekdays', s.cadence);
        System.assertEquals(false, s.ramp);
        CertStudyReminders.saveSetting(UserInfo.getUserId(), false, 'Daily', 'Monday', true); // upsert, no duplicate
        System.assertEquals(1, [SELECT COUNT() FROM Reminder_Setting__c]);
        try {
            CertStudyReminders.saveSetting(UserInfo.getUserId(), true, 'Hourly', 'Monday', true);
            System.assert(false, 'bad cadence should throw');
        } catch (CertStudyReminders.ReminderException e) {
            System.assert(e.getMessage().contains('how often'));
        }
    }

    @IsTest
    static void dueListHonoursTimeCadenceHistoryAndGoals() {
        makeLearner();
        Cert__c c = makeCert();
        goal(c, Date.newInstance(2026, 12, 30));
        Reminder_Setting__c s = setting('Weekly', 'Wednesday', true);
        DateTime noon = DateTime.newInstanceGmt(2026, 11, 18, 12, 0, 0); // a Wednesday, learner is on GMT
        System.assertEquals(new List<Id>{ s.Id }, CertStudyReminders.dueSettingIds(noon));
        System.assertEquals(0, CertStudyReminders.dueSettingIds(DateTime.newInstanceGmt(2026, 11, 18, 7, 0, 0)).size(), 'before 9am');
        System.assertEquals(0, CertStudyReminders.dueSettingIds(DateTime.newInstanceGmt(2026, 11, 17, 12, 0, 0)).size(), 'not their day');
        s.Last_Sent_On__c = Date.newInstance(2026, 11, 18);
        update s;
        System.assertEquals(0, CertStudyReminders.dueSettingIds(noon).size(), 'already sent today');
        s.Last_Sent_On__c = null;
        s.Email_Enabled__c = false;
        update s;
        System.assertEquals(0, CertStudyReminders.dueSettingIds(noon).size(), 'switched off');
        s.Email_Enabled__c = true;
        update s;
        delete [SELECT Id FROM Study_Goal__c];
        System.assertEquals(0, CertStudyReminders.dueSettingIds(noon).size(), 'no upcoming exam');
        goal(c, Date.newInstance(2026, 11, 10)); // overdue only
        System.assertEquals(0, CertStudyReminders.dueSettingIds(noon).size(), 'overdue exams do not count');
    }

    @IsTest
    static void finalWeekRampSendsOutsideTheCadenceDay() {
        makeLearner();
        Cert__c c = makeCert();
        goal(c, Date.newInstance(2026, 11, 23));
        Reminder_Setting__c s = setting('Weekly', 'Monday', true);
        DateTime tue = DateTime.newInstanceGmt(2026, 11, 17, 12, 0, 0);
        System.assertEquals(1, CertStudyReminders.dueSettingIds(tue).size());
        s.Ramp_Final_Week__c = false;
        update s;
        System.assertEquals(0, CertStudyReminders.dueSettingIds(tue).size());
    }

    @IsTest
    static void planListsExamsAndAddsASampleFromOthers() {
        makeLearner();
        Cert__c c = makeCert();
        Date today = Date.newInstance(2026, 11, 18);
        goal(c, today.addDays(3));
        otherLearnersAnsweredQuestion(c);
        CertStudyReminders.Plan p = CertStudyReminders.buildPlan(learner.Id, 'Rem', today);
        System.assertNotEquals(null, p);
        System.assertEquals('Cert Study: Reminder Cert in 3 days', p.subject);
        System.assertEquals(1, p.samples.size());
        System.assertEquals('A. Prompt Builder', p.samples[0].answer);
        String html = CertStudyReminders.htmlFor(p);
        System.assert(html.contains('Which tool grounds prompts?'));
        System.assert(html.contains('Answer: A. Prompt Builder'));
        System.assert(html.contains(CertStudyReminders.SITE_URL));
        System.assert(CertStudyReminders.textFor(p).contains('Reminder Cert: in 3 days'));
        System.assertEquals(null, CertStudyReminders.buildPlan(UserInfo.getUserId(), 'X', today), 'no goals means no plan');
    }

    @IsTest
    static void ownQuestionsAreNeverTheSample() {
        makeLearner();
        Cert__c c = makeCert();
        goal(c, Date.today().addDays(10));
        Study_Session__c ss = new Study_Session__c(
            User_Key__c = String.valueOf(learner.Id), Cert_Codes__c = ';' + c.Id + ';', Status__c = 'Active',
            Started_At__c = DateTime.now(), Last_Activity__c = DateTime.now()
        );
        insert ss;
        insert new Question__c(
            Study_Session__c = ss.Id, Cert__c = c.Id, Stem__c = 'Mine', Format__c = 'single', Difficulty__c = 1,
            Domain__c = 'Agents', Status__c = 'Answered', Options_JSON__c = '[{"key":"A","text":"x"}]',
            Correct_JSON__c = '["A"]', Feedback_MD__c = 'f'
        );
        CertStudyReminders.Plan p = CertStudyReminders.buildPlan(learner.Id, 'Rem', Date.today());
        System.assertEquals(0, p.samples.size());
    }

    @IsTest
    static void sendingStampsTheLearnerAndTestSendWorks() {
        makeLearner();
        Cert__c c = makeCert();
        goal(c, Date.today().addDays(10));
        otherLearnersAnsweredQuestion(c);
        Reminder_Setting__c s = setting('Daily', 'Monday', true);
        Test.startTest();
        CertStudyReminders.sendFor(s.Id);
        CertStudyReminders.sendTest(learner.Id);
        Test.stopTest();
        Reminder_Setting__c after = [SELECT Last_Sent_On__c, Last_Error__c FROM Reminder_Setting__c WHERE Id = :s.Id];
        System.assertNotEquals(null, after.Last_Sent_On__c);
        System.assertEquals(null, after.Last_Error__c);
        System.assertEquals(1, CertStudyReminders.lastBatch.size());
    }

    @IsTest
    static void testSendNeedsAnUpcomingExam() {
        makeLearner();
        try {
            CertStudyReminders.sendTest(learner.Id);
            System.assert(false, 'should throw');
        } catch (CertStudyReminders.ReminderException e) {
            System.assert(e.getMessage().contains('upcoming exam'));
        }
    }

    @IsTest
    static void scheduleIsIdempotentAndBatchRuns() {
        makeLearner();
        Cert__c c = makeCert();
        goal(c, Date.today().addDays(2));
        Reminder_Setting__c s = setting('Daily', 'Monday', true);
        Test.startTest();
        String a = CertStudyReminders.scheduleHourly();
        String b = CertStudyReminders.scheduleHourly();
        System.assertEquals(a, b);
        Database.executeBatch(new CertStudyReminders(), 1); // empty id list means an empty scope, no error
        Test.stopTest();
    }

    @IsTest
    static void controllerRoundTrip() {
        CertStudyController.ReminderView v = CertStudyController.saveReminderSettings(true, 'Twice a week', 'Monday', true);
        System.assertEquals(true, v.emailEnabled);
        System.assertEquals('Twice a week', CertStudyController.getReminderSettings().cadence);
        try {
            CertStudyController.sendTestReminder();
            System.assert(false, 'no exam, should throw');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}
