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

### >>> PICK UP HERE (written end of day Nov 3; plan for Nov 4) <<<

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

**Post-release idea (added Nov 4): internal SSO login.** After a user has signed up, let them log in with Salesforce's internal SSO (used for many internal tools) instead of waiting for an emailed verification code. Configuration to be worked out later. Starting points to evaluate: an Experience Cloud SAML or OpenID Connect authentication provider added to the site's login options, and matching the SSO identity to the existing external user by email (the self-registration and Login Discovery handlers already key on the @salesforce.com email). Open questions: whether an external-identity SSO app can be registered for a trial org/pilot, who approves it (IT/security), and whether the email-code path stays as a fallback. Do not promise this in the demo.

**Nov 5: per-question "Report a problem" BUILT (not deployed), version v0.11.0.** `Question_Report__c` (Question, Cert, Reporter, Issue_Type__c, Comment__c, Status__c New/Reviewing/Fixed/Dismissed, Reported_At__c, Reviewer_Notes__c; Private; admin perm set only), `CertStudyService.reportQuestion` (own-session check, 20/hour limit, repeat report on the same question updates the open one), `CertStudyController.reportQuestion`, a "Report a problem with this question" link + inline form on the question and feedback views, test `questionReportsAreValidatedScopedAndDeduplicated`. **Nov 5 follow-ups:** UI labels renamed to "Question Issue(s)" / "Issue #" (API names unchanged, still `Question_Report__c`) to avoid confusion with Salesforce Reports; page layout added (overwrites the auto-generated "Question Report Layout"); a repeat report by the same learner on the same open issue is now APPENDED to Comment__c (timestamped "follow-up: <type>" entry, original type/text kept; Comment__c raised to 32,768). Report renamed "Question Issues by Cert and Type".

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
