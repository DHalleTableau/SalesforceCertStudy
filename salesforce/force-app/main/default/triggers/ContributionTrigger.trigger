/**
 * Before update: approving a study resource creates a Cert Resource from it (once) and links it;
 * a decision (Approved/Rejected) stamps Reply_Sent_At__c. After update: sends the decision email.
 */
trigger ContributionTrigger on Contribution__c (before update, after update) {
    if (Trigger.isBefore) {
        CertStudyService.onContributionsApproved(Trigger.new, Trigger.oldMap);
        CertStudyReplies.stampDecisions(Trigger.new, Trigger.oldMap);
    } else {
        CertStudyReplies.sendStamped(Trigger.new, Trigger.oldMap);
    }
}
