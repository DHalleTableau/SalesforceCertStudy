/** When an admin approves a study resource, create a Cert Resource from it (once) and link it back. */
trigger ContributionTrigger on Contribution__c (before update) {
    CertStudyService.onContributionsApproved(Trigger.new, Trigger.oldMap);
}
