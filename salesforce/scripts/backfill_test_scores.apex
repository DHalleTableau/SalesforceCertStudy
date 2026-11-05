// One-off: store Score_Pct__c / Passed__c on tests finished before these fields existed.
List<Study_Session__c> upd = new List<Study_Session__c>();
for (Study_Session__c s : [
    SELECT Id, Mode__c, Status__c, User_Key__c, User__c, Cert_Codes__c, Question_Target__c, Time_Limit_Min__c,
        Timer_Mode__c, Elapsed_Seconds__c, Resumed_At__c, Paused__c, Started_At__c, Completed_At__c, Last_Activity__c
    FROM Study_Session__c
    WHERE Mode__c = 'Test' AND Completed_At__c != null AND Score_Pct__c = null
    LIMIT 10
]) {
    CertStudyService.TestResult r = CertStudyService.testResult(s);
    upd.add(new Study_Session__c(Id = s.Id, Score_Pct__c = r.officialPct, Passed__c = r.passed));
}
update upd;
System.debug(LoggingLevel.ERROR, 'BACKFILL updated=' + upd.size() + ' (re-run until 0)');
