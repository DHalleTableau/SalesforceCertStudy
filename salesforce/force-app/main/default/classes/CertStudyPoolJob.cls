/**
 * Background top-up for one cert's shared question pool (port of
 * worker.py's top_up_cert_pool). Generation never happens in a user's
 * request: actions only claim Ready rows and call requestTopUp().
 *
 * One model call per job (callout time limits), chaining itself until the
 * pool holds POOL_SIZE unclaimed Ready rows or no active session needs the
 * cert. Cert__c.Top_Up_Started_At__c is the per-cert lock (replaces the
 * Postgres advisory lock); a lock older than LOCK_STALE_MINUTES is treated
 * as abandoned. The hourly CertStudyScheduler restarts any stalled chain.
 */
public without sharing class CertStudyPoolJob implements Queueable, Database.AllowsCallouts {
    public static final Integer MAX_ATTEMPTS = 5;
    public static final Integer LOCK_STALE_MINUTES = 15;

    private Id certId;
    private Integer attempt = 0;
    private CertStudyGenerator.GeneratedQuestion fallback;
    private Decimal fallbackRatio;

    public CertStudyPoolJob(Id certId) {
        this.certId = certId;
    }

    /** Start a job chain for each cert that has content, needs questions, and is not already locked. */
    public static void requestTopUp(Set<String> certCodes) {
        if (certCodes == null || certCodes.isEmpty()) return;
        DateTime staleBefore = DateTime.now().addMinutes(-LOCK_STALE_MINUTES);

        Map<Id, Integer> readyByCert = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Cert__c certId, COUNT(Id) n
            FROM Question__c
            WHERE Status__c = 'Ready' AND Study_Session__c = null AND Cert__r.Cert_Code__c IN :certCodes
            GROUP BY Cert__c
        ]) {
            readyByCert.put((Id) ar.get('certId'), (Integer) ar.get('n'));
        }

        List<Cert__c> toStart = new List<Cert__c>();
        for (Cert__c c : [
            SELECT Id, Top_Up_Started_At__c, Is_Aggregate__c, Grounding_Chars__c
            FROM Cert__c
            WHERE Cert_Code__c IN :certCodes
            FOR UPDATE
        ]) {
            if (c.Grounding_Chars__c == null || c.Grounding_Chars__c == 0) continue;
            if (c.Top_Up_Started_At__c != null && c.Top_Up_Started_At__c > staleBefore) continue;
            Integer ready = readyByCert.containsKey(c.Id) ? readyByCert.get(c.Id) : 0;
            if (ready >= CertStudyGenerator.POOL_SIZE) continue;
            if (Limits.getQueueableJobs() + toStart.size() >= Limits.getLimitQueueableJobs()) break;
            c.Top_Up_Started_At__c = DateTime.now();
            toStart.add(c);
        }
        if (toStart.isEmpty()) return;
        update toStart;
        for (Cert__c c : toStart) {
            System.enqueueJob(new CertStudyPoolJob(c.Id));
        }
    }

    public void execute(QueueableContext ctx) {
        Cert__c cert = [
            SELECT Id, Name, Cert_Code__c, Domains_JSON__c, Overview_Derived_At__c,
                Duration_Min__c, Num_Questions__c, Passing_Score__c, Last_Generation_Error__c
            FROM Cert__c
            WHERE Id = :certId
        ];
        Boolean chain = false;
        try {
            chain = runOnce(cert);
        } catch (Exception e) {
            cert.Last_Generation_Error__c = (DateTime.now().format() + ' ' + e.getTypeName() + ': ' + e.getMessage()).abbreviate(32000);
            chain = false;
        }
        cert.Top_Up_Started_At__c = chain ? DateTime.now() : null;
        update cert;

        if (chain && !Test.isRunningTest()) {
            CertStudyPoolJob next = new CertStudyPoolJob(certId);
            next.attempt = attempt;
            next.fallback = fallback;
            next.fallbackRatio = fallbackRatio;
            System.enqueueJob(next);
        }
    }

    /** One unit of work. Returns true if another job should follow. All callouts happen before any DML. */
    @TestVisible
    private Boolean runOnce(Cert__c cert) {
        if (!CertStudyService.isCertNeeded(cert.Cert_Code__c)) return false;

        String grounding = CertStudyGenerator.assembleGrounding(cert.Id, CertStudyGenerator.MAX_GROUNDING_CHARS);
        if (String.isBlank(grounding)) {
            cert.Last_Generation_Error__c = 'No resource content for this cert -- add Cert Resource text.';
            return false;
        }

        // First use: derive duration / question count / passing score / domains, once.
        if (cert.Overview_Derived_At__c == null) {
            String raw = CertStudyLlm.get().generate(CertStudyGenerator.buildOverviewPrompt(cert.Name, grounding));
            if (!CertStudyGenerator.applyOverview(raw, cert)) {
                cert.Last_Generation_Error__c = 'Could not parse cert overview; generating without domain rotation.';
            }
            cert.Overview_Derived_At__c = DateTime.now();
            return true;
        }

        Integer ready = [
            SELECT COUNT() FROM Question__c
            WHERE Cert__c = :cert.Id AND Status__c = 'Ready' AND Study_Session__c = null
        ];
        if (ready >= CertStudyGenerator.POOL_SIZE) return false;

        Integer total = [SELECT COUNT() FROM Question__c WHERE Cert__c = :cert.Id];
        Integer difficulty = CertStudyGenerator.nextDifficulty(total);
        String format = CertStudyGenerator.nextFormat(total);
        String style = CertStudyGenerator.nextStyle(total);
        String domain = CertStudyGenerator.nextDomain(cert, total);

        List<String> avoidStems = new List<String>();
        Integer avoidLimit = CertStudyGenerator.AVOID_STEMS_LIMIT;
        for (Question__c q : [
            SELECT Stem__c FROM Question__c WHERE Cert__c = :cert.Id
            ORDER BY CreatedDate DESC LIMIT :avoidLimit
        ]) {
            if (String.isNotBlank(q.Stem__c)) avoidStems.add(q.Stem__c);
        }

        String prompt = CertStudyGenerator.buildQuestionPrompt(
            cert.Name, domain, difficulty, format, style, grounding, avoidStems
        );

        CertStudyGenerator.GeneratedQuestion candidate = null;
        String reason;
        try {
            String raw = CertStudyLlm.get().generate(prompt);
            candidate = CertStudyGenerator.parseQuestion(raw, format, difficulty, domain, style);
            reason = CertStudyGenerator.validityReason(candidate);
        } catch (Exception e) {
            reason = 'model call failed: ' + e.getMessage();
        }

        CertStudyGenerator.GeneratedQuestion toInsert = null;
        if (reason == null) {
            toInsert = candidate;
        } else {
            attempt++;
            cert.Last_Generation_Error__c = (DateTime.now().format() + ' attempt ' + attempt + '/' + MAX_ATTEMPTS + ' rejected: ' + reason).abbreviate(32000);
            // Only "structurally fine but length-biased" is safe as a fallback.
            if (candidate != null && CertStudyGenerator.structuralReason(candidate) == null) {
                Decimal ratio = CertStudyGenerator.lengthBiasRatio(candidate);
                if (ratio != null && (fallback == null || ratio < fallbackRatio)) {
                    fallback = candidate;
                    fallbackRatio = ratio;
                }
            }
            if (attempt >= MAX_ATTEMPTS) {
                if (fallback == null) {
                    attempt = 0;
                    return false; // give up this cycle; next claim or the scheduler retries
                }
                toInsert = fallback;
            }
        }

        if (toInsert == null) return true; // retry the same slot

        insert CertStudyGenerator.toRecord(toInsert, cert.Id);
        if (reason == null) cert.Last_Generation_Error__c = null;
        attempt = 0;
        fallback = null;
        fallbackRatio = null;
        return ready + 1 < CertStudyGenerator.POOL_SIZE;
    }
}
