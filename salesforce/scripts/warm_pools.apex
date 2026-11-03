// Warm up question pools for certs that have none (or fewer than POOL_SIZE).
//
// How it works: pools only top up for certs listed on an ACTIVE session, so this
// creates throwaway "system-warmup" sessions that list those certs and starts the
// top-up. The hourly scheduler keeps filling them, then ends the sessions after
// 24h idle (CertStudyScheduler.IDLE_HOURS), so it cleans itself up.
// Cost: up to POOL_SIZE (5) model calls per cert warmed, ~6-10s each.
//
// Run from the salesforce/ folder:
//   sf apex run --file scripts/warm_pools.apex --target-org certstudy
// Change MAX_CERTS to warm more or fewer certs per run. Safe to rerun: certs that
// already have a full pool are skipped.
Integer MAX_CERTS = 20;
String WARMUP_KEY = 'system-warmup';

Map<Id, Integer> ready = new Map<Id, Integer>();
for (AggregateResult ar : [
    SELECT Cert__c c, COUNT(Id) n FROM Question__c
    WHERE Status__c = 'Ready' AND Study_Session__c = null GROUP BY Cert__c
]) {
    ready.put((Id) ar.get('c'), (Integer) ar.get('n'));
}

List<Cert__c> todo = new List<Cert__c>();
for (Cert__c c : [
    SELECT Id, Name, Cert_Code__c FROM Cert__c
    WHERE Is_Aggregate__c = false AND Grounding_Chars__c > 0
    ORDER BY Name
]) {
    if (todo.size() >= MAX_CERTS) break;
    Integer have = ready.containsKey(c.Id) ? ready.get(c.Id) : 0;
    if (have < CertStudyGenerator.POOL_SIZE) todo.add(c);
}

// A session's Cert_Codes__c holds ';id;id;' in 255 chars, so ~13 certs per session.
List<Study_Session__c> sessions = new List<Study_Session__c>();
Set<String> codes = new Set<String>();
String delimited = ';';
for (Cert__c c : todo) {
    String piece = String.valueOf(c.Id) + ';';
    if (delimited.length() + piece.length() > 250) {
        sessions.add(new Study_Session__c(Cert_Codes__c = delimited));
        delimited = ';';
    }
    delimited += piece;
    codes.add(c.Cert_Code__c);
}
if (delimited.length() > 1) sessions.add(new Study_Session__c(Cert_Codes__c = delimited));

for (Study_Session__c s : sessions) {
    s.User_Key__c = WARMUP_KEY;
    s.Mode__c = CertStudyService.MODE_PRACTICE;
    s.Status__c = CertStudyService.ACTIVE;
    s.Started_At__c = DateTime.now();
    s.Last_Activity__c = DateTime.now();
}
insert sessions;
CertStudyPoolJob.requestTopUp(codes);

System.debug('Warming ' + todo.size() + ' cert(s) via ' + sessions.size() + ' warm-up session(s):');
for (Cert__c c : todo) System.debug('  ' + c.Name);
System.debug('Top-ups continue in the background and hourly via the scheduler.');
