# Cert Study on Salesforce (spike build)

This replaces the Heroku `web` and `worker` processes with native Salesforce pieces:

- **Generation:** `CertStudyPoolJob`, a chained Queueable, calls the Einstein Models API. It does not use an external gateway.
- **State:** custom objects that mirror `models.py`.
- **Interface:** Agentforce actions. Agent Builder preview works now. Slack comes later through the Slack demo org.

The goal is unchanged: no model call ever happens in a learner's turn. Actions only claim pre-generated `Ready` rows and grade them in plain Apex. Generation runs in the background and fills a shared pool of 5 questions per cert. It only runs while some active session needs that cert.

| Old (Python) | New (Salesforce) |
|---|---|
| `models.py` tables | `Cert__c`, `Cert_Prerequisite__c`, `Cert_Resource__c`, `Study_Session__c`, `Question__c`, `Answer__c` |
| `claude_client.py` | `CertStudyGenerator` (prompts, parse, shuffle, validation) + `CertStudyLlm` (Models API) |
| `worker.py` | `CertStudyPoolJob` (top-up chain, per-cert lock) + `CertStudyScheduler` (hourly safety net, ends idle sessions) |
| `cert_resolution.py`, `app.py` routes | `CertStudyService` + 5 invocable actions (`CertStudy_*`) |

## ▶ Resume here (paused Nov 2, 2026, evening)

**Immediate next step:** smoke-test the in-org Lightning app; it's deployed but hasn't been opened yet.
1. App Launcher → **Cert Study**. An active agent-preview session may make it open on a question.
2. Answer by click and by keyboard, confirm the explanations stay until **Next question**, then check **Summary**.
3. Report anything off. Once it's good, build Test mode (spec below).

Older resume notes follow:

The backend is done and verified:
- deployed, 18/18 tests passing;
- data loaded;
- real question generation working;
- the hourly scheduler running.

Current work is the **Agentforce agent**. Start with **`AGENT_SETUP.md`**, which has the current state, builder gotchas, every Optimizer prompt and the retest script.

Before agent testing, make sure the latest Apex is deployed. It's harmless if it already is:

```bash
cd ~/Documents/SalesforceCertStudy/salesforce
sf org display --target-org certstudy | grep -E "Connected Status|Username"   # re-login if expired: see below
sf project deploy start --source-dir force-app --target-org certstudy | grep -E "Status: (Succeeded|Failed)|Error"
```

If the CLI session expired, log in again: `sf org login web --alias certstudy --instance-url https://trailsignup-5d9fea1e5cdf7f.my.salesforce.com`

**In-org app (Nov 2):** App Launcher → **Cert Study**. This is the `certStudy` LWC on the `Cert_Study` tab, backed by `CertStudyController`.
- It's the same sessions, question pool and grading as the agent, but the explanation stays on screen until **Next**.
- Keyboard: A–E to select, then Enter.
- No agent turns, so the only credit use is background generation.
- Users need the **Cert Study User** perm set and must be users in this org. Background generation runs as whoever triggered it, so learners also need Einstein generative AI access.

**Test mode (designed, not built yet):**
- One cert; the real exam's question count, drawn by domain weight.
- No feedback until the end.
- At the end: PASS/FAIL against the real passing score, per-domain breakdown, and review of misses.
- Ending early: unanswered questions count as wrong for the official score. A secondary score on the answered questions comes with per-section "likely would/wouldn't have passed" notes and focus recommendations.
- Timer: the learner chooses a strict timer (auto-ends) or open time (elapsed shown). Pause hides the current question until they resume.

**Handy one-line scripts** (in `scripts/`; run with `sf apex run --file scripts/<name>.apex --target-org certstudy`):
- `modeltest.apex`: model reachable?
- `gentest.apex`: start generation on a cert with no questions.
- `showquestion.apex` / `answergentest.apex`: view or answer the gentest user's question.
- `unlock.apex`: clear stuck generation locks and restart top-ups.

Run multi-line shell snippets one command at a time; pasted heredocs can hang the terminal.

**Queries for checking progress.** Filter by cert name, because a date filter also catches the 301 migrated questions:

```bash
sf data query --target-org certstudy -q "SELECT Name, Num_Questions__c, Passing_Score__c, Top_Up_Started_At__c, Last_Generation_Error__c FROM Cert__c WHERE Top_Up_Started_At__c != null OR Last_Generation_Error__c != null"
sf data query --target-org certstudy -q "SELECT User_Key__c, Status__c, CreatedDate FROM Study_Session__c ORDER BY CreatedDate DESC LIMIT 3"
```

**Data facts that shape the code:**
- In this data set, cert codes are the full cert names. They contain spaces, and one contains a colon.
- Sessions store cert record Ids in `Cert_Codes__c`, not names, to stay under 255 chars.
- The 2 aggregate certs are Application Architect and System Architect.

## 1. Deploy (about 10 minutes)

```bash
cd ~/Documents/SalesforceCertStudy/salesforce
sf org login web --alias certstudy          # log in to your org
sf project deploy start --source-dir force-app --target-org certstudy | grep -E "Status: (Succeeded|Failed)|Error"
```

Before deploying, check that the model name in `labels/CustomLabels.labels-meta.xml` (`CertStudy_Model`) exists in your org. Look under **Setup → Einstein Studio → Models** for the API name of the model you want, such as a Claude model. You can also change it after deploying under **Setup → Custom Labels**, with no redeploy.

## 2. Permissions

```bash
sf org assign permset --name CertStudy_Admin --target-org certstudy
```

