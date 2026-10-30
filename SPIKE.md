# Salesforce-Native Hosting Spike

Goal: in ~1 day, in an admin-owned org with no PII/customer data, prove or
kill the two assumptions the Salesforce-native redesign depends on. No data
migration until both pass.

Context: Heroku can't reach the internal Claude gateway (see HISTORY.md,
Phase 5), so generation, state, and UI move into Salesforce. Target shape:
Prompt Template generates -> custom objects hold the queue/state -> Agentforce
(or Flow-backed Slack app) serves and grades -> Data 360 holds exam-guide
corpus + analytics.

**Status:** Steps 1-3 are built as an SFDX project in `salesforce/`. Deploy,
data-load and Agent Builder steps are in `salesforce/README.md`. The interface
for now is Agent Builder preview, then the Slack demo org with testers added as
users there. Internal Slack comes later.

## Pass/fail questions

| # | Question | Pass | Fail fallback |
|---|----------|------|---------------|
| Q1 | Can a Prompt Template return valid structured question JSON with long-form feedback, reliably? | >=9/10 generations valid after Apex validation, <=1 retry each | Split into two calls (question+options+answer, then feedback); or smaller schema |
| Q2 | Can a Slack user with NO user in this org interact with the tool? | Any non-provisioned test user can start a session, get a question, answer, see feedback | Slack app/workflow calling Flow via a single integration user, identity = Slack user ID/email |
| Q3 | Does an agent/Flow turn read + grade without an LLM call, keeping consumption to background generation only? | Serve + grade turns show zero model usage | Move grading fully into Flow/Apex invoked by the agent |
| Q4 | Can Slack render single (buttons) and multi (checkboxes/typed) answers? | Both workable | Typed answers ("B+D") |

## Steps

### 0. Prep (30 min)
- Confirm org has: Agentforce, Prompt Builder, Data 360, Slack integration
  enabled. Note edition and credit allocation (answers the cost question).
- Create 2 test users: A = licensed in the org, B = NOT a user in the org
  (a coworker's Slack account works).
- Create a test Slack channel / app install target.

### 1. Objects (1 hr) - mirror models.py
- `Cert__c`: cert_code (external ID), name, is_aggregate, domains_json (LTA)
- `Cert_Prereq__c`: cert (lookup), prereq (lookup)
- `Study_Session__c`: user_key (Slack ID/email), cert_codes (LTA), status
- `Question_Queue__c`: cert_code, domain, difficulty, format, stem (LTA),
  options_json (LTA), correct_json, feedback_md (LTA), status
  (ready/served/answered), session (lookup, nullable - shared per-cert pool,
  as in current design), served_at
- `Answer__c`: session, question, user_answer_json, is_correct, answered_at
- Load 2 certs (AI-201, Data-Con-101) + their prereq edges via Data Loader/CSV.

### 2. Q1: generation (3 hrs)
- Put one cert's primary exam-guide text into a custom field or Static
  Resource (spike only; production uses a Data 360 search index).
- Build Flex Prompt Template: inputs = cert name, domain (optional),
  difficulty 1-5, format (single/multi), grounding text. Output = JSON.
- Port the proven schema rules from `claude_client.py`: flat parallel arrays
  (option_keys[], option_texts[]), explicit option counts (single=4,
  multi=5 with 2-3 correct), strip trailing artifacts, validate.
- Apex `QuestionGenerator` invocable: call template, parse, validate
  (counts, correct keys exist in options, feedback covers every option),
  retry up to 3x, insert `Question_Queue__c` status=ready.
- Run 10 generations (mix single/multi, difficulty 1/3/5). Record valid rate,
  retries, latency, credits used.

### 3. Q3/serving logic (2 hrs, Flow/Apex)
- Invocable actions: `StartSession(user_key, cert_codes)` (aggregate/prereq
  resolution - port `cert_resolution.py`), `GetNextQuestion(session)`
  (claim a ready row), `SubmitAnswer(session, question, answer)` (all-or-
  nothing grading, writes Answer__c, returns feedback_md).
- Scheduled Flow: top up each active cert's pool to 5 ready rows.

### 4. Q2/Q4: Slack access (2 hrs)
- Path 1: Agentforce agent with the three actions above, deployed to Slack.
  Test as user A, then user B (non-org user). Record exactly what B sees.
- Path 2 (if B is blocked): Slack app/workflow whose steps call the Flows
  via an integration user; key state on Slack user ID. Test as B.
- Test button/checkbox rendering for single and multi.

### 5. Readout (30 min)
Fill in the Pass/fail table, plus: generation cost per question, per-turn
consumption, who can use it, and the recommended path (agent vs
Flow-backed Slack app).

## After the spike (only if it passes)
1. Data 360: ingest `resources` text as a data stream; chunk + vector search
   index for grounding; semantic layer over answers for weak-domain scoring.
2. Export Postgres via `DATABASE_URL` (certs, prereqs, resources text) and
   load.
3. Weak-domain targeting from harmonized answers feeds the prompt.
4. Session-ending logic (currently never marks sessions ended).
5. Retire app.py/auth.py/Procfile/Heroku.

## Housekeeping flags
- Local folder is in sync with GitHub (HEAD 41e9333) - prompts/schema to
  port are in `claude_client.py` (latest: per-option explanations assembled
  server-side after shuffle, length-bias check, shorter stems).
- Contributions (admin piece, deferred): interim path = drop material into
  a Cowork session; Claude extracts text and loads it as `Resource__c` /
  Data 360 rows. Later: Slack form -> `Contribution__c` -> admin review.
  End-user experience comes first.
- Don't commit org credentials; repo is public.
