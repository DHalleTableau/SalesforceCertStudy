# Salesforce Cert Study App — Architecture Plan

> Canonical living plan, kept in the repo so any fresh session gets
> full context by cloning + reading this file. This file is kept
> deliberately short and dense -- see `HISTORY.md` for the detailed
> narrative behind non-obvious decisions (only needed for "why", not
> for doing the next task).

## >>> CURRENT DIRECTION (Oct 30, 2026): Salesforce-native rebuild <<<

**Heroku is abandoned.** The Heroku dyno can never reach the internal Claude
gateway (AWS), and AWS access/permissions can't be changed. Everything now
lives in a Salesforce org the user administers (a Trailhead-signup org with
no PII or customer data; CLI alias `certstudy`). Generation goes through the
Einstein Models API (`sfdc_ai__DefaultBedrockAnthropicClaude55Sonnet`), so no
gateway is needed. The interface is an Agentforce agent: Agent Builder
preview first, then the Slack demo org (testers added as users there).
Internal Slack/org62 comes later. The sections below describe the retired
Heroku build; they are kept for reference and for the migration scripts.

**Read these to resume:** `salesforce/README.md` (deploy, data load, agent
setup), `SPIKE.md` (pass/fail goals and status), then the progress note below.

**Resuming in Cowork:** connect the folder `~/Documents/SalesforceCertStudy`
and read the files above with absolute paths. Do not run recursive listings
from the repo root (`.venv` holds 5000+ files); search under `salesforce/`
only. The user runs `sf` CLI and `git push` in their own Terminal. Claude
edits files and checks Apex syntax in the sandbox with `prettier-plugin-apex@1.13.0`
(the sandbox has Java 11, so the 2.x plugin won't run).

**Progress (Nov 2, 2026, paused mid-agent-testing):**
- **Done and verified:**
  - Deploy; 18/18 tests passing.
  - Model `sfdc_ai__DefaultBedrockAnthropicClaude55Sonnet` works.
  - Data loaded: 88 certs, 35 prerequisite links, 172 resources, 301 questions.
  - Hourly scheduler running.
  - Chain-depth fix deployed (Trial org caps chained Queueables at 5; the job now stops and schedules a one-off restart).
  - **Real generation verified (spike Q1 passed):** two certs went from 0 to 5 questions plus an overview, no errors, about 6-10s per question, good quality.
  - Prompt and parse tweaks deployed: no mirror-image option pairs; the doubled "Correct: Correct." label is stripped; the unlocked pre-check keeps answer turns from waiting on the generation lock.
  - `scheduleHourly()` is idempotent.
- **Probably not deployed yet:** the Apex formatting fix that puts blank lines between options and sections, because chat collapses single newlines. Run the deploy again: `sf project deploy start --source-dir force-app --target-org certstudy | grep -E "Status: (Succeeded|Failed)|Error"`.
- **Agent:** built in the NEW Agentforce Builder. Full state, gotchas, every Optimizer prompt used, and the retest script are in **`salesforce/AGENT_SETUP.md`**. In short:
  - The actions are wired up, and Find Certs → Start Session work in Live Test.
  - Answer handling (a reply of "A" → Submit) was fixed by the Optimizer and saved; it hasn't been retested.
- **Nov 2, later:**
  - Agent Live Test worked well after the v2 instructions.
  - Migrated Heroku questions retired: 295 rows, marked Retired, reversible. They were A-biased (A correct 257/301) and the longest option was usually right.
  - New question mix: 50% 3-option, 40% 4-option, 10% multi-select.
  - Domain-weighted generation.
  - Cert- and domain-rotating question picks.
  - Agent duplicate-submit guard.
  - Built and **deployed** the in-org Lightning app (`certStudy` LWC + `CertStudyController`, `Cert_Study` tab and app). 21/21 tests pass. It has NOT been tried in the browser yet.
  - **Test mode is next** (spec in `salesforce/README.md`).
- **Next, in order:**
  0. Smoke-test the Lightning app: App Launcher → **Cert Study** (open the app, not the tab).
     - Pick a cert, then answer by click and by keyboard (A–E, Enter).
     - Confirm the feedback stays until Next.
     - Check the Summary.
     - If the app is missing, re-check the CertStudy_Admin perm set or open the Cert Study tab.
     Done: the app smoke test passed. Test mode passed too; the user tested a full early-end run.
  0b. Nov 2 (later):
      - Quick fixes: exam sections come from top-level weighted sections only; more than 12 sections is rejected; with no weights in the material, sections are grouped into 10 or fewer (equal weights).
      - `CertStudyOverviewJob.rederiveSuspect()` (`scripts/rederive_overviews.apex`) fixed Platform Administrator (28 → 10 sections). Its material has no section weights; pasting the official outline would give real weights.
      - Recommendations capped at 5, with "not reached" combined into one line; weights rounded.
      - **Identity = Salesforce User Id**, not email (emails aren't unique). `Study_Session__c.User__c` lookup added. A test proves two same-email users stay separate.
      - **Progress history** built and deployed: the "My progress" button shows totals, all-time weakest areas and a session/test list with re-openable details (`getHistory` / `getSessionDetail`). 27/27 tests pass. Not yet tried in the browser.
      - The LWC now targets Experience Cloud pages too.
  0c. IN PROGRESS: **host via Experience Cloud on this org** (before Slack). Site is built and registration works; resume at "Hosting status" below, step 1.
  1. In the builder: confirm `practice_session` has RULE 1. Send Optimizer prompt #3 if needed. Always save from the Agent Definition tab.
  2. Retest in Live Test.
  3. Identity check: is `User_Key__c` the learner's email or the agent user's? If it's the agent user, pass the end-user identity into `userKey`.
  4. Commit the version, activate it, and deploy to the Slack demo org with testers.
- **Open items:**
  - Weak-domain targeting.
  - CSV export.
  - Contributions intake.
  - Data 360 search index for grounding.
  - Delete the Heroku app/DB.
  - Commit and push the repo (the user commits from their Terminal).

## Hosting plan: Experience Cloud (next)

The user prefers Experience Cloud on this org over Slack, since Slack permissions are uncertain. What Salesforce's internal Slackbot said: employees can log in to Experience Cloud sites (check the "Allow employees to log in directly to an Experience Cloud site" setting), and an internal-only, no-customer-data tool is the right shape. A persisting SDO as a host is NOT confirmed as sanctioned, so ask in #q-branch-sdo before promoting it widely, and call it a pilot.

**Correction:** the app's data lives in custom objects in this org, NOT Data 360. Back it up: a CSV export plus a rebuild script, so an org lapse is recoverable.

**Licenses available in the org (Nov 2):**
- Salesforce: 506 free.
- External Apps Login: 1300.
- Customer Community Plus Login: 405 (90 non-login).
- Customer Community Login: 30.
- External Identity: 2100. Login only, too limited to run the app.

**Recommended pilot design:**
- An LWR site with the `certStudy` component; the LWC already has the `lightningCommunity__Page/Default` targets.
- Users on **External Apps Login** (or CC Plus Login).
- **Self-registration restricted to @salesforce.com emails**, with email verification: an Apex self-reg handler that rejects other domains, and an Account to hold the users' Contacts.
- The admin stays internal.
- Identity already uses the User Id, so community users are separate.

### >>> PLANNED FEATURES (queued Nov 10; review/next round of changes the week of Nov 9) <<<

**DECISIONS (user, Nov 12):** item 3 uses a "Select upcoming exams" BUTTON (no automatic preselect); item 2 weak-area focus is an opt-in checkbox, default OFF, only for certs with earlier answers; item 4 entered exam scores automatically turn focus on for that cert, with a visible note and an off switch.

**BUILD ORDER (user, Nov 12):** after checking the done-locally items (1, 6, 8, hide-retiring default), build 7a, 5b, 5a, 7b, 2, 3, 4, 5c, then 9 + 9b (65 questions / 5 unscored). Status: **7a, 5b, 5a, 7b built locally Nov 12** (untested in an org; see their notes below), 2, 3, 4, 5c, 9, 9b not started. Items 10 and 11 are now **admin/content tasks, not code**: load more source material and worked example questions as foundational logic for those certs (see their notes). Item 12 needs an easy source for the official list of 24 (the Salesforce Ben article would not fetch automatically; copy the list from the Salesforce Help "2027 Certification Retirements FAQ").

**Built Nov 12 (local, uncommitted, not deployed):**
- **7a Deselect all:** button beside the selected-cert pills in `certStudy.html`; `deselectAll()` also clears prerequisite answers.
- **5b Bigger buffer:** `CertStudyGenerator.POOL_SIZE` 5 to 8 (`TEST_POOL_TARGET` stays 10). More cached rows per cert and more generation calls; revert if Models API usage is a concern.
- **5a Waiting screen:** `CertStudyService.waitMessage(codes)` (learner-safe reason: paused after errors with minutes left, being written now, or waiting to start; no raw error text), `CertStudyService.kickGeneration(codes)` (clears the failure cooldown and a lock older than 2 minutes, then requests a top-up), `CertStudyController.retryGeneration()`, `SessionView.waitMessage`. The LWC shows the reason, has a Check again button at all times while waiting, and polls up to ~6 minutes (was ~3).
- **7b Select last session:** `CertStudyService.lastSelection` / `CertStudyController.getLastSelection()`, button above the picker ("Select last session (Practice, 2 certs)"). Restores mode, certs, timer choice (test) or minimum difficulty (practice). A test restores one non-aggregate cert only. Prerequisite prompts may ask again for aggregate certs.
- Tests added to `CertStudyTest` and `CertStudyControllerTest` for waitMessage/kick, retryGeneration and lastSelection. Run both classes before deploying.

- **2 Weak-area focus (built Nov 12, local, uncommitted, untested in an org):** new `Study_Session__c` fields `Focus_Weak_Areas__c` (checkbox) and `Domain_Weights_JSON__c` (snapshot `{"CERT": {"Domain": weight}}`), both in the Admin perm set.
  - History: all the learner's `Answer__c` rows (Practice AND Test) grouped by cert and domain. Weight = 1 + 2 x (1 - adjusted accuracy), where adjusted accuracy shrinks a domain toward the cert's overall accuracy with strength 5 (so 3 answers cannot swing it). 1.0 is neutral, 3.0 is the maximum; 1.5 or more counts as weak (about 75% accuracy or lower). Certs with no history get no weights, so focus simply does not apply to them.
  - Serving (`claimFromPool`, Practice only): weighted random order inside each rotation bucket; with focus on, only the previous question's domain is avoided (was the last 3), so weights decide the mix. `claimForTest` is untouched.
  - Generation: `focusDomainNeeded` finds the weakest domain with fewer than 3 unclaimed Ready questions; `CertStudyPoolJob.runOnce` generates for it, and `requestTopUp` starts a chain for it (guarded by an `anyFocus` check so there is no cost when nobody uses focus). Works alongside minimum difficulty.
  - UI: "Focus on my weaker sections" checkbox in Practice mode (default off; disabled until a selected cert has earlier answers) via `getFocusableCerts()`; the session screen shows "Focusing on your weaker sections: ..." (`SessionView.focusNote`). `startPractice` now takes a 4th parameter `focusWeakAreas`; the Agentforce action is unchanged for now.
  - Tests: weights, history-only application, weighted claim, test mode unaffected, pool targeting. Fixed an earlier bug in my minimum-difficulty tests (AI-201 has a prerequisite, so the start call needs the prerequisite answer).
  - Tunables: `FOCUS_SHRINK` 5, `FOCUS_BOOST` 2.0, `FOCUS_WEAK_WEIGHT` 1.5, `FOCUS_DOMAIN_READY` 3 in `CertStudyService`.
  - Known limits: aggregate credentials (e.g. Application Architect) have no direct answers, so select the individual exams; no recency weighting yet (all history counts equally).

- **What's new cleanup (Nov 12):** `APP_VERSION` is now `v0.14.0` (`APP_RELEASED` is the placeholder "Nov 2026"; set the real date when published). The v0.14.0 entry lists everything shipped so far; shipped items were removed from Coming soon. Add each new 0.14 feature to that entry as it is built. The user will publish in Experience Builder after a batch of 0.14 work, so the learner site still shows v0.13.0 until then.
- **3 Upcoming exams (built Nov 12, local, uncommitted, not deployed):** new object `Study_Goal__c` (User, Cert, Exam_Date, Status Studying/Passed/Not passed/Dropped, Outcome_Recorded_On; private sharing; Admin perm set only, learners go through system-mode Apex like `User_Cert__c`).
  - Service/controller: `getGoals`, `saveGoal` (adds or updates the open goal for a cert; blank date clears it; rejects aggregates; max 10 open), `removeGoal` (sets Dropped, never deletes), `recordGoalOutcome` (Passed also marks the cert earned via `setEarned`; Not passed keeps the record so a retake is a new goal). Marking a cert earned elsewhere settles its open goal as Passed. Goals are scoped to the owner (`UserInfo.getUserId()`).
  - UI (per the user's decision, a button, no auto-preselect): "Select upcoming exams (N)" and "Manage upcoming exams" on the picker; a "My upcoming exams" view (add exam + optional date, edit date, remove); once the date has passed, a "Did you pass?" card on the picker with Yes / No / Ask me later (Ask me later hides it until the next visit). Test mode selects just the first upcoming exam.
  - Item 4 (below) now covers the section-score paste after "No, not this time".
  - Tests: four service tests and one controller test.
  - Deploy note: new object + fields + perm set entries deploy with the rest. After deploy, no extra perm set assignment is needed.
- **4 Exam section scores (built Nov 12, local, uncommitted, not deployed):** new field `Study_Goal__c.Section_Scores_JSON__c` (`[{name, pct, domain}]`, in the Admin perm set).
  - Flow: "No, not this time" on the Did-you-pass card opens a "Your exam results" view: paste lines like `Prompt Engineering: 83%`, Preview, then a per-line dropdown maps each line to one of the cert's sections (auto-matched; "(not one of these sections)" for none), then "Save and focus on these" (or Skip). Entering scores is optional.
  - Parsing/matching (`CertStudyService.parseSectionScores`, `matchDomain`): one `Name[:-] NN%` per line, other lines and values over 100 ignored; match by exact normalized name, then unique containment, then word overlap of at least 50% (unique best). Unmatched lines are stored but do not affect weights.
  - Weights (`weightsFromScores`): pass mark = `Passing_Score__c`, else 70 (the screen says when it is assumed). Below pass: 1.5 rising to 3.0 at 25 or more points under. At or above pass: 0.5 (about half as often). Several lines on one section use the lowest.
  - Override: `focusWeights` replaces the history weights for a cert with the exam weights, using the latest "Not passed" goal that has scores, until the user earns that cert (pass recorded or marked earned). Practice only (Test untouched), same session snapshot as item 2.
  - UI: `getExamFocus()` feeds the picker; for a selected cert with exam results the focus checkbox is pre-ticked with a note ("Focusing on your exam results for X (exam results from Nov 12, 2026), until you pass. Untick the box to practice without it."). Unticking sticks for that visit. `getFocusableCerts()` now includes certs with exam results, even with no practice history.
  - Tests: parsing the real sample report, name matching, weight math (58/67/100 vs pass 73 = 2.4/1.86/0.5), preview/save validation and ownership, override then restore after passing, controller flow.
  - Known limits: only the latest failed attempt counts; no decay as practice accuracy improves; no way to edit saved scores yet except to re-fail and re-enter.
  - Deployed and 67/67 tests passing (Nov 12).
  - Completed exams (Nov 13, local, not deployed): the "Manage upcoming exams" view is now **My exams**. Completed goals (Passed, Not passed, Dropped) are never removed, only hidden behind a **Show completed exams** toggle (off by default). Each Not passed row has Add scores / View or update scores, which reopens the scores screen prefilled from `Section_Scores_JSON__c` (`getExamHistory`, `getSavedSectionScores`, `CertStudyService.examHistory`/`savedScores`). Passed rows are shown but carry no scores. Test: `completedExamsStayReachableAndScoresCanBeEditedLater`.
  - Delete (Nov 13): each completed row has Delete with an inline Yes/Cancel (`CertStudyService.deleteCompletedExam`, `CertStudyController.deleteExam`). It permanently removes that record and its scores; it does not un-earn a passed cert. Open exams still use Remove (soft Dropped).
  - Add a past attempt (Nov 13): under Show completed exams, "Add a past attempt" (exam, date taken, Did not pass / Passed) calls `CertStudyService.addPastExam` and creates a completed record directly (date is also the outcome date so attempts sort chronologically; future dates rejected; Passed marks the cert earned). A failed attempt opens its scores screen right away. A booked retake can sit in the upcoming list at the same time; the most recent failed attempt with scores drives focus until the cert is earned.
  - **Future (user request): score trends.** If a learner fails the same exam more than once, show per-section changes between attempts. The data is already kept: each failed attempt is its own `Study_Goal__c` with its own `Section_Scores_JSON__c`, so a trends view can compare attempts by section name/domain (match on the normalized section name, since official names can change between attempts). Deleting a record removes that attempt from the trend. Listed in Coming soon.
  - Deferred to 0.15 (user request): the home picker is getting cluttered (upcoming exams, last session, filters, focus, difficulty); plan a tidier layout, e.g. group secondary actions under a menu.
  - Platform Administrator sections were updated to the current 8-section outline via `salesforce/scripts/apex/update_platform_admin_sections.apex`. Other certs may have changed outlines too; consider a content check for the most-used certs (admin/content task alongside 10/11).
- **5c Reuse answered questions (built Nov 12, local, uncommitted, not deployed):** new lookup `Question__c.Source_Question__c` (in the Admin perm set). In `claimFromPool`, when no fresh Ready question matches, `claimReused` copies an answered question from ANOTHER learner into this session (Status Served, `Source_Question__c` = the original), so the learner keeps going while top-up generation runs (still requested as before).
  - Never reused: questions this learner got before (their own, or an earlier copy, via a NOT IN on `Source_Question__c`), questions with any `Question_Report__c`, and anything below the session's minimum difficulty. Weak-area focus weighting applies to the pick.
  - Practice only; Test mode (`claimForTest`) is unchanged. Originals stay with the first learner; copies carry their own Answer rows, so stats are unaffected.
  - Caveats: copies add Question rows (Question counts/reports now include them; filter `Source_Question__c = null` for originals). Candidate pool capped at 200 per pick. Answered rows count toward any "question count" report.
  - Tests: reuse once per original, own questions skipped, reported skipped, minimum difficulty respected. Deployed and passing Nov 13.

### >>> PICK UP HERE (end of Nov 12) <<<
- **State (Nov 13):** items 7a, 5b, 5a, 7b, 2, 3, 4, 5c and the My exams / completed-exams change are built, deployed and tested (70/70 passing). Remember `sf` commands run from the `salesforce/` subfolder; git from the repo root.
- **Published Nov 13:** v0.14.0 dated Nov 13, 2026 in `certStudy.js` and `releaseNotes.js`; the user re-publishes the Experience site after deploying. Later changes go into a v0.14.1 or v0.15.0 entry.
- **Item 15 built (Nov 16, v0.14.3, awaiting deploy/test):** `Reminder_Setting__c` (one per user, key = User Id) with Email/Slack (reserved) flags, cadence (Daily/Weekdays/Twice a week/Weekly + day), final-week ramp, Last_Sent_On__c, Last_Error__c; `CertStudyReminders` (Schedulable + Batchable size 1): hourly at :05, sends one digest per learner once per local day after 9am in their time zone, only with an open non-overdue goal; digest lists exams with days left plus up to 2 sample questions (other learners' answered originals, weakest section by focus weights, never ones the learner has seen/reported, answer in small gray text) and a link to the app; controller `getReminderSettings/saveReminderSettings/sendTestReminder`; My exams has a Study reminders box; tests in `CertStudyRemindersTest`. **After deploy run once:** `sf apex run --file scripts/apex/schedule_reminders.apex` (calls `CertStudyReminders.scheduleHourly();`).
- **Next (Nov 16):** 13, 14, 9, 9b and 15 are done. Next in the agreed order: a Slack spike for 16 (Slack reminders reuse `Slack_Enabled__c`). Still to do after the format data load: run `scripts/apex/load_format_mix.apex` with `purgeMismatched = true` once to clear Ready questions in the wrong format. Also queued: v0.15.0 home-page declutter, score trends across attempts, outline checks on other certs, items 10/11/12.
- **Next to build:** 9 + 9b (per-cert question formats from `salesforce/data/cert_format_mix.csv`; mock tests deliver `Delivered_Questions`, default 65, with 5 random unscored, never revealed; exam time limits unchanged). Then admin/content tasks 10/11 and item 12 (needs the official list of the 24 retiring certs from the Salesforce Help FAQ; the Salesforce Ben page could not be fetched, so copy the list in).
- **Not published yet:** the learner site still shows v0.13.0. When the v0.14.0 batch is done: set the real date in `APP_RELEASED` (certStudy.js) and the v0.14.0 entry in `releaseNotes.js`, deploy, then Publish in Experience Builder.
- **User-owned:** production environment, SSO, friendlier URL. Agentforce `StartSession` action does not expose focus yet.
- **Gotchas learned:** `inner` and `end` are reserved Apex words; long-text fields cannot be filtered in SOQL; permission-set XML needs each element type contiguous; `DEFAULT_PASSING_SCORE` already exists in `CertStudyService` (exam-results code uses `EXAM_DEFAULT_PASS`); `sf` needs Node on PATH (nvm/brew).

**Next review (week of Nov 9): list every queued feature, re-prioritize, and fix the v0.14.0 scope.** Candidates so far: 1 min difficulty (built locally), 2 weak-area focus, 3 upcoming exams, 4 failed-exam section scores, plus the older "Coming soon" items (stats dashboard, non-Salesforce certs, SSO login).

**User-owned, in progress (not Claude tasks yet):** turning this into a production environment ahead of a large batch of new testers this week, then enabling Salesforce SSO on it. Once production is ready, add a new, easier-to-remember URL (or URL mask) and update the login page, release notes and any links. Revisit the hosting plan above when the production org is decided.

None of items 1-4 are pushed or deployed. Items 2-4 apply to Practice only, never Test mode.

**1. Minimum difficulty picker (Practice only): BUILT LOCALLY, uncommitted, untested in an org.**
- Practice start screen gets a "Minimum difficulty" dropdown, 1-5, default 1 (also an optional `Minimum Difficulty` input on the Agentforce Start Practice Session action). Null/out of range clamps to 1-5.
- Stored on `Study_Session__c.Min_Difficulty__c` (in the CertStudy_Admin perm set). Plumbed through `startSessionCore`, `CertStudyController.startPractice(certCodes, prereqAnswersJson, minDifficulty)` (3rd param is new; tests updated) and `CertStudyService.startSession`.
- Serving: `claimFromPool` filters Ready rows to `Difficulty__c >= min` (unrated legacy rows only count at min 1). `claimForTest` is untouched.
- Pool depth: the shared pool is mixed difficulty, so a high minimum could find nothing eligible. `CertStudyService.unmetMinDifficulty(certId, target)` finds the highest active-session minimum whose eligible Ready count is below target; `CertStudyPoolJob.runOnce` generates at `nextDifficulty(total, min)` (min..5) and `requestTopUp` uses it (via `needsTopUp`, with a cheap `anyHighMin` guard). Expect the cached Ready pool to grow past POOL_SIZE (5) per cert when high minimums are used.
- Deploy checklist: deploy the new field + perm set with the classes/LWC, then run CertStudyTest + CertStudyControllerTest. Version bump + release note still to do (see releaseNotes.js).

**2. Weak-area focus (Practice only): PLANNED, not started.**
- Goal: for a cert the user has answered before (in Practice OR Test mode), offer an option to ask questions more often from the sections/domains they did worst in. Never applies to Test mode (tests keep the official domain weights in `claimForTest`).
- UX: on the Practice start screen, a "Focus on my weaker sections" option (default OFF), enabled only for certs with prior answers; a cert with no history just runs normally. Optionally show the focus sections at session start. Also an optional input on the Agentforce Start Practice Session action.
- History: all `Answer__c` rows for the user's earlier sessions on that cert (both modes), grouped by `Question__c.Domain__c`; accuracy per domain. Same user identity as My Progress (`User_Key__c` / `User__c`).
- Weighting (to decide): weight = 1 + k * (1 - accuracy), with a minimum sample (e.g. 5 answers) per domain and shrinkage toward the cert's overall accuracy so a thin sample doesn't dominate; domains with no data get neutral weight. Snapshot the weights on the session at start (e.g. `Focus_Weak_Areas__c` checkbox + `Domain_Weights_JSON__c`) so a session is stable and cheap to serve.
- Serving: in `claimFromPool`, keep the cert/domain rotation buckets but choose among candidates by weighted random on domain weight instead of uniform shuffle. Multi-cert sessions apply per cert.
- Pool depth (same issue as min difficulty): the shared pool is domain-rotated by official weights, so a weak domain may run short. Needs a per-domain unmet check like `unmetMinDifficulty`, and generation that targets the weak domains (`nextDomain` override) when a focus session is active. Combine cleanly with minimum difficulty (both filters on one claim).
- Open questions: recency weighting/lookback window; k and minimum sample; whether a recently improved domain should decay out; whether to surface "your weakest sections" on the picker.

**3. Upcoming exams (study goals): PLANNED, not started.**
- Goal: let a user mark the certs they are actively studying for, optionally with an exam date, so the picker can preselect them on login (or via a "Select upcoming exams" checkbox/button) and save clicks.
- Data: new object (working name `Study_Goal__c`, separate from `User_Cert__c`, which means "earned"): User, Cert, Exam_Date (optional), Status (Studying / Passed / Not passed / Dropped), Outcome_Recorded_On, plus the section scores in feature 4. One open goal per user + cert.
- UX: a "My upcoming exams" setting (cert + optional date, add/remove) reachable from the picker and from My Progress. On the select screen, either preselect open goals by default or show a "Select upcoming exams" button (decide which; the button is the less surprising default). Test mode still allows one cert, so it preselects only the first goal / lets the user choose.
- Lifecycle: suggestions and preselection stop after the exam date. After the date, prompt "Did you pass {cert}?" on next login. Yes: mark the goal Passed and create the earned `User_Cert__c` row (Source = Self-reported), which feeds Hide completed / Up next. No: go to feature 4. Skip / not yet: ask again later. No date set: goal stays open until the user changes it.
- Reuse: the exam-date prompt follows the "My certifications" self-report pattern (Nov 4 decision); no external data source involved.
- Open questions: preselect by default vs button; how often to re-ask an unanswered pass/fail prompt; whether to show a countdown or a study-pace nudge as the date nears; whether a past-date goal with no answer should block anything (suggest no).

**4. Record section scores from a failed exam: BUILT Nov 12 locally (see "4 Exam section scores" under Built, above). Original plan kept below.**
- Goal: after "did not pass", let the user paste the official section-level results (e.g. `Prompt Engineering: 83%`, `Data 360 Fundamentals: 58%`, ...) so practice focuses on the sections that were below the pass mark, with a little time kept on the strong ones.
- Input: a paste box, one `Section: NN%` per line, parsed in Apex with a preview/confirm step (user can edit a row). Match each line to the cert's `Domains_JSON__c` domain names (case/punctuation-insensitive, with a manual mapping dropdown for unmatched lines, since official exam section names may differ from our derived ones). Store scores on the goal (e.g. `Section_Scores_JSON__c`, entered-on date, attempt number), keeping each failed attempt.
- Effect: while the goal is open (not Passed), these scores OVERRIDE the history-derived weights from feature 2 for that cert. Weight by gap to the pass mark: sections below it get the most (larger gap = more), sections at or above it get a small maintenance weight (e.g. Prompt Engineering 83% still appears occasionally). Only the latest failed attempt's scores drive weights. When the user later records a pass, the override is dropped and feature 2's practice-history weights take over again.
- Scope: Practice only, same as feature 2 (Test mode keeps official weights). Uses the same session snapshot (`Domain_Weights_JSON__c`) and pool-depth/domain-targeting work as feature 2, so build 2 first.
- Applies even if the user has not enabled the weak-area checkbox? Decide: proposed that entering scores implies opt-in for that cert, with a visible "Focusing on your {date} exam results" note and an off switch.
- Open questions: the pass mark per exam (we hold `Passing_Score__c` per cert; exams report per-section % only, so use it as the threshold); how to weight sections without a score; decay as practice accuracy in a weak section improves past the exam score; privacy (scores are the user's own and visible to admins as ordinary records).

**5. Slow refill when answering fast (reported Nov 11): PLANNED, cause not confirmed.**
- Report: answering quickly drained the pool; the "Generating your next question" screen ran about 4 minutes before a question arrived (the screen gives up polling at about 3 minutes). It did recover on its own.
- Likely contributors (code review): one question per job at ~6-10s each, so a drained pool of 5 refills slowly; Trial-org queueable depth cap of 5 then a ~1 minute scheduled restart; a 1 minute retry delay after each failed model call; a 10 minute failure cooldown and 15 minute stale lock that waiting learners cannot bypass. More testers also share the 3-chain concurrency cap.
- Scheduled: test and fix Nov 12 or 13 (user busy Nov 11). Note: the `sf` CLI failed with "env: node: No such file or directory" in the user's Terminal (Node not on PATH); fix that first or run the queries in Developer Console > Query Editor.
- To confirm: query `Cert__c` (Top_Up_Started_At__c, Last_Failure_At__c, Last_Generation_Error__c) and recent `CertStudyPoolJob` AsyncApexJob rows for the affected cert.
- Candidate fixes: (a) show the real reason on the waiting screen and raise MAX_POLLS or make "Check again" kick a top-up that ignores cooldown/stale lock when a learner is waiting; (b) larger buffer (POOL_SIZE ~8-10) so fast answerers have runway; (c) when the pool is empty, re-serve a question this user has not seen that others already answered, instead of waiting. Prioritize before the new tester wave.

**6. Keep picker selections when leaving the select screen (reported Nov 12): FIXED LOCALLY, untested in the browser, uncommitted.**
- Cause: "Back" from What's new and from the suggestion/contribution form called `showSelect()`, which resets `selectedCodes` and `prereqAnswers`. Fix: new `returnToSelect()` in `certStudy.js` just switches the view back (full reset only if the cert list was never loaded). Mode, filters, timer choice and (new) minimum difficulty were already kept as component fields.
- Not changed: starting a session, ending one, or "Start a new session" still clear the picks on purpose. Check My progress / Suggested next certs return paths in the browser; they may still reset.
- Test: pick certs, open What's new, Back; pick certs, open Suggest an improvement, Cancel; confirm the picks and mode remain.

**7. Deselect all and Select last session (low priority QoL): PLANNED, not started.**
- "Deselect all" button on the picker, enabled when anything is selected.
- "Select last session": preselects the certs (and mode, plus timer/min difficulty if useful) of the user's most recent Practice or Test session. Source: latest `Study_Session__c` for the user (`Cert_Codes__c`, `Mode__c`), already readable via `latestSession()`; needs a small controller method returning codes + mode. Test mode takes one cert only, so for a multi-cert last practice session while in Test mode select just the first (or disable). Hide when the user has no earlier sessions.
- Pairs with feature 3 (upcoming exams preselect); decide whether both live behind one "Quick select" menu.

**8. Promote mobile and cross-device use (Nov 12): DONE LOCALLY, uncommitted, not deployed.**
- Finding (user test): a practice session started on a laptop resumed on a phone at the same question. Sessions live in the org, not the browser, and the mobile experience is solid. Wording says "works on your phone" (browser), not "mobile app".
- Added: (1) login page welcome banner line in `certStudyWelcome.html` (hard-coded, so it shows even if the Builder-saved tagline overrides the default); (2) a line under the help text on the picker in `certStudy.html`; (3) a draft `v0.14.0` entry at the top of `RELEASES` in `releaseNotes.js`.
- Before release: set the real date on the v0.14.0 entry and bump `APP_VERSION`/`APP_RELEASED` in `certStudy.js` (the entry is listed but not marked current until then). Move the other built items (min difficulty, keep selections, hide retiring default) from Coming soon into that entry when they ship. Republish the Experience site so the login banner appears.
- Later ideas: a first-answer hint ("Leave anytime, your session will be here on any device"); invite/announcement text with the URL and a "save to home screen" tip.

**Exam-day feedback (Nov 12; user took two real exams: passed one, barely failed the other). Items 9-11 are PLANNED, not started.**

**9 + 9b. Per-cert question formats and unscored test questions: BUILT, deployed and tested Nov 16 (v0.14.2, 75/75 passing). Original plan below.**
- Built: `Cert__c.Format_Mix__c` (e.g. `1of4|2of4|2of5`, first = most common; blank/NONE = generic mix) and `Cert__c.Delivered_Questions__c`; new `Format__c` values `2of4`, `2of5`, `3of5` (1of3 = `single3`, 1of4 = `single`, legacy `multi` kept). `CertStudyGenerator.nextFormat(cert, total)` takes 6 of 10 slots for the first format (5 when four formats), the rest shared; prompts and validation now use exact option and correct counts per format (`optionCount`, `minCorrect`, `maxCorrect`). `CertStudyPoolJob` passes the cert in.
- 9b: a test delivers `Delivered_Questions__c` (else scored count + 5; `CertStudyService.deliveredQuestions`), with 5 random question numbers unscored (`Study_Session__c.Unscored_Positions__c`, never sent to the browser). Each answer at an unscored position is flagged `Answer__c.Is_Unscored__c` when graded. `testResult` excludes flagged answers from the score and sections but keeps misses in the review (decision Nov 16: yes, list them). Result text says how many were unscored, not which. History scoring uses scored answers only. Older sessions (no positions) score as before. Time limits unchanged.
- Deployed Nov 16 and the format data is loaded in the org (88 certs updated, none missing). Two new tests needed fixes (test data, SOQL limits); 73 of 75 passed on the first run.
- Data: `scripts/apex/load_format_mix.apex` loads the CSV into existing certs (set `purgeMismatched = true` to delete unclaimed Ready questions in formats a cert does not use). 88 rows; confidence tiers are in the CSV.
- Known limits: existing Ready questions keep their old format until purged or used; test mode serves whatever is Ready, so purge before demoing a cert whose format changed. Format mix is per cert, not per section.
 User is collecting a per-cert breakdown of real exam question structure.**
- Observed: one exam was purely 1-of-4 multiple choice; the other mixed 1-of-4, 2-of-4 and one 2-of-5. Other exams the user has taken are all 1-of-3 or other combinations, so it differs per cert.
- Today the mix is global: `CertStudyGenerator.nextFormat` (10-slot cycle: 5 x `single3`, 4 x `single`, 1 x `multi`), and `multi` is fixed at 5 options with 2 or 3 correct (`optionCount`, prompt text, and the min/max correct check in `parseQuestion`).
- Proposed: a per-cert format mix on `Cert__c` (e.g. `Format_Mix_JSON__c`: list of {options, correct, weight}), with formats generalized to "N options, K correct" (1-of-3, 1-of-4, 2-of-4, 2-of-5, plus any others the user finds). `nextFormat(cert, total)` reads the cert's mix and falls back to the current global mix when none is recorded. Grading is already all-or-nothing and needs no change.
- Test mode should follow the cert's mix as closely as possible (count by format like domain quotas in `claimForTest`); Practice just rotates through it. Same pool-depth caveat as items 1 and 2: the shared pool is generated ahead by rotation, so per-format needs generation targeting and a per-format unmet check.
- Data entry: user supplies the breakdown per cert; load via a CSV upsert like the other cert data, and update the item-5/backup scripts if they list `Cert__c` fields.
- **Data received (Nov 12) and saved to `salesforce/data/cert_format_mix.csv`** (88 rows keyed by `Cert_Code__c`; columns Format_Mix, Confidence, Notes; mixes written as `1of3`, `1of4|2of4|2of5`, etc.; `NONE` for aggregate and review-board certs). Summary: Strict 1-of-3 for the newer AI/Data/Analytics certs, Business Analyst, UX and Strategy Designers, Service/Field Service/Revenue consultants, Marketing Cloud Next, Sharing and Visibility and Data Architects, and the three Foundations (Platform, Marketing Cloud Engagement, Agentforce Sales). Strict 1-of-4 for Slack (all three) and MuleSoft (except where noted). Classic mix (1-of-4, 2-of-4, 2-of-5, sometimes 3-of-5) for most legacy exams and all remaining Accredited Professional exams.
- **Confidence tiers in the file:** `user-observed` (Platform Administrator, Slack Administrator: matches the user's Nov 12 sittings), `research-listed`, `research-assumed` (Accredited Professional exams not named in the research), `unknown-fallback` (11 certs not covered: Agentforce Life Sciences Consultant, B2B Solution Architect, B2C Commerce Architect, B2C Solution Architect, CPQ Administrator, Education Cloud Consultant, Industries CPQ Developer, Account Engagement Consultant, MuleSoft Catalyst Consultant, MuleSoft Hyperautomation Developer, Nonprofit Success Pack Consultant). The fallback rule given: classic mix for legacy exams, strict 1-of-3 only for brand-new 2025-26 launches.
- **Treat the research as unverified.** Its "About the Exam wording" heuristic ("N multiple-choice" = 1-of-3, "multiple-choice/multiple-select" = has multi-select) is a guess: Salesforce's own Slack Administrator guide says only "60 multiple-choice questions", yet the user's sitting was pure 1-of-4. Prefer the user's own sittings; only trust the rest as a starting point and correct rows after each real exam.
- **Question counts (user, Nov 12):** Slack Administrator and Platform Administrator each delivered 65 questions, and the user recalls many other exams also being 65. Salesforce's guides say "60 scored" plus up to 5 unscored, so 65 delivered is consistent with 60 scored; the research's "60 questions" figure is the scored count only. Added a `Delivered_Questions` column to the CSV (65 for those two, blank elsewhere; the user will fill it per cert as they recall or sit exams).
- **DECIDED (user, Nov 12): mock tests deliver the full 65 (scored + 5 unscored) and randomly leave 5 unscored without telling the learner. Exam time limits already match the 65-question exams, so keep `Duration_Min__c` as is.** Build notes: deliver count = `Delivered_Questions` (new `Cert__c` field, loaded from the CSV) else scored count + 5; at test start pick 5 random positions and store them on the session (e.g. `Unscored_Positions__c`), nothing in the UI hints at them; scoring, pass/fail, per-section percentages and the early-end secondary score ignore those answers; domain quotas still count all 65 so sections are balanced. DECIDED (user, Nov 12): never reveal which 5 were unscored, not on the results page either. Open: whether the review of misses should still list unscored misses (leaning yes, since revealing them is not allowed but reviewing is harmless; confirm). Passing score stays a percentage of scored questions.
- Test-mode impact (original analysis): `startTestCore` sets `Question_Target__c` from `Cert__c.Num_Questions__c`, which the model derives from the exam guide (typically 60). Decide whether a mock test should deliver the full count (65) and how the unscored 5 are handled: on the real exam the learner cannot tell which ones are unscored. Options: deliver 65 and score all 65 (simple, slightly harsher), or deliver 65 and randomly leave 5 unscored without telling the learner (closest to the real exam). Also check that the exam duration (e.g. 105 minutes) is already for the full 65, not 60. Pass mark is a percentage of the scored questions.
- Weights within a mix are not known (the user's classic-mix exam was mostly 1-of-4 with a few 2-of-4 and one 2-of-5). Decide default weights when building; a blank weight could mean "mostly 1-of-4, occasional multi".
- Open: how to treat "choose 2 of 5"-style prompts in the UI (the stem should say how many to pick; check the current multi wording shows the count).

**10. Licensing / edition-fit questions (Slack cert, passed; weakest section): REFRAMED Nov 12 as an admin/content task (user): add plan-comparison material and worked example questions for the Slack certs as `Cert_Resource__c` records so generation has the foundation. The new-style code below is optional, only if content alone does not move the question mix. Possible small code help: a `Role__c` for "Worked examples" that the prompt shows as examples to imitate.**
- Gap: at least 5 exam questions asked which edition or plan (Free, Business+, Enterprise+, Pro) could or could not solve a described problem. The user did not recall seeing this type during study.
- Proposed: a new question style (alongside terminology and the three scenario styles in `nextStyle`), e.g. `edition-fit`: describe a requirement, ask which plan/license/deployment satisfies it or why one cannot. Use it for certs whose products have tiers or licensing (Slack first), driven by a per-cert flag or domain hint so it is not applied everywhere.
- Content: make sure the cert has plan-comparison material in `Cert_Resource__c` (feature/plan matrix, limits by plan). Without grounding the model will guess plan boundaries, which is worse than no question. The user may want to supply the official plan-comparison page text.
- Also a candidate sample for item 4 (section scores), since the weak section is nameable.

**11. Formula and filter logic questions (Platform Admin): REFRAMED Nov 12 as an admin/content task (user): add formula/filter-logic source material and worked example questions for Platform Administrator (and other certs where it applies) as `Cert_Resource__c` records. The new-style code below is optional. Keep the correctness caveat: formula answers need a spot-check.**
- Gap: the exam went into actual expression logic (boolean checks, NOT, list-contains-style tests) for filters, groups and buckets; the user rarely saw this in practice.
- Proposed: a `logic-and-formula` style added to the rotation and applied wherever it fits (admin, data, reports/flows-type domains; not every cert). Questions give a short filter/formula/criteria and ask what it returns, which records match, or which expression meets a requirement. The user should confirm the exact function names that appear on the exam (e.g. what "list_contains" refers to) so prompts and grounding use the real terms.
- Caveat: correctness of generated formula answers is easy to get subtly wrong. Add a stricter validation or a spot-check pass on these before they go into tests.
- Related: the barely failed exam is a real test case for items 2-4; record the section results when the user is ready.

**12. Refresh cert statuses for the 2027 retirements and July 2026 renames: PLANNED, data task. Source-checked Nov 12.**
- Confirmed by Salesforce's own FAQ and several articles: 24 credentials retire Feb 1, 2027; 16 credentials were renamed effective July 24, 2026 (e.g. Sales Cloud Consultant to Agentforce Sales Consultant, Service Cloud Consultant to Agentforce Service Consultant, Data Cloud Consultant to Data 360 Consultant). The last day to register for a retiring exam was July 24 and the last sitting was Aug 31, 2026, so those exams can no longer be taken. Salesforce says a retired credential stays valid on the holder's profile, labeled "retired" from Feb 2027.
- To do: set `Exam_Status__c` / `Retires_On__c` on the 24 retiring certs in the org (known members present in our data: CPQ Administrator, B2B Solution Architect, Education Cloud Consultant, Nonprofit Success Pack Consultant, MuleSoft Hyperautomation Developer, plus several Accredited Professional credentials; get the full official list from the Salesforce Help "2027 Certification Retirements FAQ" before editing). "Hide retiring exams" (now default on) then hides them. Check cert names and aliases against the renames so search still finds old names (e.g. keep the former name searchable).
- Decide whether retired certs with no remaining sittings should be hidden entirely or kept for study (a held credential is still valid; the exam bank is gone).

**13. Taller paste box for exam results: BUILT and deployed Nov 16 (v0.14.1).** Native `<textarea rows=14>` with `.scores-box` CSS (min-height 16rem, vertical resize) plus a live "N lines pasted" line.
- The "Section scores" textarea on the exam results screen shows only about 2 lines, so it is hard to tell whether a paste worked. Make it taller (about 12-15 lines, resizable) in `certStudy.html` (lightning-textarea needs a min-height via CSS class in `certStudy.css`). Consider showing a "N lines detected" count after Preview.

**14. Searchable exam dropdown in My exams: BUILT and deployed Nov 16 (v0.14.1).** New LWC `certSearchPicker` (type-ahead over name and code, 10 results at a time, fires `select`), used for "Add an exam" and "Add a past attempt". Former-name search needs a data field for aliases (not built; add with item 12).
- The "Add an exam" and "Add a past attempt" dropdowns are plain comboboxes with a very long list. Replace with a type-ahead search (filter the cert list as the user types; match on name, code and former names, which also helps the 2026 renames). Options: a text input with a filtered list (lightning-input type=search + list), or a custom lookup built on the same `allCerts` data. Reuse for any other long cert pickers.

**15. "Send me a reminder to study" (queued Nov 14): PLANNED, new feature (candidate for 0.15).**
- Set up in My exams, per user (or per upcoming exam). Channels: Email checkbox, Slack checkbox (Slack is a later add if linking is not quick).
- Cadence: a schedule picker (daily, weekly on chosen days, etc.) plus an optional "increase reminders as the exam gets close" ramp (for example weekly until 30 days out, every few days until 14, daily in the last week), driven by `Study_Goal__c.Exam_Date__c`.
- Sub-idea: each reminder includes a sample question from the learner's weakest sections for that exam (using the existing focus weights: exam results first, else practice history), with the answer in small text at the bottom. Needs a question source that does not consume the learner's pool, for example a reused answered question from other learners (same selection rules as 5c) so it never counts as "seen" unless the learner then chooses to practice.
- Build notes: new fields for reminder settings (on `Study_Goal__c` or a new `Reminder_Setting__c`), a scheduled Apex job (hourly, like `CertStudyScheduler`) that finds due reminders, an email send through the org (Messaging.sendEmail; watch daily email limits), unsubscribe/pause link, and a "no reminder after the exam date or once passed" rule. Admin-visible log of sends. Slack send reuses the Slack integration below.
- Open questions: per-exam or global cadence; quiet hours/time zone; digest vs one email per exam; whether the sample question links back into the app (Experience site URL) with that cert preselected.

**16. Practice from Slack (queued Nov 14): BIG FUTURE FEATURE, needs a design pass before building.**
- Goal: learners practice from Slack, powered by the same app, so more people keep studying. They call it from Slackbot, and questions and answers appear in the Slackbot thread. MCP passes the questions to Slack.
- Scope for v1: Practice mode only (no Test mode), one cert per session, none of the web app's configuration (no minimum difficulty, no focus toggle unless it is cheap), same pool, same grading and explanations, same session record (`Study_Session__c`), so history, stats and weak-area weighting all keep working.
- Flow idea: user messages Slackbot (or a slash command) with a cert name; the bot starts a session via the existing `CertStudyService.startSession`, posts a question in the thread with answer options as buttons (or replies A-D), grades on reply, posts the explanation, then offers the next question or End. Identity: map the Slack user to the Salesforce user (email match on @salesforce.com) so sessions belong to the right `User_Key__c`.
- Existing pieces to reuse: the Agentforce invocable actions (`CertStudy_StartSession`, `CertStudy_NextQuestion`, `CertStudy_SubmitAnswer`, `CertStudy_SessionSummary`, `CertStudy_FindCerts`) already expose the core loop; the Agentforce agent could be surfaced in Slack, or a Slack app could call the same actions through MCP. Investigate first which path is cheapest (Agentforce in Slack vs a custom Slack app with the Slack MCP/API).
- Dependencies and risks: Slack app approval/permissions in the Salesforce Slack workspace, message formatting (long explanations, multi-select answers), rate limits, abandoned sessions (the scheduler already ends idle sessions), and the question-reuse/pool behaviour when many people practice at once. Same Slack link would also serve item 15's Slack reminders.
- Suggested sequence: item 14/13 small fixes (0.14.1), 9 + 9b, then 15 (email first), then a Slack spike for 16.

### >>> PICK UP HERE (written end of Nov 6; user back the week of Nov 9) <<<

**Resume point:** Tableau Next "Cert Study Usage" dashboard, Adoption page built (see "Nov 6" notes below for every ID). Start Claude Code from ~/Documents/SalesforceCertStudy; MCPs tabnext-certstudy + dc-sql-certstudy (read-only); confirm each write with the user, never delete without asking.
1. User checks the Adoption page after the bar-chart rebuild (expect Sessions by day 2/10/7/3/6, New learners 1/3/1); fix any layout issues (metric tiles may need more than 8 rows).
2. Ask: delete the 2 old unused vizzes (1AKaj00000ThGATGA3, 1AKaj00000TgnLOGAZ)?
3. Share the dashboard with CertStudy admins (ask which user/group).
4. Next page: Cert demand (answers by cert, certs never practiced), then Learning outcomes, Content health (step 4 list below). Propose calcs + vizzes first.
5. Still open from before: Builder REPUBLISH of the site; commit + push (score-field/Data Cloud prep plus today's PLAN.md).

### (Nov 5 → Nov 6 marker, kept for detail)

**Shipped Nov 5 (all deployed, tests 57/57):** v0.12.0 Trailhead study links (33 loaded, all URLs checked; "Get Ready for Agentforce" deactivated), What's new + Coming soon; CT-000002 Tableau Next guide approved and loaded as a 71k-char Additional resource; backup script extended; daily admin digest (3pm PT, scheduled); v0.13.0 decision emails + Note to Learner (verified with CT-000003 approval email); Study_Session Score_Pct__c/Passed__c stored on test finish (4 old tests backfilled); Data Cloud connector perm set has read on all 9 Cert Study objects.

**Not yet done:** Builder REPUBLISH of the site (learners still on the old version until then; user deliberately waiting until the dashboard step); commit + push of the score-field/Data Cloud prep (see git note below).

**Nov 6 progress:** all 9 streams Active with expected counts (Cert 88, Question 555, Study_Session 34, Answer 67, Study_Link 33, User_Cert 9, User_Study_Link 3, Contribution 2, Question_Report 0). Cert/Answer/Question_Report show intermittent Failure on no-op hourly upserts (0 records, 0:0:0); not blocking, but check Answer count rises after new activity. User stream SKIPPED (use User__c ids + first session as sign-up proxy; add later via one relationship). Semantic model built from DLOs (no DMO mapping needed) with all 7 relationships, after fixing an error where the parent side auto-filled a field named after the object instead of Record ID. NEXT: connect User_Study_Link.Study_Link__c -> Study_Link Record ID (or remove), name/save model, Model Filter User_Key__c != 'system-warmup', then metrics (step 4). Adoption calcs planned: Learners = COUNTD([User]); Tests Taken = COUNT(IF [Mode]="Test" THEN [Record ID] END); First Session Date = {FIXED [User] : MIN([Started At])}; Sessions = built-in Study_Session count (28 after warm-up filter, from 34). WRITABLE MCP for this org (user-provided, pilot): https://api.salesforce.com/platform/mcp/v1/d/trailsignup-5d9fea1e5cdf7f/analytics/tableau-next-pilot ; add as a custom connector in Claude (name it e.g. "Tableau Next Pilot certstudy" to keep it apart from the Org62 read-only connector), then resume in a new session and build calcs/vizzes/dashboard through it (confirm each write with the user). Cowork custom connectors are greyed out (admin setting), so use Claude Code from ~/Documents/SalesforceCertStudy with these MCPs (all names end in -certstudy): tabnext-certstudy (writable pilot, above); dc-sql-certstudy = https://api.salesforce.com/platform/mcp/v1/d/trailsignup-5d9fea1e5cdf7f/data/data-cloud-queries ; data360-certstudy = https://api.salesforce.com/platform/mcp/v1/d/trailsignup-5d9fea1e5cdf7f/data/data360 . Use the Data Cloud ones read-only, to check dashboard numbers against the DLOs.
  CONNECTED Nov 6 (Claude Code, project-local): tabnext-certstudy (161 tools, URL above, tableau-next-pilot) and dc-sql-certstudy (2 tools). data360-certstudy dropped: the new Data 360 server is not active/listed in this org ("not implemented"). Auth setup that works: External Client App "CertStudyECA" in the certstudy org, callback http://localhost:8080/callback, scopes mcp_api + refresh_token, PKCE on, "Require secret for Web Server Flow" OFF, JWT-based tokens for named users ON; add with `claude mcp add --transport http --client-id "$KEY" --callback-port 8080 <name> <url>` (no secret; no angle brackets). Gotchas hit: `<key>` in zsh is a redirect; tokens are only issued when the require-secret setting matches; start `claude` from ~/Documents/SalesforceCertStudy (local scope). Disable the generic (Org62) user MCPs for this project. The consumer secret was exposed in a screenshot: rotate it (unused).
  READ-ONLY CHECK Nov 6 (via MCP, nothing written): model "Cert Study Usage" = apiName `New_Semantic_Model_ba6` (id 2SMaj000002xTKzGAM), workspace `Cert_Study` (1Dyaj000000JAoTCAW), org 00Daj00001EnAthEAF. 9 DLO objects, apiNames `<Obj>_c_Home` (e.g. `Study_Session_c_Home`). 8 relationships, all child -> parent Record_ID (User_Study_Link -> Study_Link is connected). Model Filter `Study_Session_c_Home.User_Key DoesNotEquals 'system-warmup'`. No calcs/metrics/vizzes yet besides the 9 auto `<Obj>_rowCount` measures. Field apiNames: Study_Session `User`, `User_Key`, `Mode`, `Started_At`, `Completed_At`, `Status1`, `Passed`, `Score` (=Score_Pct), `Record_ID`; Answer `Study_Session`, `Question`, `Is_Correct`, `Answered_At`; Question `Cert`, `Domain`, `Status1`, `Study_Session`, `Served_At`; Cert `Cert_Name`, `Cert_Code`, `Exam_Status`, `Last_Failure_At`, `Is_Aggregate`. Counts match DLO: 34 total, 6 warm-up, **28 after filter** (Practice 17, Test 4, blank Mode 7). Gotchas: TuA has no IF (simple CASE only); 8 pre-Nov 2 sessions have User = '' (empty string, not NULL; keys are the admin, gentest@example.com, noreply@salesforce.com), so COUNTD(User) would count '' as a learner: use CASE [User] WHEN '' THEN NULL ELSE [User] END. Real learners = 5. LOD `{FIXED [Study_Session_c_Home].[User] : MIN([Study_Session_c_Home].[Started_At])}` works.
  CREATED Nov 6 (user-approved) in `New_Semantic_Model_ba6`: calc measures `Learners` (COUNTD of User with '' -> NULL) and `Tests_Taken` (SUM of CASE Mode WHEN 'Test'); calc dims `First_Session_Date` (FIXED LOD, sign-up proxy) and `Mode_Label` (label "Mode"; blank -> "Unknown (pre-Nov 2)"). Verified by semantic query: Learners 5, Tests Taken 4, Sessions 28; by mode Practice 17 / Test 4 / Unknown 7; 5 learners by First Session Date (Nov 2, 3, 3, 3, 5). NEXT: Adoption visualizations V1-V4 (each create to be approved), then the dashboard.
  CREATED Nov 6 (user-approved; daily grain until there is more data, KPIs as semantic metrics instead of a table): metrics `Learners_Metric`, `Sessions_Metric`, `Tests_Taken_Metric` (time dim Study_Session `Started_At`, grains Day/Week/Month, PriorPeriod comparison, identifying dim `Record_ID` / naming `Session`, Mode_Label as insight dimension on the first two). Verified: Sessions Oct 2 + Nov 26 = 28; Tests Nov 4; Learners by day Nov 2:1, 3:3, 4:1, 5:2. Visualizations in workspace `Cert_Study`: "Learners per Day" (line, 1AKaj00000ThG5dGAF), "New Learners per Day" (bar on First_Session_Date, 1AKaj00000TgnLOGAZ), "Sessions per Day by Mode" (stacked bar, colour Mode_Label, 1AKaj00000ThGATGA3). Switch the vizzes to DateTruncWeek once there are a few weeks of data. NEXT: eyeball the 3 vizzes + 3 metric cards in the UI, then build the Adoption dashboard page (metric tiles on top, 3 charts below); then the Cert demand / Learning outcomes / Content health views.
  DASHBOARD CREATED Nov 6 (user-approved): "Cert Study Usage" (`Cert_Study_Usage`, 0Traj000000V45lCAC) in workspace Cert_Study; 48-col grid; page 1 renamed "Adoption" (page name 23df4e3f-18a7-45c5-af62-0cbbdcc34a52): title text, 3 metric widgets (m_learners/m_sessions/m_tests; metric widget source = {name: <metric apiName>} + metricOption sdmApiName/sdmId works), Learners per Day + New Learners per Day side by side, Sessions per Day by Mode full width. All 7 widgets status Ok on read-back. NOT yet: visual check in the UI, sharing with CertStudy admins (propose separately). Further views = add_page on this same dashboard.
  BAR CHART FIX Nov 6: user screenshot showed both bar charts broken (bars on a continuous DateTruncDay axis stretch across gaps and overlap; data itself correct: per day Oct 31: 2, Nov 2: 10, Nov 3: 7, Nov 4: 3, Nov 5: 6). Line chart OK. CREATED (approved) discrete calc dims `Session_Day` = DATE([Study_Session_c_Home].[Started_At]) and `First_Session_Day` = {FIXED [User] : MIN(DATE([Started_At]))} (DATETRUNC returns DateTime and fails a Date field; use DATE()). `edit_visualization` field-swap ops fail with an opaque EDIT_OPERATION_FAILED (op params undocumented; replaceFieldFromRowsOrColumns / changeFieldOnRowsOrColumns tried), nothing changed. PENDING user choice: (A) recreate the 2 bar vizzes via create_visualization with the discrete day fields and repoint dashboard widgets v_sessions_mode / v_new_learners (keep old vizzes until user says delete), or (B) user swaps the field in the UI. Day boundaries follow the query timezone (session appears UTC+1; Pacific would move the 2 first sessions to Oct 30).
  DONE (user chose A): new vizzes "Sessions per Day by Mode" (1AKaj00000ThJ6jGAF; Session_Day discrete, colour Mode_Label, count labels) and "New Learners per Day" (1AKaj00000ThJ8LGAV; First_Session_Day discrete, Learners >= 1 filter, labels), both sortIntent DimensionAscending (else bars sort by value). Dashboard widgets v_sessions_mode / v_new_learners repointed, saved, read back Ok. OLD unused vizzes still in workspace (same labels): 1AKaj00000ThGATGA3 and 1AKaj00000TgnLOGAZ; delete only if user asks. Lesson: for bar charts by date in Tableau Next use a discrete DATE() calc dim, not a continuous DateTrunc axis.

**Tomorrow, usage dashboard in Tableau Next (certstudy org, manual UI; Org62 MCP connector does NOT reach this org):**
1. Check Data Cloud > Data Streams: the 9 `*__c_Home` streams (Study_Session, User_Cert, Cert, Question, Contribution, User_Study_Link, Question_Report, Answer, Study_Link) were Processing at end of day; confirm Active + record counts (expect roughly: Cert 88, Question 555+, Study_Session 34+, Answer 67+, Study_Link 33). If any failed, open it for the error.
2. **User stream was NOT created** (no User_Home in the list; user could not find where to choose User fields). Needed for learner names/sign-up dates on adoption views. Options: add a Salesforce CRM data stream for the standard User object (fields Id, Name, UserType, IsActive, CreatedDate), or skip it and use Study_Session.User__c (ids) + first session date as the sign-up proxy.
3. Semantic model (Tableau Next > workspace "Cert Study"): add the DLOs directly (map to DMOs only if DLOs are not offered). Relationships: Answer.Study_Session__c -> Study_Session.Id; Answer.Question__c -> Question.Id; Question.Cert__c -> Cert.Id; Question_Report.Cert__c / Contribution.Cert__c / User_Cert.Cert__c -> Cert.Id; Study_Session.User__c -> User.Id (if streamed). Exclude User_Key__c = 'system-warmup' sessions.
4. Metrics for the four views: Adoption (distinct learners per week, new learners = first session date, sessions started, practice vs test); Cert demand (answers by cert, certs never practiced); Learning outcomes (accuracy by cert and Domain__c, test pass rate from Passed__c, avg Score_Pct__c); Content health (Ready unserved questions per cert = Status Ready and Study_Session null, certs with Last_Failure_At__c, open Question_Report / New Contribution counts).
5. Dashboard: one page per view; share with CertStudy admins.

### (Earlier marker, Nov 3 → Nov 4; superseded by the Nov 6 marker above)

**State:** the Experience Cloud pilot is LIVE and in early testing (3 teammates registered; a few practice sessions and tests run; no direct complaints except the sign-up issue). Site: https://trailsignup-5d9fea1e5cdf7f.my.site.com/sfcertstudy (Active; republish in Builder after any LWC change). App version **v0.9.0**. 37/37 of our tests pass. Deployed today: generation resilience (3 concurrent chains, delayed retries, 10-min failure cooldown), pool warm-up and backup scripts, banner/footer/version polish, clearer login message. The polish was seen in the org after a republish; NOT yet checked on the site as an external user. Commit/push still to be confirmed (`git status`; `git ls-remote` vs `git rev-parse HEAD`).

**Goal for tomorrow:** a few more fixes, then record a quick demo for broader/senior teams.

**Nov 4 progress, exam status (item 3 below) DEPLOYED and the 24 retiring certs LOADED (24/24 upserted, 38/38 tests pass); still to check on the live site after a Builder republish:** new fields `Cert__c.Exam_Status__c` (Retiring/Retired/Renamed), `Retires_On__c`, `Path_Forward__c`; the picker (`certStudy`) shows an amber "Retiring on Feb 1, 2027. <path forward>" note under each flagged cert and has a "Hide retiring exams" checkbox; `CertOption` carries status/retiresOn/pathForward; test `listCertsCarriesRetirementStatus`. Data: `salesforce/data/cert_status.csv` = Salesforce's official list of 24 certs retiring Feb 1, 2027 (all 24 matched to our 88 by name; cert codes equal names), loaded with `sf data upsert bulk --sobject Cert__c --file data/cert_status.csv --external-id Cert_Code__c --line-ending LF --wait 10 --target-org certstudy`. NOT yet run. The "16 renamed" list the user pasted looks third-party and inconsistent (it lists Marketing Cloud Account Engagement Consultant as renamed "no structural change" while the official retiring table has it retiring; our catalog already uses some new names, e.g. Data 360 Consultant, Agentforce Sales/Service Consultant, and still has old names for Business Analyst and Omnistudio Consultant/Developer): do NOT apply it until checked against Salesforce's own page. Idea: derive categories (type: Accredited Professional / Administrator / Consultant / Developer / Architect / Specialist; product area) from names for labeling and filtering.

**Nov 4, categories BUILT (not deployed), version bumped to v0.10.0:** `lwc/certStudy/certCategories.js` derives a Type (Accredited Professional, Architect, Administrator, Developer, Consultant, Specialist, Foundations, Analyst / Designer) and a Product area (Slack, Data & Analytics, Integration [MuleSoft only], Marketing, Commerce & Revenue, Industries, Sales & Service, Agentforce & AI, Platform) from each cert's name; checked against all 88 names (none fall to "Other"; Platform has the most, 25). The picker has Product area and Type dropdowns next to "Hide retiring exams". Pure client-side, no data load. If a cert lands in the wrong bucket, edit the regex rules in that file.

**Nov 4, prerequisites in the picker BUILT (not deployed):** `CertStudyService.prereqNamesByCert()` + `CertOption.prereqs`; each cert row shows a gray "Prerequisites: A, B" line (from the 35 `Cert_Prerequisite__c` links, direct prerequisites only). Test assertion added.

**Nov 4 (later): the user asked for the toggle next, so the self-report part is BUILT (not deployed): `User_Cert__c` (User, Cert, Source, Earned On, Unique_Key__c = UserId:CertId, Private sharing), `CertStudyService.earnedCertCodes/setEarned`, `CertStudyController.getEarnedCerts/setCertEarned` (keyed to `UserInfo.getUserId()`), a per-row "Mark earned / Earned (undo)" button and a default-ON "Hide certs I've earned (N)" checkbox in the picker, 2 new tests. Also built the same day (not deployed): a "Suggest next certs" button next to "My progress" opening a Suggested next certifications view (up to 5; 3 from the learner's own/related areas, up to 2 "Broaden your skills" starters [Platform Administrator, Agentforce Specialist, Slack Administrator]; skips earned, retiring/retired, aggregate certs and certs whose prerequisites are not earned; "Practice this" preselects it, "I already have this" marks it earned). Logic is client-side in `lwc/certStudy/certRecommendations.js`, tested in node against the real catalog (Tableau-heavy profile gets CRM Analytics, Data 360, Tableau Next, Agentforce Specialist, Platform Administrator). STILL post-release: the Trailhead sync. Original decision follows.**

**Decision Nov 4: self-report "My certifications" + "Hide completed" + "Up next" is a POST-RELEASE feature (not before the recorded demo). Trailhead sync waits until an official/authorized data source exists. Focus now: the recorded demo.**

**Design, per-user completed certs, "Already completed" filter and recommendations (agreed in principle Nov 4; BUILD LATER, after the demo and release):**
- Source-agnostic. New object `User_Cert__c` (User lookup by User Id, Cert lookup, Earned On, Source = Self-reported / Trailhead, Verified, Synced At; unique per user + cert). An Apex `CertSource` interface with a self-report implementation now and a Trailhead implementation only when an approved data source exists.
- UI: "My certifications" (tick the ones earned, works with no integration) plus a "Sync from Trailhead" option behind an explicit per-user consent screen saying exactly what is read, with a "disconnect and delete my synced data" control. The Sync option stays hidden/"coming soon" until a source exists.
- Picker: completed certs get a check badge and are hidden by a default-ON, uncheckable "Hide completed" filter. Recommendations ("Up next"): not completed, not retired, with every direct prerequisite completed (or none), ranked by same product area as what the user already holds.
- **Feasibility test, Nov 4 (public pages only):** (1) `trailhead.salesforce.com/credentials/verification` is a name search behind a ReCaptcha and a JS app: not usable from code. (2) Trailhead MCP (`https://mcp.trailhead.salesforce.com/mcp`, docs at trailhead.salesforce.com/support/mcp, updated 2026-08-24) exposes only public learning content (`content_search`, `fetch_content`), needs no authentication "in its current form", and states it does not access private learner data, badges, points, or certifications. So there is NO official per-user certification feed today. Options: self-report now; watch for an authenticated Trailhead MCP/API; ask Salesforce via the Trailhead MCP feedback path (help.salesforce.com/s/cases, "Ask Agentforce", state it relates to Trailhead MCP) and the existing IdeaExchange request for a certification API; keep looking for an internal source. Spin-off idea (public data, low risk): link each cert to relevant Trailhead trails/badges via Trailhead MCP.
- Open question for the user: what is the Trailhead sync side-effort based on (an internal data source, a user's public profile, or a user-uploaded export)? Salesforce has said there is no public certification API and the verification page is opt-in only; avoid scraping. The answer decides the Trailhead adapter and its consent wording.

**Plan for the working session when the user is back (do ALL visual changes, deploy once, republish once):**
1. Deploy the pending changes (exam status already deployed; this adds categories + v0.10.0): `sf project deploy start --source-dir force-app --target-org certstudy`, run our 4 test classes.
2. **Sign-up visibility.** In the LWR Builder, look at page properties for an access / "require login" setting on pages. If present: make a public landing page (big "Sign up" and "Log in" buttons, short explanation, @salesforce.com note) and keep the `certStudy` page protected. If not: check Administration > Pages for login-page branding; otherwise rely on the invite text.
3. Any other visual changes the user wants (spacing, wording, colors) in the same pass.
4. Republish once; check as an external user in incognito (banner, version, retiring notes, filters, sign-up path).
5. Commit and push; fresh backup (`bash scripts/backup_org.sh`) copied off the laptop.

**Do, in order:**
1. **Check the polish on the live site** as an external user (incognito): banner, footer, version chip, cert list spacing; type an unregistered @salesforce.com email and see whether the new "click Sign Up" message appears (earlier handler errors showed nothing; the page just reset).
2. **Make Sign Up far more visible** (teammates looped on the login page). The login page is the platform's standard Login Discovery page, so our code cannot restyle its small "Sign Up" link. Options: (a) public landing page with big "Sign up" / "Log in" buttons ahead of login (look for a per-page access / "require login" setting in the LWR Builder page properties; keep `certStudy` on a login-protected page); (b) branding/CSS for the discovery page (check Administration > Pages for login branding); (c) instructions in the invite. Fall back to (c) for the demo.
3. **Certification freshness (exam status).** Add status + end date on `Cert__c` (Active / Retiring / Retired / Renamed), compare the 88 certs against Salesforce's "2027 Certification Retirements FAQ" (24 retiring Feb 1, 2027, 16 renames; retiring exams can no longer be scheduled), show a label in the picker, consider hiding or de-emphasizing Retired. Known examples in our picker: B2B Solution Architect, Marketing Cloud Advanced Cross Channel / Intelligence / Personalization Accredited Professional (verify against the FAQ; sources differ).
4. **Demo prep:** pick certs with stocked pools (30 certs have 5+ ready; warm-up ran for 20); short script (register, email-code login, practice, test, My progress); decide what to say about the pilot status/org lifetime (trial org, 30-day extensions).
5. Commit and push everything; take a fresh backup (`bash scripts/backup_org.sh`) and copy it outside the laptop.

**After the demo (already designed above):** contribution + suggestion forms and the release log ("What's new"), daily 3pm PT digest of new submissions with a 48h SLA and auto-created Cert Resources on approval; "My certifications" self-report checklist; ask #q-branch-sdo whether a persisting SDO may host this (call it a pilot); usage report/dashboard; decide on a permanent site and a better short link (the sfdc.co link's redirect never completes; deferred).

**New item (Nov 5): non-Salesforce certifications, starting with AI certs useful to employees.** First: Anthropic's **Claude Certified Associate – Foundations (CCAO-F)**. Public facts (third-party prep sites + Pearson VUE, Nov 5; confirm against Anthropic's official exam guide): non-developer/business-user exam; 60 questions, 120 min, 7 domains (Output Evaluation and Validation the largest at 21%); scaled pass 720/1000; $99; registration gated to Claude Partner Network orgs via Anthropic Partner Academy with a company-domain email; valid 12 months; Pearson VUE says updated exam guides arrive Nov 17, 2026 (applies to tests from Dec 7). Work needed: (a) data: a Cert__c row (60 q / 120 min / passing ~72% as an approximation of scaled 720, Domains_JSON with the 7 official domains and weights) plus a Primary Cert_Resource with the OFFICIAL exam guide text (not third-party prep content); refresh after Nov 17; (b) app: add an Issuer/Provider dimension (Salesforce vs Anthropic vs other) to certCategories.js with a filter, an area for non-Salesforce AI, keep "Mark earned"/recommendations working (consider suggesting CCAO-F as a "broaden" pick for Agentforce/AI holders), and reword "Salesforce certifications" in the banner/login copy to "certifications"; (c) later: more external AI certs (other vendors) once the pattern works.
  Candidate backlog beyond AI (source: SF Ben, "25+ Non-Salesforce Certifications to Boost Your Resume", Lucy Mazalon, updated Jan 6, 2026, https://www.salesforceben.com/non-salesforce-certifications-to-boost-your-resume/). Each needs individual work (official exam guide/syllabus for grounding, format, passing score, eligibility, cost): Business analysis: IREB CPRE and Digital Design Professional; IIBA pathway (ECBA/CCBA/CBAP). Project management: PMI PMP; Scrum Alliance (Scrum Master, Product Owner); ACMP CCMP (change management). Design/UX: Codecademy + Miro "User Research: Generative" (free course). Architecture: TOGAF (The Open Group); ITIL 4 Foundation (AXELOS); Microsoft Azure certs; Google Cloud certs; Zachman ZCEA; AWS Certified Cloud Practitioner. Security: ISC2 range. Data: INFORMS Certified Analytics Professional (CAP); Cloudera CCA Data Analyst (check it is still offered); Tableau (already Salesforce); Microsoft Power BI Data Analyst Associate. DevOps: Copado, DevOps Launchpad (Gearset), Flosum, DevOps Institute DevOps Foundation. RevOps: Winning By Design Revenue Architecture; HubSpot RevOps course. AI: IBM SkillsBuild Artificial Intelligence Fundamentals. Productivity: Microsoft Excel Associate/Expert. Note some are courses/badges without a proctored exam (Codecademy, HubSpot, IBM SkillsBuild); treat those as study-only or skip in Test mode. Prioritize with the user later.

**Future idea (from contribution CT-000003, Nov 5; user wants it too): results + personal stats dashboard.** A richer breakdown on the results page and on a per-user profile view (trends over time, by domain/cert, pass likelihood), possibly built in Tableau Next. Overlaps the planned admin usage dashboard.

**Post-release idea (added Nov 4): internal SSO login.** After a user has signed up, let them log in with Salesforce's internal SSO (used for many internal tools) instead of waiting for an emailed verification code. Configuration to be worked out later. Starting points to evaluate: an Experience Cloud SAML or OpenID Connect authentication provider added to the site's login options, and matching the SSO identity to the existing external user by email (the self-registration and Login Discovery handlers already key on the @salesforce.com email). Open questions: whether an external-identity SSO app can be registered for a trial org/pilot, who approves it (IT/security), and whether the email-code path stays as a fallback. Do not promise this in the demo.

**Nov 5: per-question "Report a problem" BUILT (not deployed), version v0.11.0.** `Question_Report__c` (Question, Cert, Reporter, Issue_Type__c, Comment__c, Status__c New/Reviewing/Fixed/Dismissed, Reported_At__c, Reviewer_Notes__c; Private; admin perm set only), `CertStudyService.reportQuestion` (own-session check, 20/hour limit, repeat report on the same question updates the open one), `CertStudyController.reportQuestion`, a "Report a problem with this question" link + inline form on the question and feedback views, test `questionReportsAreValidatedScopedAndDeduplicated`. (earlier Nov 5 marker, superseded by the Nov 6 marker above)
Status of v0.12 work (nothing below is deployed unless marked):
- DEPLOYED + tested: question issue reports (v0.11), admin tabs/layouts/report, contributions + suggestions (42/42 tests), Login Prompt text. Welcome panel LWC deployed but unused (Builder Login page is not served).
- BUILT, NOT DEPLOYED: release log (`releaseNotes.js` + "What's new" chip, v0.12.0).
- (4) Trailhead study links, IN PROGRESS. User chose: curated links loaded as data, shown at the end of every practice session and test, plus a running deduped list in My progress.
  - Done: `data/study_links.csv` (33 official Trailhead links for 20 certs: strailhead prep trailmixes, "Prepare for..." trails, credential pages; 7 URLs fetched and verified, the rest from live search results); objects `Study_Link__c` (Cert, Title, URL, Link_Type__c, Sort_Order__c, Domain__c "Exam Section" to prioritize weak sections, Active__c, Source__c, Link_Key__c ext id) and `User_Study_Link__c` (User, Study Link, First/Last Suggested, Unique_Key__c = userId:linkId); Study Links tab + admin perm set + app tab; service `studyLinksFor` / `recordSuggestedLinks` / `suggestedLinksFor` / `certIdsForSession`; controller `StudyLinkView`, `studyLinks` on SummaryView + TestResultView (via `suggestLinks`, weak = section < 70% or not likely-pass; failures never break results), `suggestedLinks` on HistoryView; test `studyLinksShowAtSessionEndAndBuildADedupedRunningList`.
  - DONE (new chat, Nov 5): LWC built. `mapLinks()` helper in certStudy.js (key, "Cert · Type" meta, "Last suggested" date in My progress); "Keep studying on Trailhead" list on practice summary (live + reopened from history) and test result; "Trailhead suggestions so far" in My progress before Sessions and tests; `.study-links` CSS; v0.12.0 release-note line added. CSV cert codes all match the Nov 5 backup. Also added: "Coming soon" box at the top of What's new (`UPCOMING` in releaseNotes.js, no versions/dates; remove items as they ship): stats dashboard, updates on reports/contributions, non-Salesforce certs (AI first), SSO login. historyAcrossSessions split into 3 tests (SOQL limit after link lookups). DEPLOYED Nov 5: 45/45 tests pass, 33 Study_Link__c rows loaded. NEXT: Builder republish (LWR caches components), try in app (internal + site), URLs verified Nov 5 (all 33 load and match their cert; trailmix contents client-rendered so judged by title). "Get Ready for Agentforce" (Agentforce Specialist|2) is beginner content, not exam prep: set Active__c=false in the CSV (column added) and re-upsert.
  - (original TODO, for reference) LWC. Add "Keep studying on Trailhead" block (links open in new tab, show cert name + type) to the practice summary (this.summary built ~line 784 and ~948 in certStudy.js: pass `studyLinks` through) and the test result (this.testResult built ~line 568: pass `studyLinks`), and a "Trailhead suggestions so far" list in the history view (this.history ~line 881: map `suggestedLinks`, add keys; HTML after the weak-areas block ~line 516). Then add a v0.12.0 release-note line, deploy, run the 4 test classes (expect 43), load data: `sf data upsert bulk --sobject Study_Link__c --file data/study_links.csv --external-id Link_Key__c --line-ending LF --wait 10 --target-org certstudy` (grant FLS first via the deployed CertStudy_Admin; run from salesforce/).
- CT-000002 APPROVED Nov 5 (Title fixed; Cert_Resource a4saj000000JdorAAC, Additional). Guide is 79k chars of colleague notes (unofficial), too long for Details; exam-logistics sections cut, ~71k loaded straight into Content__c via data/contributions/CT-000002_resource_update.csv (folder gitignored). Pattern for long contributions: approve with a short note, then bulk-update the created Cert_Resource.
- DONE Nov 5: links + What's new/Coming soon verified in the org; committed and pushed (52745d1); backup_org.sh now also exports Study_Link, User_Study_Link, User_Cert, Contribution, Question_Report; backup run (88 certs, 173 resources, 555 questions, 34 sessions, 67 answers, 33 links, 2 contributions, 0 question issues). Builder republish for the external site still pending (user tested in the org).
- (5) Daily digest DEPLOYED Nov 5 (52/52 tests; test send OK, sent=1, admins=1; schedule after the user checks the email): `CertStudyDigest` (Schedulable, job "Cert Study daily digest" wakes hourly and sends only at 15:00 America/Los_Angeles, because the admin user trailsignup... is Europe/Paris) emails every active CertStudy_Admin user (setTargetObjectId, no external email limit) the New question issues (count by cert + oldest-first list, max 50, comment/stem snippets), New contributions, and certs with Last_Failure_At__c in the last 24h; OVERDUE flag past 48h, overdue count in the subject; no email when empty; fails quietly (lastError) if deliverability is off. Test class `CertStudyDigestTest` (6 tests). Scripts: `scripts/digest_send_now.apex`, `scripts/digest_schedule.apex`. Needs Setup > Deliverability = All email.
- (6) Reply emails DEPLOYED Nov 5 (57/57 tests), v0.13.0; live check on CT-000003 + Builder republish pending: `CertStudyReplies` + `QuestionReportTrigger` (new) + `ContributionTrigger` (now before+after update). Question issue -> Fixed/Dismissed, Contribution -> Approved/Rejected stamps new `Reply_Sent_At__c` (once per item, never resent) and emails the reporter/submitter (setTargetObjectId, reply-to daniel.halle@salesforce.com, link to the site). New field `Note_To_Learner__c` (optional, goes in the email; fill it BEFORE setting the final status); `Reviewer_Notes__c` stays internal. Both fields on layouts + CertStudy_Admin. Test `CertStudyRepliesTest` (4). "Updates on problems you report..." moved from UPCOMING to the v0.13.0 release note. Items decided before this deploy (CT-000002) get no email.
- (7) Usage dashboard: user chose TABLEAU NEXT in the certstudy org (not Org62; the analytics MCP connector here points at Org62, view-only, so setup is manual in the UI). Provisioned: Data Cloud (GenieDataPlatformStarterPsl), Tableau Next Creator (TableauNextUserPsl 20, TableauEinsteinUserPsl 5), perm sets CDPAdmin / GenieAdmin / TableauEinsteinAdmin / sfdc_a360_sfcrm_data_extract ("Data Cloud Salesforce Connector"). Views wanted: adoption, cert demand, learning outcomes, content health. Prep BUILT (not deployed): `Study_Session__c.Score_Pct__c` + `Passed__c` stored on first finishTest (+ `scripts/backfill_test_scores.apex`, re-run until 0). Plan: (a) admin perms; (b) grant the Data Cloud Salesforce Connector perm set read on the Cert Study objects/fields; (c) CRM data streams for Study_Session, Answer, Question, Cert, Question_Report, Contribution, User_Cert, User (+ Study_Link/User_Study_Link optional); (d) semantic model with relationships + metrics; (e) workspace + dashboard.
- Remaining list items after Trailhead: daily 3pm PT digest (issues + contributions), reply emails, usage dashboard; external certs (CCAO-F + SF Ben backlog) stay plan-only for now.

**Nov 5, v0.11 scope walk-through (one item at a time; skip permanent hosting + Trailhead sync):** (1) Sign-up visibility: BUILT (not deployed) `lwc/certStudyWelcome`, a guest-safe (no Apex) panel for the Builder Login page: brand banner, "New here? Create your account" big button (Builder property `signUpUrl` = the URL of the login page's own Sign Up link) and "Already registered? enter email, get a code". User places it above the login form in Builder > Login page, sets the URL, republishes. FINDING: Login Page Type = "Login Discovery Page" (standard platform page, handler CertStudyLoginDiscoveryHandler), so the Builder Login page (username/password form) is NOT served; do not switch to it (would break email-code login). Fix used instead: the "Login Prompt" text on Login & Registration + share the direct sign-up URL (https://trailsignup-5d9fea1e5cdf7f.my.site.com/sfcertstudyvforcesite/secur/CommunitiesSelfRegUi?startURL=%2Fsfcertstudy%2F) in invites. The welcome panel is kept for a future public landing page (needs guest access + per-page "requires login" on the certStudy page). SSO: deferred until the move to a production/persistent site. Live fix applied Nov 5: Login Prompt text "New? Click Sign Up below to register with your @salesforce.com email. Registered? Enter your email to get a login code." (user approved; custom page still preferred later).
(2) Contribution + suggestion forms: BUILT (not deployed), v0.12.0. `Contribution__c` (Kind Study resource/Suggestion, Cert, Cert_Name__c formula, Title, URL, Details, Submitter, Status New/Approved/Rejected, Submitted_At, Reviewer_Notes, Cert_Resource__c link), Contributions tab + New/All list views + layout, admin perm set. `CertStudyService.submitContribution` (http/https links only, cert required for resources, link or text required, 10/hour) + `ContributionTrigger` (before update): approving a Study resource creates an Additional `Cert_Resource__c` (Content = title + text, URL kept) once and links it. Note: link-only resources add no grounding text (generator reads Content__c only), so paste key text when approving if needed. UI: "Share a study resource" / "Suggest an improvement" links under the picker's Start button and on practice summary and test result screens; form view 'contribute' with thanks + "Send another". Test `contributionsAreValidatedAndApprovedResourcesBecomeCertResources`. DEPLOYED + 42/42 tests pass; user tested both kinds (CT-000002 Tableau Next guide is a Drive PDF link: needs its text pasted into Details before approval, and its Title fixed; CT-000003 = dashboard idea, logged above).
(3) Release log: BUILT (not deployed). `lwc/certStudy/releaseNotes.js` (RELEASES, newest first; ADD AN ENTRY ON EVERY VERSION BUMP) + "What's new" chip in the banner opening a 'whatsNew' view (Current badge on APP_VERSION), Back returns to the previous view. No object; notes ship with the code.

**Nov 5 follow-ups:** UI labels renamed to "Question Issue(s)" / "Issue #" (API names unchanged, still `Question_Report__c`) to avoid confusion with Salesforce Reports; page layout added (overwrites the auto-generated "Question Report Layout"); a repeat report by the same learner on the same open issue is now APPENDED to Comment__c (timestamped "follow-up: <type>" entry, original type/text kept; Comment__c raised to 32,768). Report renamed "Question Issues by Cert and Type".

**Admin review DEPLOYED Nov 5 (first built same day):** "Question Reports" tab in the Cert Study app (CertStudy_Admin tab visibility) with list views New Reports / Needs Attention / All Reports; custom report type "Question Reports" and report "Reports by Cert and Issue Type" (folder Cert Study, open reports grouped by cert then type, with a bar chart). Decisions: NO "retire question" action (each question is served to one session only, so retiring prevents nothing; use reports to find certs whose Cert Resources are thin or stale); NO urgent alert for now. Still to do: include new reports in the daily 3pm PT digest (counts by cert/type plus top comments), reply to reporter on Fixed/Dismissed. Original design follows.

**Post-release idea (added Nov 5): per-question "Report a problem" feedback.** A link/button on every question (during practice/test review and on the answer-feedback view) opens a small form so problems are caught as they happen. Fields: Issue type (picklist: Factually inaccurate; More than one correct answer; No correct answer; Outdated, missing a recent product update; Unclear or badly worded; Wrong domain or cert; Explanation is wrong; Other) and a free-text comment (required for Other). Design: new object `Question_Report__c` (Question lookup, Cert lookup via question, Reporter User, Issue_Type__c, Comment__c long text, Status__c New/Reviewing/Fixed/Dismissed, Reported_At__c, Reviewer notes); Apex `CertStudyController.reportQuestion(questionId, issueType, comment)` writes it in the without-sharing service, verifying the question belongs to the user's own session, with a per-user rate limit and comment length cap. Admin side: list view of New reports plus an admin action to retire a question (Status__c = Retired so it is no longer served) and regenerate; counts of reports per question so repeat offenders surface; include New reports in the planned daily 3pm PT digest (or a separate immediate alert for "More than one correct answer"/"Inaccurate"). Reuse the planned contribution/suggestion form UI and submission pipeline. Needs: object + perm set access for CertStudy_External, tests, republish. Candidate to build first among post-demo items since it directly improves question quality.

**Known issues / accepted:** rejected registrations (non-@salesforce.com) fail silently on the form; the login page shows a small "Salesforce Trial Org Request & Manage employee? Log In" link that cannot be removed (one login option is required); top-up jobs run as Automated Process, not the configured subscriber user; the org expires every 30 days (extend when notified); user feedback so far: sign-up not found; answer counts per session are low (5, 4, 2, 2, 1, 1), probably early/confusion.

**Handy checks:** pool by cert (`SELECT Cert__r.Name, COUNT(Id) n FROM Question__c WHERE Status__c = 'Ready' AND Study_Session__c = null GROUP BY Cert__r.Name ORDER BY COUNT(Id) DESC LIMIT 30`); running/failed top-ups (`SELECT Name, Top_Up_Started_At__c, Last_Failure_At__c FROM Cert__c WHERE Top_Up_Started_At__c != null OR Last_Failure_At__c != null`); usage (`SELECT User_Key__c, COUNT(Id) FROM Study_Session__c WHERE User_Key__c != 'system-warmup' GROUP BY User_Key__c`). Run `sf` from `salesforce/`. Test only our classes (`CertStudyTest`, `CertStudyControllerTest`, `CertStudySelfRegHandlerTest`, `CertStudyLoginDiscoveryHandlerTest`).

### Hosting status (Nov 2, paused mid-test; details below)

**Deployed and tested (33/33 of our tests pass):**
- Generation decoupled from learners: `Cert_Study_TopUp__e` event + `CertStudyTopUpTrigger` + `CertStudyPoolJob.requestTopUpAsync` (event publish; direct fallback if the publish fails and in tests). `CertStudyService` learner paths use it; the hourly scheduler still calls `requestTopUp` directly. Verified: generation runs from the event. Jobs run as **Automated Process**, not the PlatformEventSubscriberConfig user (config deployed, trigger redeployed, no effect). Accepted: learners are decoupled either way.
- `CertStudySelfRegHandler` (Auth.ConfigurableSelfRegHandler): only exact name@salesforce.com; hidden username `email + .certstudy` (usernames are unique across ALL orgs; employee emails likely taken elsewhere, e.g. Org62); assigns **`CertStudy_External`** via @future.
- **`CertStudy_External`** perm set (controller class + event create only). The first version assigned `CertStudy_User`, which failed ("user license doesn't allow Assigned Apps") because it carries app/tab visibility; `CertStudy_User` stays for internal users.
- `CertStudyLoginDiscoveryHandler` (Auth.LoginDiscoveryHandler): learners type only their email, get an email one-time code (`Site.passwordlessLogin`); matches only active `.certstudy` users, so an internal user with the same email never matches. **Deployed, NOT yet configured on the site or tried.**

**Site (manual, in the org):** LWR site "Salesforce Cert Study", URL `https://trailsignup-5d9fea1e5cdf7f.my.site.com/sfcertstudy`, **published** (check; it was about to be). Public access off. `certStudy` is on Home. Administration > Login & Registration: self-registration on, Configurable Self-Reg Page, handler `CertStudySelfRegHandler`, executes as Daniel Halle, email verification, include password, profile **External Apps Login User** (a member of the site), account "Cert Study Learners". Account created.

**Test results so far:** a non-logged-in visitor can't get in; self-registration form works and sends the verification email. Registered user `daniel.halle@salesforce.com.certstudy` hit "The Apex request is invalid" (no class access, perm set assignment had failed). Fixed by `CertStudy_External` + `scripts/assign_external_permset.apex` (assigned to that user, succeeded). **Not yet re-tested after the fix.**

**Update (Nov 3):** site is reachable at `https://trailsignup-5d9fea1e5cdf7f.my.site.com/sfcertstudy` (NOT the lightning.force.com URL). Status was still "Preview" (needs **Activate**; untick Emails > "Send welcome email" first, the SDO has 11 internal members). Login Discovery configured and WORKS (email only, one-time code). The cert list was empty for the external user because `CertStudyController` is `with sharing` and `Cert__c`/`Answer__c` are Private for externals; moved those queries into the without-sharing `CertStudyService` (`usableCerts`, `answerCounts`). Needs deploy + retest. Other controller paths go through the service and are probably fine, but verify start session, answering, My progress, test mode.

**Verified Nov 3 (external user on the site):** email-only login, cert list, practice mode and test mode work after the sharing fix. 33/33 of our tests pass. Cosmetic: cert list rows had extra spacing on the LWR site; tightened with `.cert-row` CSS (best effort, check on the site). Still to check: My progress, that questions actually generate for an external user (platform event path), Activate the site (Preview now), second user + non-@salesforce rejection test, sign-up link prominence, remove "Are you an employee? Log in" link, ask #q-branch-sdo.

**Verified Nov 3 (later):** question generation, My progress, second user (`+cert1`) provisioning/login, non-@salesforce and unregistered emails all fail as intended (but silently: page just resets). Login handler now throws `Auth.DiscoveryCustomErrorException` to show a message (needs deploy + retest); the registration rejection message is still not shown (unknown whether the configurable self-reg form can display handler errors). Site Activate done. Open: remove "Are you an employee? Log in" and enlarge the sign-up link in Builder (Login page), republish; commit and push; ask #q-branch-sdo.

**Login page (Nov 3):** live page is the standard Login Discovery page ("Phone or Email", small "Sign Up" link). It also shows a "Salesforce Trial Org Request & Manage employee? Log In" link; it can't be removed because Salesforce requires one login option, and it is accepted as harmless (leads to the internal org login). Builder's Login Form is not used by the discovery page.

**Backup (Nov 3):** `salesforce/scripts/backup_org.sh` (bulk-exports content + history to `backups/DATE/`) and `scripts/restore_from_backup.py` (builds load-ready CSVs for an empty org, matched by cert code, prints the sf commands). Backup run against the org on Nov 3 (88 certs, 35 prerequisites, 172 resources, 361 questions, 14 sessions, 35 answers); the restore script's dry run reproduces all four content counts with nothing skipped. The actual load into a fresh org has not been tested. See salesforce/README.md.

**Short link (Nov 3):** an internal shortener link, https://sfdc.co/sfcertstudy, was created for https://trailsignup-5d9fea1e5cdf7f.my.site.com/sfcertstudy but its redirect never completes (the interstitial's "continue" does nothing; the long URL works fine). DEFERRED: share the long URL for now; revisit with a different shortener, or a proper domain once this moves to a permanent prod site.

**Pool warm-up (Nov 3):** pools only top up for certs on an ACTIVE session (target 5 Ready per cert, 10 while a Test session needs it), so a cold cert makes the first learner wait. `scripts/warm_pools.apex` creates throwaway `system-warmup` sessions (13 certs per session, MAX_CERTS per run) and starts top-ups; the scheduler ends them after 24h idle. Cost is up to 5 model calls per cert; Einstein credit limits unknown, so warm in batches. Not run yet; verify with the Ready-per-cert query. A permanent "initial load across all certs" protocol is still undecided.

**Generation burst failure (Nov 3, 14:48 UTC):** a session on 11 cold certs started 11 chains at once; every model call failed ("Callout failed for LLM Gateway Standard ... createGenerations ... unexpected error") and all chains burned 5/5 attempts in seconds and gave up. A single model call (`scripts/modeltest.apex`) worked an hour later, so it was a burst or brief outage. Fix written (NOT yet deployed/tested): `CertStudyPoolJob` caps concurrent chains at 3 (`maxConcurrent`), a finished chain starts the next waiting cert, a failed model call retries via a delayed job (1 min) instead of immediately, and a cert that gives up gets `Last_Failure_At__c` and a 10-minute cooldown. New field `Cert__c.Last_Failure_At__c`; 4 new tests. Watch for: whether `AsyncOptions.MinimumQueueableDelayInMinutes` behaves in this org.

**Contributions and suggestions (design agreed Nov 3; BUILD AFTER THE TESTER ROUND, not before):**
- Anyone logged in can submit; nothing touches the live data. Admins review first.
- Two forms, reachable from links on the home screen and the results/summary pages of the `certStudy` LWC: (1) **Contribute study material**: cert, title, a link and/or pasted text, notes. "Link to a hosted file" means a URL to a file hosted elsewhere (Drive, Quip, Slack, etc.) that the admin can open; there is NO file upload in v1. (2) **Suggestion for improvement**: free text, optional category.
- One new object, e.g. `Contribution__c` (Type: Material / Suggestion; Cert lookup; Title; URL; Content long text; Notes; Status New/Approved/Rejected/Applied; Submitted By user + email; Reviewer, Reviewed At, Reviewer Notes). Private to admins; contributors get create-only via the Apex controller (system mode), with length limits, simple per-user rate limiting, and no read access to others' submissions. External users must not be able to see the object.
- **Approval:** setting Status = Approved on a Material submission (with a cert and content) auto-creates a `Cert_Resource__c` (role Additional) on that cert; the submitted text is untrusted and goes into model grounding, which is why review comes first. Link-only submissions have no pasted content, so they stay for manual handling.
- **Notification:** a once-a-day digest email (scheduled Apex) to admins, listing all submissions still New; no email when there are none. Include age, and flag anything older than 48h (stated SLA: reviewed within 48 hours; say so on the forms). Admins = users with the `CertStudy_Admin` permission set. Also add a tab with a "New submissions" list view. Digest time: ~3pm PT (scheduled Apex runs in the scheduling user's time zone; confirm Daniel's user time zone is Pacific when building).
- **Replies to submitters:** the check-off IS the Status field. When a reviewer sets Approved/Rejected (with optional Reviewer Notes), an automatic thank-you/decision email goes to the submitter; no separate tracking needed. Needs an email-limit check and a sender address.

**Release log / "What's new" (requested Nov 3; build AFTER today's testing, together with the contribution forms):**
- A "What's new" link beside the Contribute / Suggest links on the home and results screens, opening a simple list of entries, newest first, in two groups: **Recently released** and **Coming soon**.
- Backing object `Release_Note__c`: Title, Date, Type (Released / Planned), Body (short rich/plain text), Published checkbox. Admins write entries as ordinary records, and only Published ones are shown (read via the controller, in system mode), so updating it needs no code change and no site republish.
- Seed the first entries from what has actually shipped: email login, practice and test modes, progress history, generation resilience, etc.; "Coming soon" can show the contribution forms, exam status (retiring certs), and "My certifications".
- Link approved suggestions to release notes when they ship (a "Shipped in" note on the submission), which closes the loop for contributors.

**Future ideas (not scheduled):**
1. *Exam status.* Add a status on `Cert__c` (Active / Retiring / Retired / Renamed, plus an end date) and show it in the picker. Researched Nov 3: Salesforce announced 24 certifications retiring Feb 1, 2027 and 16 renames (effective July 24, 2026); registration for retiring exams closed July 24, 2026 and the last sitting date was Aug 31, 2026, so they can no longer be taken. Many "Accredited Professional" credentials are affected. No official machine-readable catalog/feed was found, so v1 = a manual import from Salesforce's "2027 Certification Retirements FAQ" and the certification overview page, not automation. Compare our 88 certs against that list.
2. *Completed certs.* Salesforce says it offers no public API for a person's certifications (data privacy); the verification page and Trailblazer profile show them only if the person opts in, with no official programmatic access. Scraping profiles or using unofficial third-party services is not recommended. Preferred design: a self-reported "My certifications" checklist per learner (stored against their user, optional paste/CSV), used to filter or recommend next certs. No integration, no scraping.

**Demo polish (Nov 3, first tester feedback: several people could not find Sign Up and looped on the login page):** `certStudy` now has a Salesforce-blue banner (navy/blue/cloud gradient, no logos or mascots), a Pilot + version chip (`APP_VERSION` in `certStudy.js`; bump it every release) and a footer with version, date, owner name/email (mailto) and a disclaimer (AI-generated, not official exam content). The login handler's not-found message now says to click Sign Up. NOT yet deployed. The standard Login Discovery page's small "Sign Up" link is still the weak spot; options to evaluate: (a) a public landing page with big "Sign up" / "Log in" buttons before the login (needs per-page access control in the LWR site), (b) branding/CSS on the discovery page, (c) just telling people in the invite. Also: certs on the retirement lists (e.g. B2B Solution Architect, some Marketing Cloud Accredited Professional credentials) appear in the picker; consider exam status sooner than planned before senior demos.

**Next steps, in order:**
1. Reload the site as the registered user (incognito): the cert list should load. Start a practice session, answer a question, open My progress. If no questions arrive, check `AsyncApexJob` for `CertStudyPoolJob` (and `Last_Generation_Error__c` on the cert).
2. Administration > Login & Registration: set **Login Page Type** to the Login Discovery option, handler `CertStudyLoginDiscoveryHandler`, Execute As Daniel. If the option is missing for LWR in this release, fall back to username (email + `.certstudy`) login or revisit. Unknown: passwordless email login may need a verified email on the user.
3. Log out and log in with just the email. Also test a non-@salesforce.com registration (must be rejected, no user/contact created) and a second user (e.g. `daniel.halle+cert@salesforce.com`) to confirm two users stay separate.
4. Verify email verification happens BEFORE the handler runs (otherwise add a check in the handler).
5. Polish: make the Sign Up link more prominent on the login page.
6. Ask in #q-branch-sdo whether a persisting SDO may host this; call it a pilot. Back up the data (CSV export + rebuild script).

**Gotchas:** `RunLocalTests` fails ~27% on pre-installed SDO/B2B tests, so always run only our classes: `--class-names CertStudyTest --class-names CertStudyControllerTest --class-names CertStudySelfRegHandlerTest --class-names CertStudyLoginDiscoveryHandlerTest`. Run `sf` from the `salesforce/` folder (the DX project root), not the repo root. Every Apex class needs its `-meta.xml`. `scripts/` is `.forceignore`d.

## Local Environment Notes (retired Heroku build — read before touching git or pip)

- **Clone into `$TMPDIR`, not the default working directory** — `.git`
  writes fail elsewhere in this sandbox. The exact command is in the
  resume prompt below; use it literally, do not paraphrase it.
- **Never run a broad recursive listing or search from this
  directory** (`ls -R`, `find .`, `grep -r .`, etc.) — `.venv` alone
  contains 5000+ installed-package files. One such command dumps a
  massive listing into context in one shot and can single-handedly
  cause repeated autocompact thrashing (context refills to the limit
  within a couple of turns of every compact). Only read specific,
  named files with their full absolute path. Relatedly: the
  Read/Write/Edit tools need an **absolute** path — a Bash `cd` does
  not carry over to them, so `Read("PLAN.md")` right after cloning
  will fail; use the full path (e.g. from `pwd` right after cloning).
- **Local venv setup** (`pip install -r requirements.txt` used to fail
  here on `psycopg2-binary` trying to compile from source -- now
  installs cleanly from a prebuilt wheel, see HISTORY.md):
  ```bash
  cd "$TMPDIR/SalesforceCertStudy"
  python3 -m venv .venv && source .venv/bin/activate
  pip install -r requirements.txt
  ```
- **Ingestion (Tier-1 auto-fetch) needs two more things, deliberately
  NOT in `requirements.txt`:**
  ```bash
  pip install playwright trafilatura
  playwright install chromium
  ```
  These are local-only: ingestion currently only ever runs via the
  local `app.py` workaround (see Locked-in decisions), and a real
  headless-browser dependency can't build/run on a standard Heroku
  dyno anyway (no prebuilt `greenlet` wheel on Heroku's build image,
  and no Chromium binary available without a dedicated buildpack --
  see HISTORY.md). Putting them in `requirements.txt` breaks the
  Heroku build; keep them as a separate local install step.
- **Real internal-gateway calls need**, exported in the same terminal
  session: `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL` (no `/bedrock`
  suffix), `SALESFORCE_CA_BUNDLE=./salesforce-ca-bundle.pem` (re-export
  via `security find-certificate -a -p
  /Library/Keychains/System.keychain > salesforce-ca-bundle.pem` after
  any reboot).
- **`.env`** (gitignored) with `FLASK_SECRET_KEY`,
  `APP_LOGIN_USERNAME`/`APP_LOGIN_PASSWORD`, `DATABASE_URL=` (blank,
  sqlite fallback) — `app.py` loads it via `python-dotenv`. **Check for
  it with `test -f .env`, never `ls`/`find`** — the exact command is
  below; use it literally, do not improvise a check:
  ```bash
  cd "$TMPDIR/SalesforceCertStudy"
  test -f .env || cat > .env <<'EOF'
  FLASK_SECRET_KEY=dev-local-secret
  APP_LOGIN_USERNAME=admin
  APP_LOGIN_PASSWORD=changeme
  DATABASE_URL=
  EOF
  ```
- **`git push` needs the user's own terminal** — the assistant commits
  locally, the user pushes. **Verify every push landed** with `git
  ls-remote <repo-url> HEAD` (cache-proof) immediately after, before
  assuming a fresh session will see it. Skipping this once cost a full
  rewrite of two phases' work — see HISTORY.md.
- **`$TMPDIR` does not survive a reboot.** Re-clone, rebuild the venv,
  and re-export the CA bundle after any reboot. The repo is the
  durable copy; `$TMPDIR` is not.

## Context

A personal 3-week practice-exam tool for two Salesforce certs
(Agentforce Specialist AI-201, Data 360 Consultant Data-Con-101). Core
design goal: **question generation never happens in the user's
request path** — a background `worker` pre-generates questions +
full-detail feedback into Postgres; the `web` app only ever serves an
already-`ready` row. Long-form feedback (why the correct answer is
correct, why each wrong option is wrong) is a hard requirement, not
something to shorten for speed.

Target repo: **https://github.com/DHalleTableau/SalesforceCertStudy**.

### Locked-in decisions

- **Cert data → 2-tab Google Sheet, ingested by paste** (not live
  fetch — the org's sharing policy blocks anonymous access).
  **Exam Guides** tab → `resources` rows (`Base`/`Extra` →
  primary/additional role) + `Cert.is_aggregate`/URLs.
  **Certification Prerequisites** tab → `cert_prerequisites` edges
  (PreReq1-N columns, any number supported).
- **Aggregate vs. prerequisite session-setup:** an aggregate cert has
  no exam of its own — selecting it auto-includes its full
  prerequisite tree with no prompt. A non-aggregate cert with 1+
  prerequisites prompts at each non-aggregate level walked, auto-
  descending silently through any aggregate nodes. Implemented in
  `cert_resolution.py`.
- **Auth/hosting:** internal Salesforce employees only for now,
  eventually any Salesforce employee (org-wide) — this was the
  original intent, not scope creep; no data-model change needed for
  multi-user since everything already keys off `session_id`. Hosting
  is fixed at Heroku Enterprise, team **`se-smb`**
  (`dashboard.heroku.com/teams/se-smb`), not a personal account, and
  not changing.
- **Claude access is internal-gateway-only — resolved.** The gateway
  is a unified multi-provider proxy speaking the **OpenAI Chat
  Completions API** for every model (confirmed via `GET
  {base_url}/v1/models` — Claude/GPT/Gemini all listed as `"owned_by":
  "openai"`), NOT Anthropic's native format, even for Claude models.
  Use the `openai` package: `OpenAI(api_key=<ANTHROPIC_AUTH_TOKEN>,
  base_url=<ANTHROPIC_BASE_URL>,
  http_client=httpx.Client(verify=<SALESFORCE_CA_BUNDLE>))`, OpenAI-
  style function-calling (`response.choices[0].message.tool_calls[0]
  .function.arguments`, a JSON string). `claude-sonnet-5` (or
  `CLAUDE_MODEL` env var override) is a valid model ID on this
  gateway. **Known structured-output flakiness, already mitigated**
  in `claude_client.py`/`worker.py`: flat parallel arrays instead of
  nested array-of-objects in tool schemas, `minItems`/`maxItems` set
  structurally not just in prose, trailing tool-call-artifact
  stripping on long text fields, validate+retry. Full debugging story
  in HISTORY.md if this resurfaces in a new form.
  - **Confirmed BLOCKED (Phase 5's first check):** the deployed
    `worker` dyno cannot reach the gateway — `heroku run` from inside
    `sf-cert-study` gets `httpx.ConnectTimeout` (TCP-level, not
    auth/TLS/4xx), meaning the gateway is unreachable from Heroku's
    network entirely, almost certainly because it's locked to
    Salesforce's internal network the same way the deployed app itself
    needed VPN + a Trusted IP Range to be reachable. Unresolved as of
    now — needs either a Private Space peering connection to
    Salesforce's internal network, an IP allowlist on the gateway's
    side for Heroku's outbound IPs, or a different access pattern
    entirely. See HISTORY.md for the full diagnostic chain.
- **Worker model:** on-demand top-up only (queue < 5 ready AND a
  session is active; idle otherwise).
- **Review export:** CSV download + in-app filterable screen.

## Architecture Overview

Two Heroku process types sharing one Postgres database:
- **`web`** (Flask) — login, session setup, question UI, review/
  export. Never calls the Claude API in a request.
- **`worker`** — while a session is active and a cert's queue has
  fewer than ~5 `ready` rows, calls the model and inserts a row. Idle
  when queues are full or no session is active.

```
User → web (Flask) → Postgres queue  ← worker → Claude API
                         ↑ serves instantly        ↑ fills ahead of demand
```

## Data Model (Postgres) — all implemented in `models.py`

- **`resources`** `(id, cert_code, url, role, fetch_status,
  fetched_text, pasted_text)` — `pasted_text` is what actually matters
  in practice (Tier-1 fetch rarely works on real sources; see
  HISTORY.md).
- **`certs`** `(cert_code, name, detail_page_url, exam_guide_url,
  is_aggregate, duration_min, num_questions, passing_score,
  domains_json)`.
- **`cert_prerequisites`** `(id, cert_code, prereq_cert_code)` — direct
  edges only; resolved recursively in `cert_resolution.py`.
- **`sessions`** `(id, user_label, cert_codes, started_at, status)` —
  `cert_codes` is the fully resolved set (post aggregate/prerequisite
  walk).
- **`question_queue`** `(id, session_id, cert_code, domain,
  difficulty, format, stem, options_json, correct_json, feedback_md,
  status)` — `format ∈ {single, multi}`; `status` moves ready → served
  → answered.
- **`answers`** `(id, session_id, question_id, user_answer_json,
  is_correct, answered_at)`.

## Resource Ingestion

Both sheet tabs are paste-only (`ingest.py`). Tier-1 auto-fetches
individual Exam_Guide_URL content pages; Tier-2 is a per-resource
paste fallback for blocked/JS-rendered ones. Primary (Base) sources
weighted most heavily in grounding (ordering + labeling in the prompt,
not a numeric scheme — see `claude_client.assemble_grounding_text`).

**Run bulk CSV ingest locally, not against the deployed app.**
Tier-1 auto-fetch (`playwright`) is deliberately excluded from
`requirements.txt` — no prebuilt wheel on Heroku's build image, and no
Chromium binary on a dyno anyway (see HISTORY.md). `fetch_pending_resources`
detects this and no-ops instead of crashing, but that means running
`/admin/ingest` against the *deployed* app never auto-fetches anything —
every new resource sits at `fetch_status="pending"` forever, needing a
manual paste. For a handful of resources that's fine; for dozens at
once (adding several new certs) it doesn't scale.

Instead, for any bulk CSV ingest, run `app.py` locally pointed at the
production database, so playwright is actually available:

```bash
source .venv/bin/activate
export DATABASE_URL=$(heroku config:get DATABASE_URL -a sf-cert-study)
export FLASK_SECRET_KEY=dev-only-not-secure
export ADMIN_LOGIN_USERNAME=<admin username>
export ADMIN_LOGIN_PASSWORD=<admin password>
python3 app.py
```

Then paste the CSVs into `http://localhost:5000/admin/ingest` — same
production DB, but this time Tier-1 actually runs, so only genuinely
blocked/JS-rendered pages need a manual paste afterward (on either the
local or deployed admin ingest page — the paste box now shows for any
resource missing content, not just ones already marked
`blocked_needs_paste`).

The admin ingest page also flags any cert with zero resources carrying
real content (pasted or fetched) right after ingest, so this can't go
silently unnoticed the way it did before — previously a cert with no
usable grounding text just made the worker generate nothing for it,
forever, with no error anywhere (see HISTORY.md).

## Cert Overview Derivation

`claude_client.derive_cert_overview`: on first use, the worker derives
duration/# questions/passing score/domain weights from a cert's
primary Exam Guide text and caches them on the `Cert` row.

## Question Generation (worker)

`claude_client.generate_question`: cert + weak-domain target (deferred
— currently `domain=None`, model chooses from grounding) + ramping
difficulty + format (single 1-of-4 / multi 2-3-of-5, all-or-nothing
grading) + primary-weighted grounding excerpts → structured question
+ long-form feedback. Inserted into `question_queue` as `ready`.

## User Flow

1. Login (simple, internal-only for now).
2. Session setup — pick cert(s), resolve aggregate/prerequisites,
   create `StudySession`.
3. Overview — derived duration/questions/passing score/domains per
   resolved cert.
4. Question loop — serve next `ready` instantly; grade on answer
   (multi all-or-nothing); show feedback + the next already-ready
   question together in one response.
5. Review/export — filterable (right/wrong/both) + CSV download.

## Files

`app.py` (web routes), `worker.py` (top-up loop), `claude_client.py`
(model calls + grounding assembly), `models.py`, `ingest.py`,
`cert_resolution.py`, `auth.py`, `templates/`, `Procfile`,
`requirements.txt`, `.python-version`, `.env.example`, `.gitignore`.

## Secrets & Config

Heroku config vars only, never committed (repo is public):
`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_BASE_URL` (or `ANTHROPIC_API_KEY`),
`SALESFORCE_CA_BUNDLE` (as a Heroku config var pointing at a bundled
file, or the PEM content directly — TBD in Phase 5), `DATABASE_URL`
(Heroku sets automatically), `FLASK_SECRET_KEY`,
`APP_LOGIN_USERNAME`/`APP_LOGIN_PASSWORD`.

## Phased Implementation

One **phase** per fresh chat session — stay in the SAME session across
a phase's sub-steps, only start a new session for a new phase. Use
**Sonnet** for implementation; reserve Opus for genuinely hard
sub-problems.

**Starting a new phase's session — use this exact block, do not
paraphrase it** (see HISTORY.md for why this has to be the literal
command, not a pointer to where it's documented):

```
Run this first, exactly as written:
cd "$TMPDIR" && git clone https://github.com/DHalleTableau/SalesforceCertStudy.git ; cd SalesforceCertStudy && pwd

The Read/Write/Edit tools need an ABSOLUTE path -- Bash's cd does NOT
carry over to them. Take the absolute path printed by pwd above and
use it for every file read from here on: read <that path>/PLAN.md and
<that path>/README.md in full (a relative Read("PLAN.md") will fail).

Do NOT run any recursive directory listing or search (ls -R, find .,
grep -r) from this directory. .venv alone contains 5000+ installed-
package files -- one such command will dump a massive listing into
context and can single-handedly cause repeated autocompact thrashing.
Only read specific, named files with their full absolute path.

Then set up the venv per Local Environment Notes' exact pip install line
(not -r requirements.txt).

Then run the .env command from Local Environment Notes' `.env` bullet
literally -- do NOT check for it with ls/find, only `test -f .env`. That
bullet has the exact command; use it verbatim, do not improvise a check.

Then resume from the Current progress note below.
```

**Current progress (update every time a sub-step finishes or is left
mid-way):** Phase 4 **complete**. Phase 5 **partially blocked, but the
app is actually usable right now via a workaround.** Deployed to
Heroku (`sf-cert-study`, team `se-smb`, space `se-smb-internal`) with
Postgres attached -- app.py and worker.py both run correctly against
it. Two separate, still-open blockers, both needing someone outside
this app to act:
- **Web access:** the deployed app's public URL 403s until an admin
  adds your VPN IP to the space's Trusted IP Ranges (you don't have
  the role to do this yourself). Ask a `se-smb` team admin.
- **Gateway access:** the Heroku `worker` dyno cannot reach the
  internal Claude gateway at all (`ConnectTimeout` -- confirmed no
  supported path exists yet, escalated to #community-claude-code).
**Interim workaround (verified working end-to-end):** run `app.py` AND
`worker.py` locally, both pointed at the deployed Heroku Postgres via
`DATABASE_URL` (reachable from your Mac over VPN even though the app's
HTTP routing isn't) -- full question loop confirmed working against
real production data and real generated questions. See HISTORY.md's
Phase 5 section for the full blocker list and the exact commands.
Next: 4g's CSV export is untested against production data; otherwise
wait on the two escalations above before revisiting a fully-hosted
deploy.

1. **Skeleton + data model.** **[Done]**
2. **Ingestion** (`ingest.py`, admin screen). **[Done: 2a-2g]** —
   real-data finding: Tier-1 auto-fetch got 0/84 on the real sheet
   (JS-rendered pages); `pasted_text` is what actually matters (see
   HISTORY.md).
3. **Worker + question generation** (`claude_client.py`, `worker.py`).
   **[Done: 3a-3d]** — see Locked-in decisions above for the gateway
   protocol/schema-reliability facts.
4. **Question UI + review/export.** Sub-steps:
   - 4a. Login (`auth.py`). **[Done]**
   - 4b. Aggregate/prerequisite resolution (`cert_resolution.py`).
     **[Done]**
   - 4c. Session setup route (`/session/setup`). **[Done]**
   - 4d. Overview route (`/session/<id>/overview`). **[Done]**
   - 4e. Question loop (`/session/<id>/question`,
     `/session/<id>/answer`). **[Done]**
   - 4f. Review screen (`/session/<id>/review?filter=...`). **[Done]**
   - 4g. CSV export (`/session/<id>/export.csv`). **[Done]**
5. **Deploy.** **First check, before anything else in this phase:**
   confirm the deployed `worker` dyno can actually reach the internal
   Claude gateway (e.g. a one-off `heroku run` hitting it) — unverified
   until tested against the real Heroku Enterprise org; if it can't
   reach it, the rest of this phase is blocked on resolving that first.

Each phase ends with a commit to `main` so the next phase's fresh
session starts from a known, working state.

## Verification (end-to-end)

1. **Local:** Postgres + `flask run` + `python worker.py`; queue fills
   to ~5 `ready` before answering.
2. **Latency:** next question + feedback appear with no model call in
   the request (the served row was already `ready`).
3. **Ingestion:** paste both tabs, confirm roles/edges/aggregate flags
   match the sheet (including a multi-level chain); a blocked URL gets
   flagged for paste.
4. **Grading:** multi is all-or-nothing; difficulty ramps over a run.
5. **Prerequisite/aggregate walk:** aggregate certs auto-include
   silently; non-aggregate certs prompt per level.
6. **Export:** downloaded CSV matches the review screen's filter.
7. **Deploy:** push, set config vars, scale `web=1 worker=1`, repeat
   checks 2-6 in prod behind the internal-only login.
