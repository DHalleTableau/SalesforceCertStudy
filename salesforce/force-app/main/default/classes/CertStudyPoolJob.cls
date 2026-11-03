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
    /**
     * Trial/Developer Edition orgs cap chained Queueables at depth 5. Each
     * chain is started with this explicit max; at the cap the job stops
     * cleanly and schedules a one-off CertStudyScheduler run ~1 minute out,
     * which starts a fresh chain.
     */
    public static final Integer MAX_CHAIN_DEPTH = 5;
    public static final String RESTART_JOB_PREFIX = 'Cert Study restart ';
    /**
     * Top-up chains allowed to run at once, org-wide. A burst of parallel model
     * calls (e.g. a learner picking a dozen cold certs) made the Models API fail
     * for every cert at once; finished chains start the next waiting cert instead.
     */
    @TestVisible
    private static Integer maxConcurrent = 3;
    /** A cert that gave up after repeated failures is not retried for this long. */
    public static final Integer FAILURE_COOLDOWN_MIN = 10;
    /** A failed model call is retried by a delayed job, not immediately. */
    public static final Integer RETRY_DELAY_MIN = 1;

    @TestVisible
    private static Boolean forceAtMaxDepth = false;

    private Id certId;
    private Integer attempt = 0;
    private CertStudyGenerator.GeneratedQuestion fallback;
    private Decimal fallbackRatio;
    private Boolean modelFailed = false; // this run's model call failed (retry later, don't hammer)

    public CertStudyPoolJob(Id certId) {
        this.certId = certId;
    }

    /** Test hook: exercise the platform-event path instead of the direct call. */
    @TestVisible
    private static Boolean useEventInTest = false;

    /**
     * Learner-facing entry point: publishes Cert_Study_TopUp__e so generation runs
     * as the event subscriber's user, not the learner. Falls back to a direct call
     * if publishing fails, and in tests unless useEventInTest is set.
     */
    public static void requestTopUpAsync(Set<String> certCodes) {
        if (certCodes == null || certCodes.isEmpty()) return;
        if (Test.isRunningTest() && !useEventInTest) {
            requestTopUp(certCodes);
            return;
        }
        String joined = String.join(new List<String>(certCodes), ';');
        if (joined.length() > 255) {
            requestTopUp(certCodes);
            return;
        }
        Database.SaveResult sr = EventBus.publish(new Cert_Study_TopUp__e(Cert_Codes__c = joined));
        if (!sr.isSuccess()) requestTopUp(certCodes);
    }

    /** Start a job chain for each cert that has content, needs questions, and is not already locked. */
    public static void requestTopUp(Set<String> certCodes) {
        if (certCodes == null || certCodes.isEmpty()) return;
        DateTime staleBefore = DateTime.now().addMinutes(-LOCK_STALE_MINUTES);
        DateTime cooldownBefore = DateTime.now().addMinutes(-FAILURE_COOLDOWN_MIN);

        // Concurrency cap: only start chains while fewer than maxConcurrent are running.
        Integer running = [SELECT COUNT() FROM Cert__c WHERE Top_Up_Started_At__c > :staleBefore];
        Integer slots = maxConcurrent - running;
        if (slots <= 0) return;

        Map<Id, Integer> readyByCert = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Cert__c certId, COUNT(Id) n
            FROM Question__c
            WHERE Status__c = 'Ready' AND Study_Session__c = null AND Cert__r.Cert_Code__c IN :certCodes
            GROUP BY Cert__c
        ]) {
            readyByCert.put((Id) ar.get('certId'), (Integer) ar.get('n'));
        }

        // Cheap unlocked pre-check first, so a learner's turn never waits on a
        // row lock held by a running generation job for the same cert.
        Set<Id> candidates = new Set<Id>();
        for (Cert__c c : [
            SELECT Id, Top_Up_Started_At__c, Grounding_Chars__c, Last_Failure_At__c
            FROM Cert__c
            WHERE Cert_Code__c IN :certCodes
        ]) {
            if (c.Grounding_Chars__c == null || c.Grounding_Chars__c == 0) continue;
            if (c.Top_Up_Started_At__c != null && c.Top_Up_Started_At__c > staleBefore) continue;
            if (c.Last_Failure_At__c != null && c.Last_Failure_At__c > cooldownBefore) continue;
            Integer ready = readyByCert.containsKey(c.Id) ? readyByCert.get(c.Id) : 0;
            if (ready >= CertStudyService.poolTarget(c.Id)) continue;
            candidates.add(c.Id);
        }
        if (candidates.isEmpty()) return;

        List<Cert__c> toStart = new List<Cert__c>();
        for (Cert__c c : [
            SELECT Id, Top_Up_Started_At__c, Is_Aggregate__c, Grounding_Chars__c
            FROM Cert__c
            WHERE Id IN :candidates
            FOR UPDATE
        ]) {
            if (c.Grounding_Chars__c == null || c.Grounding_Chars__c == 0) continue;
            if (c.Top_Up_Started_At__c != null && c.Top_Up_Started_At__c > staleBefore) continue;
            Integer ready = readyByCert.containsKey(c.Id) ? readyByCert.get(c.Id) : 0;
            if (ready >= CertStudyService.poolTarget(c.Id)) continue;
            if (toStart.size() >= slots) break;
            if (Limits.getQueueableJobs() + toStart.size() >= Limits.getLimitQueueableJobs()) break;
            c.Top_Up_Started_At__c = DateTime.now();
            toStart.add(c);
        }
        if (toStart.isEmpty()) return;
        update toStart;
        for (Cert__c c : toStart) {
            AsyncOptions opts = new AsyncOptions();
            opts.MaximumQueueableStackDepth = MAX_CHAIN_DEPTH;
            System.enqueueJob(new CertStudyPoolJob(c.Id), opts);
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
            // Typically a Models API callout failure (overview derivation): retry later, a few times.
            attempt++;
            if (attempt < MAX_ATTEMPTS) {
                chain = true;
                modelFailed = true;
            } else {
                attempt = 0;
                chain = false;
                cert.Last_Failure_At__c = DateTime.now();
            }
        }
        Boolean restartLater = false;
        if (chain && atMaxDepth()) {
            chain = false;
            restartLater = true;
        }
        cert.Top_Up_Started_At__c = chain ? DateTime.now() : null;
        update cert;

        if (chain && !Test.isRunningTest()) {
            CertStudyPoolJob next = new CertStudyPoolJob(certId);
            next.attempt = attempt;
            next.fallback = fallback;
            next.fallbackRatio = fallbackRatio;
            try {
                if (modelFailed) {
                    // Back off: a failed call retries after a delay instead of burning every attempt at once.
                    AsyncOptions retry = new AsyncOptions();
                    retry.MinimumQueueableDelayInMinutes = RETRY_DELAY_MIN;
                    System.enqueueJob(next, retry);
                } else {
                    System.enqueueJob(next);
                }
            } catch (AsyncException e) {
                // Depth limit we could not detect up front: release the lock so the restart can claim it.
                update new Cert__c(Id = certId, Top_Up_Started_At__c = null);
                restartLater = true;
            }
        }
        if (restartLater) scheduleRestart();

        // A chain that ended normally frees a slot: start the next waiting cert (the
        // failure cooldown keeps a cert that just gave up from being retried right away).
        if (!chain && !restartLater && !Test.isRunningTest()) {
            try {
                requestTopUp(CertStudyService.activeCertCodes());
            } catch (Exception e) {
                // Best effort; the hourly scheduler picks up anything missed.
            }
        }
    }

    private static Boolean atMaxDepth() {
        if (forceAtMaxDepth) return true;
        Integer depth = AsyncInfo.getCurrentQueueableStackDepth();
        return depth != null && depth >= MAX_CHAIN_DEPTH;
    }

    /** One-off CertStudyScheduler run in ~1 minute, unless one is already pending. */
    @TestVisible
    private static void scheduleRestart() {
        String pattern = RESTART_JOB_PREFIX + '%';
        Integer pending = [
            SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :pattern AND NextFireTime != null
        ];
        if (pending > 0) return;
        DateTime t = DateTime.now().addMinutes(1);
        String cron = t.second() + ' ' + t.minute() + ' ' + t.hour() + ' ' + t.day() + ' ' + t.month() + ' ? ' + t.year();
        System.schedule(RESTART_JOB_PREFIX + t.getTime(), cron, new CertStudyScheduler());
    }

    /** One unit of work. Returns true if another job should follow. All callouts happen before any DML. */
    @TestVisible
    private Boolean runOnce(Cert__c cert) {
        modelFailed = false;
        if (!CertStudyService.isCertNeeded(cert.Id)) return false;

        String grounding = CertStudyGenerator.assembleGrounding(cert.Id, CertStudyGenerator.MAX_GROUNDING_CHARS);
        if (String.isBlank(grounding)) {
            cert.Last_Generation_Error__c = 'No resource content for this cert -- add Cert Resource text.';
            return false;
        }

        // First use: derive duration / question count / passing score / domains, once.
        if (cert.Overview_Derived_At__c == null) {
            String raw = CertStudyLlm.get().generate(CertStudyGenerator.buildOverviewPrompt(
                cert.Name, CertStudyGenerator.overviewGrounding(cert.Id, CertStudyGenerator.MAX_GROUNDING_CHARS)
            ));
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
        Integer target = CertStudyService.poolTarget(cert.Id);
        if (ready >= target) return false;

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
            modelFailed = true;
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
                    cert.Last_Failure_At__c = DateTime.now(); // cooldown before anything retries this cert
                    return false; // give up this cycle; the scheduler or a later claim retries
                }
                toInsert = fallback;
            }
        }

        if (toInsert == null) return true; // retry the same slot

        insert CertStudyGenerator.toRecord(toInsert, cert.Id);
        if (reason == null) {
            cert.Last_Generation_Error__c = null;
            cert.Last_Failure_At__c = null;
        }
        attempt = 0;
        fallback = null;
        fallbackRatio = null;
        return ready + 1 < target;
    }
}
