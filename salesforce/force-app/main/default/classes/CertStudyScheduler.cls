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

    public static String scheduleHourly() {
        return System.schedule('Cert Study maintenance', '0 0 * * * ?', new CertStudyScheduler());
    }
}
