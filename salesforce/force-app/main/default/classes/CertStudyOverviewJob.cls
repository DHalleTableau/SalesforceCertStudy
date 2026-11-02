/**
 * Re-derives a cert's exam overview (question count, duration, pass mark,
 * weighted sections) from its study material. Used to repair overviews where
 * the model listed sub-objectives as sections (e.g. 28 sections at 3.57%).
 *
 * One model call per job, no chaining (Trial orgs cap chain depth), so
 * rederiveSuspect() enqueues one independent job per affected cert.
 *
 * Run from Anonymous Apex:  CertStudyOverviewJob.rederiveSuspect();
 */
public without sharing class CertStudyOverviewJob implements Queueable, Database.AllowsCallouts {
    private Id certId;

    public CertStudyOverviewJob(Id certId) {
        this.certId = certId;
    }

    /**
     * True when a derived overview looks like a list of objectives rather than
     * the exam's sections. Equal or missing weights alone are acceptable (the
     * material may simply not state them); too many sections is not.
     */
    public static Boolean looksWrong(Cert__c c) {
        return CertStudyGenerator.domains(c).size() > 10;
    }

    public static Integer rederiveSuspect() {
        List<Cert__c> toFix = new List<Cert__c>();
        for (Cert__c c : [
            SELECT Id, Domains_JSON__c FROM Cert__c
            WHERE Overview_Derived_At__c != null AND Grounding_Chars__c > 0
        ]) {
            if (looksWrong(c)) toFix.add(c);
        }
        Integer started = 0;
        for (Cert__c c : toFix) {
            if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) break;
            System.enqueueJob(new CertStudyOverviewJob(c.Id));
            started++;
        }
        return started;
    }

    public void execute(QueueableContext ctx) {
        Cert__c cert = [
            SELECT Id, Name, Domains_JSON__c, Duration_Min__c, Num_Questions__c, Passing_Score__c, Last_Generation_Error__c
            FROM Cert__c WHERE Id = :certId
        ];
        String grounding = CertStudyGenerator.overviewGrounding(cert.Id, CertStudyGenerator.MAX_GROUNDING_CHARS);
        if (String.isBlank(grounding)) return;
        Cert__c updated = new Cert__c(Id = cert.Id, Overview_Derived_At__c = DateTime.now());
        try {
            String raw = CertStudyLlm.get().generate(CertStudyGenerator.buildOverviewPrompt(cert.Name, grounding));
            Cert__c candidate = new Cert__c(Id = cert.Id);
            if (CertStudyGenerator.applyOverview(raw, candidate) && candidate.Domains_JSON__c != null && !looksWrong(candidate)) {
                updated.Duration_Min__c = candidate.Duration_Min__c;
                updated.Num_Questions__c = candidate.Num_Questions__c;
                updated.Passing_Score__c = candidate.Passing_Score__c;
                updated.Domains_JSON__c = candidate.Domains_JSON__c;
                updated.Last_Generation_Error__c = null;
            } else {
                updated.Last_Generation_Error__c = 'Overview re-derive did not produce clean weighted sections; previous overview kept.';
            }
        } catch (Exception e) {
            updated.Last_Generation_Error__c = ('Overview re-derive failed: ' + e.getMessage()).abbreviate(32000);
        }
        update updated;
    }
}
