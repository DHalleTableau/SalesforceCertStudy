/** Keeps Content_Length__c in sync so Cert__c.Grounding_Chars__c (roll-up) shows which certs can generate. */
trigger CertResourceTrigger on Cert_Resource__c (before insert, before update) {
    for (Cert_Resource__c r : Trigger.new) {
        r.Content_Length__c = String.isBlank(r.Content__c) ? 0 : r.Content__c.trim().length();
    }
}
