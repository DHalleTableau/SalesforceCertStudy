/** A decision (Fixed/Dismissed) stamps Reply_Sent_At__c before update; the email goes out after update. */
trigger QuestionReportTrigger on Question_Report__c (before update, after update) {
    if (Trigger.isBefore) {
        CertStudyReplies.stampDecisions(Trigger.new, Trigger.oldMap);
    } else {
        CertStudyReplies.sendStamped(Trigger.new, Trigger.oldMap);
    }
}
