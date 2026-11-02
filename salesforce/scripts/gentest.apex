// Starts a generation test on a cert that has study material but no questions yet.
Set<Id> withQ = new Set<Id>();
for (AggregateResult ar : [SELECT Cert__c c FROM Question__c GROUP BY Cert__c]) withQ.add((Id) ar.get('c'));
Cert__c c = [SELECT Name, Cert_Code__c FROM Cert__c WHERE Id NOT IN :withQ AND Grounding_Chars__c > 0 AND Is_Aggregate__c = false LIMIT 1];
System.debug('CERT>> ' + c.Name);
System.debug('START>> ' + CertStudyService.startSession('gentest@example.com', c.Cert_Code__c, c.Cert_Code__c + '=no'));
