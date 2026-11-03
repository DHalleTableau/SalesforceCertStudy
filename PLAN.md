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

### Hosting status (Nov 2, paused mid-test; resume here)

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
