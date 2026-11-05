/**
 * Automatic decision emails to the learner who reported a question issue or sent a contribution.
 *
 * Question issue -> Fixed or Dismissed; Contribution -> Approved or Rejected.
 * Before update stamps Reply_Sent_At__c (only if it is still empty, so each item gets
 * at most one reply); after update sends an email for every row stamped in that update.
 * Note to Learner (optional) is included in the email; Reviewer Notes stay internal.
 * A failed send never blocks the admin's save.
 */
public without sharing class CertStudyReplies {
    public static final String SITE_URL = 'https://trailsignup-5d9fea1e5cdf7f.my.site.com/sfcertstudy';
    public static final String REPLY_TO = 'daniel.halle@salesforce.com';
    public static final Set<String> ISSUE_DECISIONS = new Set<String>{ 'Fixed', 'Dismissed' };
    public static final Set<String> CONTRIBUTION_DECISIONS = new Set<String>{ 'Approved', 'Rejected' };

    /** Set when the last send failed (for checks and tests). */
    public static String lastError;
    /** Emails built in the last send (for tests). */
    @TestVisible private static List<Messaging.SingleEmailMessage> lastBatch = new List<Messaging.SingleEmailMessage>();

    // ------------------------------------------------------------ trigger hooks

    public static void stampDecisions(List<SObject> rows, Map<Id, SObject> oldMap) {
        DateTime now = DateTime.now();
        for (SObject r : rows) {
            String status = (String) r.get('Status__c');
            String oldStatus = (String) oldMap.get(r.Id).get('Status__c');
            if (status == oldStatus || r.get('Reply_Sent_At__c') != null) continue;
            if (decisionsFor(r).contains(status)) r.put('Reply_Sent_At__c', now);
        }
    }

    public static void sendStamped(List<SObject> rows, Map<Id, SObject> oldMap) {
        Set<Id> ids = new Set<Id>();
        for (SObject r : rows) {
            if (r.get('Reply_Sent_At__c') != null && oldMap.get(r.Id).get('Reply_Sent_At__c') == null) ids.add(r.Id);
        }
        if (ids.isEmpty()) return;
        try {
            List<Messaging.SingleEmailMessage> mails = rows[0] instanceof Question_Report__c
                ? issueEmails(ids) : contributionEmails(ids);
            send(mails);
        } catch (Exception e) {
            lastError = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Cert Study reply not sent: ' + e.getMessage());
        }
    }

    private static Set<String> decisionsFor(SObject r) {
        return r instanceof Question_Report__c ? ISSUE_DECISIONS : CONTRIBUTION_DECISIONS;
    }

    // ------------------------------------------------------------ build

    private static List<Messaging.SingleEmailMessage> issueEmails(Set<Id> ids) {
        List<Messaging.SingleEmailMessage> out = new List<Messaging.SingleEmailMessage>();
        for (Question_Report__c r : [
            SELECT Id, Name, Status__c, Issue_Type__c, Note_To_Learner__c, Reporter__c, Reporter__r.FirstName,
                Reporter__r.IsActive, Cert__r.Name, Question__r.Stem__c
            FROM Question_Report__c WHERE Id IN :ids
        ]) {
            if (r.Reporter__c == null || !r.Reporter__r.IsActive) continue;
            String cert = r.Cert__r == null ? 'a certification' : r.Cert__r.Name;
            String outcome = r.Status__c == 'Fixed'
                ? 'We reviewed it and made a fix. Thank you: reports like yours are how the questions get better.'
                : 'We reviewed it and decided not to make a change this time. Thank you for flagging it all the same.';
            List<String> details = new List<String>{ 'Your report: ' + r.Issue_Type__c };
            if (r.Question__r != null && !String.isBlank(r.Question__r.Stem__c)) {
                details.add('Question: ' + r.Question__r.Stem__c.normalizeSpace().abbreviate(300));
            }
            out.add(mail(
                r.Reporter__c,
                'Your Cert Study question report (' + r.Name + '): ' + r.Status__c.toLowerCase(),
                r.Reporter__r.FirstName,
                'Thanks for reporting a problem with a ' + cert + ' practice question.',
                outcome, details, r.Note_To_Learner__c
            ));
        }
        return out;
    }

    private static List<Messaging.SingleEmailMessage> contributionEmails(Set<Id> ids) {
        List<Messaging.SingleEmailMessage> out = new List<Messaging.SingleEmailMessage>();
        for (Contribution__c c : [
            SELECT Id, Name, Kind__c, Status__c, Title__c, URL__c, Note_To_Learner__c, Submitter__c,
                Submitter__r.FirstName, Submitter__r.IsActive, Cert__r.Name
            FROM Contribution__c WHERE Id IN :ids
        ]) {
            if (c.Submitter__c == null || !c.Submitter__r.IsActive) continue;
            Boolean isResource = c.Kind__c == 'Study resource';
            Boolean approved = c.Status__c == 'Approved';
            String cert = c.Cert__r == null ? null : c.Cert__r.Name;
            String intro = isResource
                ? 'Thanks for sharing a study resource' + (cert == null ? '' : ' for ' + cert) + '.'
                : 'Thanks for your suggestion for Cert Study.';
            String outcome;
            if (isResource) {
                outcome = approved
                    ? 'We approved it. It is now part of the material new ' + (cert == null ? '' : cert + ' ') + 'practice questions are written from.'
                    : 'We reviewed it and decided not to add it this time.';
            } else {
                outcome = approved
                    ? 'We liked it and have added it to our plans. Keep an eye on "What\'s new" in the app.'
                    : 'We reviewed it and decided not to take it forward for now.';
            }
            List<String> details = new List<String>();
            if (!String.isBlank(c.Title__c)) details.add('You sent: ' + c.Title__c.abbreviate(200));
            if (!String.isBlank(c.URL__c)) details.add('Link: ' + c.URL__c);
            out.add(mail(
                c.Submitter__c,
                'Your Cert Study ' + (isResource ? 'study resource' : 'suggestion') + ' (' + c.Name + '): ' + c.Status__c.toLowerCase(),
                c.Submitter__r.FirstName, intro, outcome, details, c.Note_To_Learner__c
            ));
        }
        return out;
    }

    @TestVisible
    private static Messaging.SingleEmailMessage mail(Id userId, String subject, String firstName, String intro,
            String outcome, List<String> details, String notes) {
        String hello = 'Hi ' + (String.isBlank(firstName) ? 'there' : firstName) + ',';
        String noteText = String.isBlank(notes) ? null : notes.trim().abbreviate(2000);

        List<String> t = new List<String>{ hello, '', intro + ' ' + outcome };
        if (noteText != null) t.addAll(new List<String>{ '', 'Note from the reviewer:', noteText });
        if (!details.isEmpty()) { t.add(''); t.addAll(details); }
        t.addAll(new List<String>{ '', 'Keep studying: ' + SITE_URL, '', 'Cert Study', '(Reply to this email to reach the Cert Study team.)' });

        List<String> h = new List<String>{
            '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#181818;max-width:640px">',
            '<p>' + esc(hello) + '</p>',
            '<p>' + esc(intro) + ' ' + esc(outcome) + '</p>'
        };
        if (noteText != null) {
            h.add('<div style="border-left:3px solid #0176d3;padding:4px 12px;margin:12px 0;background:#f3f9ff">'
                + '<div style="font-weight:bold;margin-bottom:4px">Note from the reviewer</div>'
                + '<div style="white-space:pre-wrap">' + esc(noteText) + '</div></div>');
        }
        if (!details.isEmpty()) {
            List<String> lines = new List<String>();
            for (String d : details) lines.add(esc(d));
            h.add('<p style="color:#555;font-size:13px">' + String.join(lines, '<br>') + '</p>');
        }
        h.add('<p><a href="' + SITE_URL + '" style="color:#0176d3;font-weight:bold">Keep studying in Cert Study</a></p>');
        h.add('<p style="color:#888;font-size:12px">Reply to this email to reach the Cert Study team.</p></div>');

        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        m.setTargetObjectId(userId);
        m.setSaveAsActivity(false);
        m.setSenderDisplayName('Cert Study');
        m.setReplyTo(REPLY_TO);
        m.setSubject(subject);
        m.setPlainTextBody(String.join(t, '\n'));
        m.setHtmlBody(String.join(h, '\n'));
        return m;
    }

    private static void send(List<Messaging.SingleEmailMessage> mails) {
        lastBatch = mails;
        if (mails.isEmpty()) return;
        for (Messaging.SendEmailResult r : Messaging.sendEmail(mails, false)) {
            if (!r.isSuccess()) lastError = r.getErrors()[0].getMessage();
        }
    }

    private static String esc(String s) {
        return s == null ? '' : s.escapeHtml4();
    }
}
