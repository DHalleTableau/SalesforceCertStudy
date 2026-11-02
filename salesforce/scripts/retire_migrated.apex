// Retires questions imported from Heroku (Legacy_Id__c set) that are still unused.
// Most predate option shuffling (correct answer is "A" 257/301 times) and the
// short-option rule (correct option usually the longest). Reversible: they are
// marked Retired, not deleted. To undo: set Status__c back to 'Ready'.
List<Question__c> old = [
    SELECT Id FROM Question__c
    WHERE Legacy_Id__c != null AND Status__c = 'Ready' AND Study_Session__c = null
];
for (Question__c q : old) q.Status__c = 'Retired';
update old;
// Also return any migrated question currently sitting unanswered in a session.
List<Question__c> served = [
    SELECT Id FROM Question__c WHERE Legacy_Id__c != null AND Status__c = 'Served'
];
for (Question__c q : served) { q.Status__c = 'Retired'; q.Study_Session__c = null; }
update served;
System.debug('RETIRED>> ' + (old.size() + served.size()));
