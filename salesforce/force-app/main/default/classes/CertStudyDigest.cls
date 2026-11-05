/**
 * Daily admin digest: question issues and contributions still waiting for review,
 * plus certs whose question generation failed in the last day. Sent to every
 * active user with the CertStudy_Admin permission set. No email when there is nothing to report.
 *
 * Schedule once from Anonymous Apex:  CertStudyDigest.scheduleDaily();
 * The job wakes hourly and sends only at SEND_HOUR in SEND_TZ, so the scheduling
 * user's own time zone does not matter and daylight-saving changes are handled.
 * Send one now (for a check):
 *   CertStudyDigest.sendNow();
 */
public without sharing class CertStudyDigest implements Schedulable {
    public static final String JOB_NAME = 'Cert Study daily digest';
    public static final String CRON = '0 0 * * * ?'; // hourly; execute() sends only at SEND_HOUR
    public static final String SEND_TZ = 'America/Los_Angeles';
    public static final Integer SEND_HOUR = 15; // 3pm Pacific
    public static final String ADMIN_PERM_SET = 'CertStudy_Admin';
    public static final Integer SLA_HOURS = 48;
    public static final Integer MAX_ITEMS = 50; // per section; the rest are counted, not listed
    public static final Integer SNIPPET = 300;

    /** Set when the last send failed (for checks from Anonymous Apex). */
    public static String lastError;

    public void execute(SchedulableContext ctx) {
        if (isSendHour(DateTime.now())) sendNow();
    }

    public static Boolean isSendHour(DateTime t) {
        return Integer.valueOf(t.format('H', SEND_TZ)) == SEND_HOUR;
    }

    /** Idempotent: returns the existing job's Id if already scheduled. */
    public static String scheduleDaily() {
        List<CronTrigger> existing = [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME AND NextFireTime != null LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0].Id;
        // System.schedule returns a 15-char Id; normalize to 18 so repeat calls match.
        return String.valueOf((Id) System.schedule(JOB_NAME, CRON, new CertStudyDigest()));
    }

    // ------------------------------------------------------------------ model

    public class Item {
        public Id id;
        public String name;      // QR-000001 / CT-000001
        public String heading;   // issue type, or kind + title
        public String certName;
        public String who;
        public String text;      // comment / details / URL
        public Integer ageHours;
        public Boolean overdue;
    }

    public class Digest {
        public List<Item> issues = new List<Item>();
        public Integer issueTotal = 0;
        public Map<String, Integer> issuesByCert = new Map<String, Integer>();
        public List<Item> contributions = new List<Item>();
        public Integer contributionTotal = 0;
        public List<Item> failures = new List<Item>();
        public Integer overdueTotal = 0;
        public Boolean isEmpty() { return issueTotal == 0 && contributionTotal == 0 && failures.isEmpty(); }
    }

    public static Digest build(DateTime now) {
        Digest d = new Digest();

        d.issueTotal = [SELECT COUNT() FROM Question_Report__c WHERE Status__c = 'New'];
        for (AggregateResult ar : [
            SELECT Cert__r.Name certName, COUNT(Id) n FROM Question_Report__c
            WHERE Status__c = 'New' GROUP BY Cert__r.Name ORDER BY COUNT(Id) DESC
        ]) {
            String c = (String) ar.get('certName');
            d.issuesByCert.put(c == null ? '(no cert)' : c, (Integer) ar.get('n'));
        }
        for (Question_Report__c r : [
            SELECT Id, Name, Issue_Type__c, Comment__c, Reported_At__c, CreatedDate,
                Cert__r.Name, Reporter__r.Name, Question__r.Stem__c
            FROM Question_Report__c WHERE Status__c = 'New'
            ORDER BY CreatedDate ASC LIMIT :MAX_ITEMS
        ]) {
            Item it = item(r.Id, r.Name, r.CreatedDate, now);
            it.heading = r.Issue_Type__c;
            it.certName = r.Cert__r == null ? null : r.Cert__r.Name;
            it.who = r.Reporter__r == null ? null : r.Reporter__r.Name;
            String stem = r.Question__r == null ? '' : 'Question: ' + snip(r.Question__r.Stem__c, 160);
            it.text = String.isBlank(r.Comment__c) ? stem : stem + (stem == '' ? '' : '\n') + 'Comment: ' + snip(r.Comment__c, SNIPPET);
            d.issues.add(it);
        }

        d.contributionTotal = [SELECT COUNT() FROM Contribution__c WHERE Status__c = 'New'];
        for (Contribution__c c : [
            SELECT Id, Name, Kind__c, Title__c, URL__c, Details__c, Submitted_At__c, CreatedDate,
                Cert__r.Name, Submitter__r.Name
            FROM Contribution__c WHERE Status__c = 'New'
            ORDER BY CreatedDate ASC LIMIT :MAX_ITEMS
        ]) {
            Item it = item(c.Id, c.Name, c.CreatedDate, now);
            it.heading = c.Kind__c + (String.isBlank(c.Title__c) ? '' : ': ' + c.Title__c);
            it.certName = c.Cert__r == null ? null : c.Cert__r.Name;
            it.who = c.Submitter__r == null ? null : c.Submitter__r.Name;
            List<String> parts = new List<String>();
            if (!String.isBlank(c.URL__c)) parts.add('Link: ' + c.URL__c);
            if (!String.isBlank(c.Details__c)) parts.add(snip(c.Details__c, SNIPPET));
            it.text = String.join(parts, '\n');
            d.contributions.add(it);
        }

        // Tally overdue across ALL open items, not just the listed ones.
        DateTime slaCutoff = now.addHours(-SLA_HOURS);
        d.overdueTotal =
            [SELECT COUNT() FROM Question_Report__c WHERE Status__c = 'New' AND CreatedDate < :slaCutoff]
            + [SELECT COUNT() FROM Contribution__c WHERE Status__c = 'New' AND CreatedDate < :slaCutoff];

        DateTime dayAgo = now.addHours(-24);
        for (Cert__c c : [
            SELECT Id, Name, Last_Failure_At__c, Last_Generation_Error__c FROM Cert__c
            WHERE Last_Failure_At__c >= :dayAgo ORDER BY Last_Failure_At__c DESC LIMIT :MAX_ITEMS
        ]) {
            Item it = item(c.Id, c.Name, c.Last_Failure_At__c, now);
            it.heading = c.Name;
            it.text = snip(c.Last_Generation_Error__c, SNIPPET);
            it.overdue = false;
            d.failures.add(it);
        }
        return d;
    }

    // ------------------------------------------------------------------ send

    /** Builds and sends the digest. Returns how many emails were accepted (0 when there was nothing to send or sending failed). */
    public static Integer sendNow() {
        Digest d = build(DateTime.now());
        if (d.isEmpty()) return 0;
        List<Id> admins = adminUserIds();
        if (admins.isEmpty()) return 0;

        String subject = subjectFor(d);
        String html = htmlFor(d);
        String text = textFor(d);
        List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
        for (Id u : admins) {
            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setTargetObjectId(u); // internal users: does not count against the daily external email limit
            m.setSaveAsActivity(false);
            m.setSubject(subject);
            m.setHtmlBody(html);
            m.setPlainTextBody(text);
            m.setSenderDisplayName('Cert Study');
            mails.add(m);
        }
        Integer sent = 0;
        try {
            for (Messaging.SendEmailResult r : Messaging.sendEmail(mails, false)) {
                if (r.isSuccess()) sent++;
                else lastError = String.valueOf(r.getErrors()[0].getMessage());
            }
        } catch (EmailException e) {
            // Typically: Setup > Deliverability is not set to "All email".
            lastError = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Cert Study digest not sent: ' + e.getMessage());
            return 0;
        }
        return sent;
    }

    public static List<Id> adminUserIds() {
        List<Id> out = new List<Id>();
        for (PermissionSetAssignment a : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSet.Name = :ADMIN_PERM_SET AND Assignee.IsActive = true
        ]) {
            out.add(a.AssigneeId);
        }
        return out;
    }

    // ------------------------------------------------------------------ render

    public static String subjectFor(Digest d) {
        List<String> parts = new List<String>();
        if (d.issueTotal > 0) parts.add(d.issueTotal + ' question issue' + (d.issueTotal == 1 ? '' : 's'));
        if (d.contributionTotal > 0) parts.add(d.contributionTotal + ' contribution' + (d.contributionTotal == 1 ? '' : 's'));
        if (!d.failures.isEmpty()) parts.add(d.failures.size() + ' generation problem' + (d.failures.size() == 1 ? '' : 's'));
        String s = 'Cert Study daily digest: ' + String.join(parts, ', ');
        if (d.overdueTotal > 0) s += ' (' + d.overdueTotal + ' past ' + SLA_HOURS + 'h)';
        return s;
    }

    public static String htmlFor(Digest d) {
        String base = URL.getOrgDomainUrl().toExternalForm();
        List<String> h = new List<String>();
        h.add('<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#181818;max-width:760px">');
        h.add('<h2 style="color:#0176d3;margin:0 0 4px">Cert Study daily digest</h2>');
        h.add('<p style="color:#555;margin:0 0 16px">Items waiting for review. Our promise: everything is reviewed within '
            + SLA_HOURS + ' hours. Items past that are marked <b style="color:#ba0517">OVERDUE</b>.</p>');

        if (d.issueTotal > 0) {
            h.add(sectionHead('Question issues', d.issueTotal));
            List<String> byCert = new List<String>();
            for (String c : d.issuesByCert.keySet()) byCert.add(esc(c) + ' (' + d.issuesByCert.get(c) + ')');
            h.add('<p style="margin:0 0 8px;color:#555">By cert: ' + String.join(byCert, ' · ') + '</p>');
            h.add(itemsHtml(d.issues, base));
            h.add(moreLine(d.issueTotal, d.issues.size()));
        }
        if (d.contributionTotal > 0) {
            h.add(sectionHead('Contributions and suggestions', d.contributionTotal));
            h.add(itemsHtml(d.contributions, base));
            h.add(moreLine(d.contributionTotal, d.contributions.size()));
        }
        if (!d.failures.isEmpty()) {
            h.add(sectionHead('Question generation problems (last 24 hours)', d.failures.size()));
            h.add('<p style="margin:0 0 8px;color:#555">These certs gave up generating questions after repeated failures; they retry on their own after a cooldown.</p>');
            h.add(itemsHtml(d.failures, base));
        }
        h.add('<p style="color:#888;font-size:12px;margin-top:24px">Sent daily at 3pm Pacific to users with the '
            + ADMIN_PERM_SET + ' permission set, only when there is something to review. '
            + 'Change an item\'s Status to take it off this list.</p></div>');
        return String.join(h, '\n');
    }

    public static String textFor(Digest d) {
        String base = URL.getOrgDomainUrl().toExternalForm();
        List<String> t = new List<String>{ subjectFor(d), '' };
        if (d.issueTotal > 0) {
            t.add('QUESTION ISSUES (' + d.issueTotal + ')');
            t.addAll(itemsText(d.issues, base));
            if (d.issueTotal > d.issues.size()) t.add('...and ' + (d.issueTotal - d.issues.size()) + ' more');
            t.add('');
        }
        if (d.contributionTotal > 0) {
            t.add('CONTRIBUTIONS AND SUGGESTIONS (' + d.contributionTotal + ')');
            t.addAll(itemsText(d.contributions, base));
            if (d.contributionTotal > d.contributions.size()) t.add('...and ' + (d.contributionTotal - d.contributions.size()) + ' more');
            t.add('');
        }
        if (!d.failures.isEmpty()) {
            t.add('QUESTION GENERATION PROBLEMS, LAST 24 HOURS (' + d.failures.size() + ')');
            t.addAll(itemsText(d.failures, base));
        }
        return String.join(t, '\n');
    }

    // ------------------------------------------------------------------ helpers

    private static Item item(Id id, String name, DateTime at, DateTime now) {
        Item it = new Item();
        it.id = id;
        it.name = name;
        it.ageHours = at == null ? 0 : ((now.getTime() - at.getTime()) / 3600000L).intValue();
        it.overdue = it.ageHours >= SLA_HOURS;
        return it;
    }

    @TestVisible
    private static String ageText(Integer hours) {
        if (hours < 1) return 'under 1h old';
        if (hours < 48) return hours + 'h old';
        return (hours / 24) + ' days old';
    }

    private static String sectionHead(String title, Integer n) {
        return '<h3 style="margin:20px 0 6px;border-bottom:1px solid #ddd;padding-bottom:4px">' + esc(title) + ' (' + n + ')</h3>';
    }

    private static String moreLine(Integer total, Integer shown) {
        return total > shown ? '<p style="color:#555">…and ' + (total - shown) + ' more. Open the tab in Salesforce to see them all.</p>' : '';
    }

    private static String itemsHtml(List<Item> items, String base) {
        List<String> h = new List<String>{ '<table style="border-collapse:collapse;width:100%">' };
        for (Item it : items) {
            String flag = it.overdue ? ' <b style="color:#ba0517">OVERDUE</b>' : '';
            String meta = String.join(nonBlank(new List<String>{ it.certName, it.who == null ? null : 'from ' + it.who, ageText(it.ageHours) }), ' · ');
            h.add('<tr><td style="padding:6px 0;border-bottom:1px solid #f0f0f0;vertical-align:top">'
                + '<a href="' + base + '/' + it.id + '" style="color:#0176d3;font-weight:bold">' + esc(it.name) + '</a> '
                + esc(it.name == it.heading ? '' : it.heading) + flag
                + '<div style="color:#555;font-size:12px">' + esc(meta) + '</div>'
                + (String.isBlank(it.text) ? '' : '<div style="white-space:pre-wrap;margin-top:2px">' + esc(it.text) + '</div>')
                + '</td></tr>');
        }
        h.add('</table>');
        return String.join(h, '\n');
    }

    private static List<String> itemsText(List<Item> items, String base) {
        List<String> t = new List<String>();
        for (Item it : items) {
            String meta = String.join(nonBlank(new List<String>{ it.certName, it.who == null ? null : 'from ' + it.who, ageText(it.ageHours) }), ' · ');
            t.add('- ' + it.name + (it.name == it.heading ? '' : ' ' + it.heading) + (it.overdue ? ' [OVERDUE]' : '') + ' (' + meta + ')');
            if (!String.isBlank(it.text)) t.add('  ' + it.text.replace('\n', '\n  '));
            t.add('  ' + base + '/' + it.id);
        }
        return t;
    }

    private static List<String> nonBlank(List<String> xs) {
        List<String> out = new List<String>();
        for (String x : xs) if (!String.isBlank(x)) out.add(x);
        return out;
    }

    private static String snip(String s, Integer n) {
        return s == null ? '' : s.normalizeSpace().abbreviate(n);
    }

    private static String esc(String s) {
        return s == null ? '' : s.escapeHtml4();
    }
}
