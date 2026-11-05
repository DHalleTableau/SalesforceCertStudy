// Schedules the digest job (idempotent). It wakes hourly and only sends at 3pm Pacific.
String jobId = CertStudyDigest.scheduleDaily();
CronTrigger ct = [SELECT NextFireTime FROM CronTrigger WHERE Id = :jobId];
System.debug(LoggingLevel.ERROR, 'DIGEST job=' + jobId + ' next check=' + ct.NextFireTime.format('yyyy-MM-dd HH:mm z', 'America/Los_Angeles'));