- **Cert Study Admin** (you): full access to the data, tabs and classes.
- **Cert Study User** (learners): class access only. All data access happens in Apex system mode.
- Learners also need whatever permission set your org uses for Agentforce and Einstein generative AI, for example the agent's user access permission set. This is required because the background generation job runs as the learner who triggered it.

## 3. Load the existing data

Run this from the repo root with the venv active, on VPN:

```bash
export DATABASE_URL=$(heroku config:get DATABASE_URL -a sf-cert-study)
python salesforce/scripts/export_from_postgres.py --out salesforce/export

cd salesforce
sf data upsert bulk --sobject Cert__c              --file export/Cert__c.csv              --external-id Cert_Code__c --line-ending LF --wait 10 --target-org certstudy
sf data upsert bulk --sobject Cert_Prerequisite__c --file export/Cert_Prerequisite__c.csv --external-id Legacy_Id__c --line-ending LF --wait 10 --target-org certstudy
sf data upsert bulk --sobject Cert_Resource__c     --file export/Cert_Resource__c.csv     --external-id Legacy_Id__c --line-ending LF --wait 10 --target-org certstudy
sf data upsert bulk --sobject Question__c          --file export/Question__c.csv          --external-id Legacy_Id__c --line-ending LF --wait 10 --target-org certstudy
```

- The upserts are rerunnable, and the order matters (certs first).
- `Question__c.csv` re-pools every question already generated as `Ready`, so learners start with zero generation wait or cost. Use `--only-unused` if you don't want to see questions you've already answered.
- `salesforce/export/` is gitignored because it holds the full study corpus.
- Check the Cert tab afterwards. `Grounding Characters = 0` means that cert has no content and can't generate questions. This is the same warning the old admin ingest page gave.

Schedule the hourly maintenance job once, from Anonymous Apex (Developer Console):

```apex
CertStudyScheduler.scheduleHourly();
```

## 4. Create the agent (Agent Builder, about 15 minutes)

In **Setup → Agentforce Agents → New Agent**, create an employee-facing agent, for example "Cert Study Coach". Then add one topic:

**Topic name:** Certification Practice

**Classification description:** Practice exams for Salesforce certifications: finding a certification, starting a practice session, answering questions, getting the next question, and reviewing scores or weak areas.

**Scope:** Run practice-exam sessions for Salesforce certifications using only the provided actions. Do not write, invent, or answer exam questions yourself.

**Instructions** (add each as its own instruction):

1. Always show the Message returned by any Cert Study action to the user exactly as written, in full. Never summarize, shorten, reword, or add hints to it. Never reveal or guess the correct answer before the user answers.
2. When the user wants to practice a certification, call Find Certifications to get its exact code, confirm the certification with the user if more than one matches, then call Start Practice Session with that code.
3. If Start Practice Session returns a Message beginning with NEEDS_ANSWER (CODE), ask the user the yes/no question in it. Then call Start Practice Session again with the same Cert Codes and Prerequisite Answers set to CODE=yes or CODE=no. Include all earlier answers, separated by semicolons.
4. When the user replies with an option letter or letters (such as "B", "b and d", "A, C"), call Submit Practice Answer with exactly what they chose.
5. When the user asks for the next question, to skip ahead, or to see the current question again, call Get Next Practice Question.
6. When the user asks how they are doing, for their score, or for weak areas, call Practice Session Summary. When they say they are done, call it with End Session set to true.
7. Leave User Key blank on every action.

**Actions:** add the 5 Apex actions (Find Certifications, Start Practice Session, Get Next Practice Question, Submit Practice Answer, Practice Session Summary). For each action, mark the `Message` output as **Show in conversation** and leave inputs as collected from the conversation.

Activate the agent, then test in the **Agent Builder preview**:

- "I want to practice for the Agentforce Specialist exam"
- answer "B"
- "next question"
- "how am I doing?"
- "I'm done"

## 5. Spike readout (see ../SPIKE.md)

- **Q1 (generation quality):** after a session starts, watch the Question tab fill toward 5 `Ready` rows per cert. Rejections show in `Cert__c.Last_Generation_Error__c`. Open 10 questions and judge stem, option and feedback quality. Check your org's Einstein/Agentforce consumption page for credits per question.
- **Q3 (no LLM in learner turns):** serving and grading are plain Apex, so only `CertStudyPoolJob` consumes generation credits. The agent's own reasoning turns are still metered by Agentforce; note what one practice turn costs.
- **Q2/Q4 (Slack):** deploy the same agent to the Slack demo org and add testers as users there. Because actions key learners on email (`User Key`), moving later to a Slack-ID or internal-Slack setup needs no data change.

## Known limits / next

- **Grounding:** up to 60k characters per call, taken as a random window from the cert's resources. Production should move resource text into a Data 360 search index for retrieval.
- **Model output length:** the Models API default output limit might truncate long 5-option feedback. If `Last_Generation_Error__c` keeps showing "feedback too short" or parse failures, that's the cause. Fix it by picking a model with a larger output limit, or by splitting generation into two calls.
- **Chain depth:** Trial/Developer Edition orgs cap chained Queueables at depth 5. `CertStudyPoolJob` starts each chain with an explicit max of 5. At the cap it stops cleanly and schedules a one-off `Cert Study restart …` job about 1 minute out. The hourly scheduler and every question claim also restart stalled pools.
- **Not ported yet:** CSV export (the summary action covers review for now), the contributions queue, and weak-domain targeting.
- **Adding material for now:** give it to Claude in a session, or create a `Cert Resource` record on the cert, paste the text into Content, and set the Role.
