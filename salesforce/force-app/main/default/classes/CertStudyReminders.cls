/**
 * Study reminders: an email digest for learners who turned reminders on in My exams and have an upcoming exam.
 *
 * Flow: the hourly schedule (execute) finds learners who are due right now (their local time is 9am or later,
 * nothing sent yet today, today fits their cadence), then runs a batch of size 1 so each learner's email
 * (including a sample question) gets its own governor limits.
 *
 * Schedule once from Anonymous Apex:  CertStudyReminders.scheduleHourly();
 * Send yourself one now (ignores cadence):  CertStudyReminders.sendTest(UserInfo.getUserId());
 */
public without sharing class CertStudyReminders implements Schedulable, Database.Batchable<SObject> {
    public static final String JOB_NAME = 'Cert Study reminders';
    public static final String CRON = '0 5 * * * ?'; // five past every hour; each learner is sent once a day
    public static final Integer SEND_HOUR = 9;       // learner-local; later hours catch up a missed one
    public static final Integer FINAL_WEEK_DAYS = 7;
    public static final Integer MAX_SAMPLES = 2;
    public static final String SITE_URL = CertStudyReplies.SITE_URL;
    public static final String REPLY_TO = CertStudyReplies.REPLY_TO;
    public static final List<String> CADENCES = new List<String>{ 'Daily', 'Weekdays', 'Twice a week', 'Weekly' };
    /** Index = days since a Sunday, modulo 7 (locale independent). */
    public static final List<String> DAYS = new List<String>{
        'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
    };

    public static String lastError;
    @TestVisible private static List<Messaging.SingleEmailMessage> lastBatch = new List<Messaging.SingleEmailMessage>();

    public class ReminderException extends Exception {}

    private List<Id> settingIds;

    public CertStudyReminders() {}

    private CertStudyReminders(List<Id> ids) {
        settingIds = ids;
    }

    // ------------------------------------------------------------ schedule + batch

    public void execute(SchedulableContext ctx) {
        List<Id> due = dueSettingIds(DateTime.now());
        if (!due.isEmpty()) Database.executeBatch(new CertStudyReminders(due), 1);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        List<Id> ids = settingIds == null ? new List<Id>() : settingIds;
        return Database.getQueryLocator([SELECT Id FROM Reminder_Setting__c WHERE Id IN :ids]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        for (SObject s : scope) sendFor((Id) s.Id);
    }

    public void finish(Database.BatchableContext bc) {}

    /** Idempotent: returns the existing job's Id if already scheduled. */
    public static String scheduleHourly() {
        List<CronTrigger> existing = [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME AND NextFireTime != null LIMIT 1
        ];
        if (!existing.isEmpty()) return String.valueOf(existing[0].Id);
        return String.valueOf((Id) System.schedule(JOB_NAME, CRON, new CertStudyReminders()));
    }

    // ------------------------------------------------------------ settings

    public class Setting {
        public Boolean emailEnabled = false;
        public Boolean slackEnabled = false;
        public String cadence = 'Weekly';
        public String weeklyDay = 'Monday';
        public Boolean ramp = true;
    }

    public static Setting getSetting(Id userId) {
        Setting s = new Setting();
        List<Reminder_Setting__c> rows = [
            SELECT Email_Enabled__c, Slack_Enabled__c, Cadence__c, Weekly_Day__c, Ramp_Final_Week__c
            FROM Reminder_Setting__c WHERE Unique_Key__c = :String.valueOf(userId) LIMIT 1
        ];
        if (rows.isEmpty()) return s;
        s.emailEnabled = rows[0].Email_Enabled__c == true;
        s.slackEnabled = rows[0].Slack_Enabled__c == true;
        if (String.isNotBlank(rows[0].Cadence__c)) s.cadence = rows[0].Cadence__c;
        if (String.isNotBlank(rows[0].Weekly_Day__c)) s.weeklyDay = rows[0].Weekly_Day__c;
        s.ramp = rows[0].Ramp_Final_Week__c != false;
        return s;
    }

    public static Setting saveSetting(Id userId, Boolean emailEnabled, String cadence, String weeklyDay, Boolean ramp) {
        if (!CADENCES.contains(cadence)) throw new ReminderException('Pick how often you want reminders.');
        if (cadence == 'Weekly' && !DAYS.contains(weeklyDay)) throw new ReminderException('Pick a day of the week.');
        upsert new Reminder_Setting__c(
            Unique_Key__c = String.valueOf(userId), User__c = userId,
            Email_Enabled__c = emailEnabled == true, Slack_Enabled__c = false,
            Cadence__c = cadence, Weekly_Day__c = DAYS.contains(weeklyDay) ? weeklyDay : 'Monday',
            Ramp_Final_Week__c = ramp != false
        ) Reminder_Setting__c.Unique_Key__c;
        return getSetting(userId);
    }

    // ------------------------------------------------------------ who is due

    /** Learner-local date and hour for an instant. */
    public static Date localDate(DateTime t, String tz) {
        return Date.valueOf(t.format('yyyy-MM-dd', tz));
    }

    public static Integer localHour(DateTime t, String tz) {
        return Integer.valueOf(t.format('H', tz));
    }

    public static Integer weekdayIndex(Date d) {
        return Math.mod(Date.newInstance(1900, 1, 7).daysBetween(d), 7); // 1900-01-07 was a Sunday
    }

    /** Does today fit this cadence? The final-week ramp (daily within 7 days of the nearest exam) overrides it. */
    public static Boolean isDueToday(String cadence, String weeklyDay, Boolean ramp, Date today, Date nearestExam) {
        if (ramp == true && nearestExam != null) {
            Integer left = today.daysBetween(nearestExam);
            if (left >= 0 && left <= FINAL_WEEK_DAYS) return true;
        }
        String day = DAYS[weekdayIndex(today)];
        if (cadence == 'Daily') return true;
        if (cadence == 'Weekdays') return day != 'Saturday' && day != 'Sunday';
        if (cadence == 'Twice a week') return day == 'Monday' || day == 'Thursday';
        return day == weeklyDay;
    }

    /** Settings that should get an email now. One settings query and one goals query, no per-learner work. */
    public static List<Id> dueSettingIds(DateTime now) {
        List<Reminder_Setting__c> settings = [
            SELECT Id, User__c, Cadence__c, Weekly_Day__c, Ramp_Final_Week__c, Last_Sent_On__c, User__r.TimeZoneSidKey
            FROM Reminder_Setting__c
            WHERE Email_Enabled__c = true AND User__c != null AND User__r.IsActive = true
            LIMIT 2000
        ];
        Set<Id> userIds = new Set<Id>();
        for (Reminder_Setting__c s : settings) userIds.add(s.User__c);
        Date floor = now.date().addDays(-1); // covers every time zone
        Map<Id, List<Date>> goalDates = new Map<Id, List<Date>>(); // null entry = a goal with no date
        for (Study_Goal__c g : [
            SELECT User__c, Exam_Date__c FROM Study_Goal__c
            WHERE User__c IN :userIds AND Status__c = 'Studying' AND Cert__c != null
                AND (Exam_Date__c = null OR Exam_Date__c >= :floor)
        ]) {
            if (!goalDates.containsKey(g.User__c)) goalDates.put(g.User__c, new List<Date>());
            goalDates.get(g.User__c).add(g.Exam_Date__c);
        }
        List<Id> due = new List<Id>();
        for (Reminder_Setting__c s : settings) {
            String tz = s.User__r.TimeZoneSidKey;
            if (localHour(now, tz) < SEND_HOUR) continue;
            Date today = localDate(now, tz);
            if (s.Last_Sent_On__c != null && s.Last_Sent_On__c >= today) continue;
            Boolean hasOpen = false;
            Date nearest = null;
            for (Date d : goalDates.containsKey(s.User__c) ? goalDates.get(s.User__c) : new List<Date>()) {
                if (d != null && d < today) continue; // overdue goals get the "did you pass?" prompt instead
                hasOpen = true;
                if (d != null && (nearest == null || d < nearest)) nearest = d;
            }
            if (!hasOpen) continue;
            if (isDueToday(s.Cadence__c, s.Weekly_Day__c, s.Ramp_Final_Week__c, today, nearest)) due.add(s.Id);
        }
        return due;
    }

    // ------------------------------------------------------------ build and send

    public class Sample {
        public String certName;
        public String section;
        public String stem;
        public List<String> options = new List<String>();
        public String answer;
    }

    public class Plan {
        public String subject;
        public String firstName;
        public List<String> examLines = new List<String>();
        public List<Sample> samples = new List<Sample>();
    }

    /** Null when the learner has no upcoming exam. */
    public static Plan buildPlan(Id userId, String firstName, Date today) {
        List<Study_Goal__c> goals = new List<Study_Goal__c>();
        for (Study_Goal__c g : [
            SELECT Exam_Date__c, Cert__c, Cert__r.Name, Cert__r.Cert_Code__c FROM Study_Goal__c
            WHERE User__c = :userId AND Status__c = 'Studying' AND Cert__c != null
            ORDER BY Exam_Date__c ASC NULLS LAST, Cert__r.Name ASC
        ]) {
            if (g.Exam_Date__c == null || g.Exam_Date__c >= today) goals.add(g);
        }
        if (goals.isEmpty()) return null;
        Plan p = new Plan();
        p.firstName = firstName;
        for (Study_Goal__c g : goals) p.examLines.add(g.Cert__r.Name + ': ' + whenText(g.Exam_Date__c, today));
        Study_Goal__c first = goals[0];
        p.subject = first.Exam_Date__c == null
            ? 'Cert Study: time for some practice'
            : 'Cert Study: ' + first.Cert__r.Name + ' ' + whenText(first.Exam_Date__c, today);
        for (Integer i = 0; i < goals.size() && p.samples.size() < MAX_SAMPLES; i++) {
            Sample s = sampleQuestion(userId, goals[i].Cert__r);
            if (s != null) p.samples.add(s);
        }
        return p;
    }

    @TestVisible
    private static String whenText(Date examDate, Date today) {
        if (examDate == null) return 'no date set';
        Integer d = today.daysBetween(examDate);
        if (d <= 0) return 'is today';
        if (d == 1) return 'is tomorrow';
        return 'in ' + d + ' days';
    }

    /**
     * One answered question from another learner, from the learner's weakest section when we know it, that the
     * learner has not been given before. It is not recorded as served, so it never uses up the learner's pool.
     */
    public static Sample sampleQuestion(Id userId, Cert__c cert) {
        String key = String.valueOf(userId);
        Set<Id> seen = new Set<Id>();
        for (Question__c c : [
            SELECT Source_Question__c FROM Question__c
            WHERE Study_Session__r.User_Key__c = :key AND Source_Question__c != null
        ]) {
            seen.add(c.Source_Question__c);
        }
        String domain = weakestDomain(key, cert.Cert_Code__c);
        List<Question__c> rows = domain == null ? new List<Question__c>() : candidates(key, cert.Id, domain, seen, true);
        if (rows.isEmpty()) rows = candidates(key, cert.Id, null, seen, false);
        if (rows.isEmpty()) return null;
        Question__c q = rows[Math.floor(Math.random() * rows.size()).intValue()];
        Sample s = new Sample();
        s.certName = cert.Name;
        s.section = q.Domain__c;
        s.stem = q.Stem__c;
        Map<String, String> texts = new Map<String, String>();
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(q.Options_JSON__c)) {
                Map<String, Object> m = (Map<String, Object>) o;
                String k = String.valueOf(m.get('key'));
                texts.put(k, String.valueOf(m.get('text')));
                s.options.add(k + '. ' + String.valueOf(m.get('text')));
            }
            List<String> answerParts = new List<String>();
            for (Object k : (List<Object>) JSON.deserializeUntyped(q.Correct_JSON__c)) {
                String ks = String.valueOf(k);
                answerParts.add(ks + '. ' + (texts.containsKey(ks) ? texts.get(ks) : ''));
            }
            s.answer = String.join(answerParts, '  |  ');
        } catch (Exception e) {
            return null; // a malformed question is never worth emailing
        }
        return s;
    }

    private static List<Question__c> candidates(String key, Id certId, String domain, Set<Id> seen, Boolean useDomain) {
        if (useDomain) {
            return [
                SELECT Id, Stem__c, Domain__c, Options_JSON__c, Correct_JSON__c FROM Question__c
                WHERE Status__c = 'Answered' AND Source_Question__c = null AND Cert__c = :certId
                    AND Domain__c = :domain AND Study_Session__r.User_Key__c != :key AND Id NOT IN :seen
                    AND Id NOT IN (SELECT Question__c FROM Question_Report__c WHERE Question__c != null)
                LIMIT 50
            ];
        }
        return [
            SELECT Id, Stem__c, Domain__c, Options_JSON__c, Correct_JSON__c FROM Question__c
            WHERE Status__c = 'Answered' AND Source_Question__c = null AND Cert__c = :certId
                AND Study_Session__r.User_Key__c != :key AND Id NOT IN :seen
                AND Id NOT IN (SELECT Question__c FROM Question_Report__c WHERE Question__c != null)
            LIMIT 50
        ];
    }

    /** The section with the highest focus weight (exam results first, else practice history); null with no history. */
    private static String weakestDomain(String key, String certCode) {
        Map<String, Map<String, Decimal>> all = CertStudyService.focusWeights(key, new Set<String>{ certCode });
        Map<String, Decimal> w = all.get(certCode);
        if (w == null || w.isEmpty()) return null;
        String best = null;
        for (String d : w.keySet()) if (best == null || w.get(d) > w.get(best)) best = d;
        return best;
    }

    /** Sends the scheduled reminder for one setting and stamps the learner's local date. */
    public static void sendFor(Id settingId) {
        Reminder_Setting__c rs = [
            SELECT Id, User__c, User__r.FirstName, User__r.IsActive, User__r.TimeZoneSidKey
            FROM Reminder_Setting__c WHERE Id = :settingId
        ];
        if (rs.User__c == null || rs.User__r.IsActive != true) return;
        Date today = localDate(DateTime.now(), rs.User__r.TimeZoneSidKey);
        try {
            Plan p = buildPlan(rs.User__c, rs.User__r.FirstName, today);
            if (p == null) return;
            deliver(rs.User__c, p);
            rs.Last_Sent_On__c = today;
            rs.Last_Error__c = null;
        } catch (Exception e) {
            rs.Last_Error__c = e.getMessage().abbreviate(255);
            lastError = e.getMessage();
        }
        update rs;
    }

    /** Sends the learner a reminder right now, ignoring cadence. Throws if there is nothing upcoming to remind about. */
    public static void sendTest(Id userId) {
        User u = [SELECT FirstName, TimeZoneSidKey FROM User WHERE Id = :userId];
        Plan p = buildPlan(userId, u.FirstName, localDate(DateTime.now(), u.TimeZoneSidKey));
        if (p == null) throw new ReminderException('Add an upcoming exam first, then try again.');
        deliver(userId, p);
    }

    private static void deliver(Id userId, Plan p) {
        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        m.setTargetObjectId(userId);
        m.setSaveAsActivity(false);
        m.setSenderDisplayName('Cert Study');
        m.setReplyTo(REPLY_TO);
        m.setSubject(p.subject);
        m.setPlainTextBody(textFor(p));
        m.setHtmlBody(htmlFor(p));
        lastBatch = new List<Messaging.SingleEmailMessage>{ m };
        Messaging.SendEmailResult r = Messaging.sendEmail(lastBatch, false)[0];
        if (!r.isSuccess()) throw new ReminderException(r.getErrors()[0].getMessage());
    }

    // ------------------------------------------------------------ render

    public static String htmlFor(Plan p) {
        List<String> h = new List<String>{
            '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#181818;max-width:640px">',
            '<p>Hi ' + esc(String.isBlank(p.firstName) ? 'there' : p.firstName) + ',</p>',
            '<p>A quick nudge to keep studying. Your upcoming exams:</p><ul>'
        };
        for (String line : p.examLines) h.add('<li>' + esc(line) + '</li>');
        h.add('</ul>');
        for (Sample s : p.samples) {
            h.add('<div style="border-left:3px solid #0176d3;padding:6px 12px;margin:14px 0;background:#f3f9ff">');
            h.add('<div style="color:#555;font-size:12px">Try this one: ' + esc(s.certName)
                + (String.isBlank(s.section) ? '' : ' · ' + esc(s.section)) + '</div>');
            h.add('<div style="margin:6px 0;font-weight:bold">' + esc(s.stem) + '</div>');
            for (String o : s.options) h.add('<div>' + esc(o) + '</div>');
            h.add('<div style="color:#888;font-size:11px;margin-top:10px">Answer: ' + esc(s.answer) + '</div>');
            h.add('</div>');
        }
        h.add('<p><a href="' + SITE_URL + '" style="color:#0176d3;font-weight:bold">Practice in Cert Study</a></p>');
        h.add('<p style="color:#888;font-size:12px">You get these because you turned on study reminders. '
            + 'To change how often, or to stop them, open My exams in Cert Study. Reply to this email to reach the team.</p></div>');
        return String.join(h, '\n');
    }

    public static String textFor(Plan p) {
        List<String> t = new List<String>{
            'Hi ' + (String.isBlank(p.firstName) ? 'there' : p.firstName) + ',', '',
            'A quick nudge to keep studying. Your upcoming exams:'
        };
        for (String line : p.examLines) t.add('- ' + line);
        for (Sample s : p.samples) {
            t.add('');
            t.add('Try this one: ' + s.certName + (String.isBlank(s.section) ? '' : ' / ' + s.section));
            t.add(s.stem);
            t.addAll(s.options);
            t.add('(Answer: ' + s.answer + ')');
        }
        t.addAll(new List<String>{
            '', 'Practice in Cert Study: ' + SITE_URL, '',
            'You get these because you turned on study reminders. To change how often, or to stop them, open My exams.'
        });
        return String.join(t, '\n');
    }

    private static String esc(String s) {
        return s == null ? '' : s.escapeHtml4();
    }
}
