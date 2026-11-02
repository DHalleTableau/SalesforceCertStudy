/**
 * Hourly maintenance: ends sessions idle for 24h (returning their unanswered
 * questions to the pool) and restarts any stalled pool top-up chains.
 *
 * Schedule once from Anonymous Apex:  CertStudyScheduler.scheduleHourly();
 */
public without sharing class CertStudyScheduler implements Schedulable {
    public static final Integer IDLE_HOURS = 24;

    public void execute(SchedulableContext ctx) {
        run();
    }

    public static void run() {
        DateTime cutoff = DateTime.now().addHours(-IDLE_HOURS);
        CertStudyService.endSessions([
            SELECT Id FROM Study_Session__c
            WHERE Status__c = 'Active' AND (Last_Activity__c < :cutoff OR Last_Activity__c = null)
        ]);
        CertStudyPoolJob.requestTopUp(CertStudyService.activeCertCodes());
    }

    public static final String JOB_NAME = 'Cert Study maintenance';

    /** Idempotent: returns the existing job's Id if already scheduled. */
    public static String scheduleHourly() {
        List<CronTrigger> existing = [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME AND NextFireTime != null LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0].Id;
        return System.schedule(JOB_NAME, '0 0 * * * ?', new CertStudyScheduler());
    }
}
