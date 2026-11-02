/**
 * Runs as the user set in PlatformEventSubscriberConfig (an internal admin /
 * integration user), so learners -- including Experience Cloud users who cannot
 * call the Models API -- never generate questions themselves.
 * Running user: see platformEventSubscriberConfigs/CertStudyTopUpConfig.
 * (Redeploy this trigger after changing that config so the subscription restarts.)
 */
trigger CertStudyTopUpTrigger on Cert_Study_TopUp__e(after insert) {
    Set<String> codes = new Set<String>();
    for (Cert_Study_TopUp__e e : Trigger.new) {
        if (String.isBlank(e.Cert_Codes__c)) continue;
        for (String c : e.Cert_Codes__c.split(';')) {
            if (String.isNotBlank(c)) codes.add(c.trim());
        }
    }
    CertStudyPoolJob.requestTopUp(codes);
}
