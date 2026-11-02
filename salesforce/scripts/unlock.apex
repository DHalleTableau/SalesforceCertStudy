// Clears stuck generation locks and restarts top-ups for active sessions.
List<Cert__c> locked = [SELECT Id FROM Cert__c WHERE Top_Up_Started_At__c != null];
for (Cert__c c : locked) c.Top_Up_Started_At__c = null;
update locked;
CertStudyScheduler.run();
System.debug('UNLOCKED>> ' + locked.size());
