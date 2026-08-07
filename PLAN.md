# Salesforce Cert Study App — Architecture Plan

> This is the canonical, living plan for this project. It lives in the
> repo (not in a local `~/.claude/plans/` file) specifically so that any
> fresh chat session can pick up full context just by reading this file
> after cloning — no out-of-band file path needs to be remembered or
> passed along between sessions. When starting Phase N in a new
> session, say: *"Clone https://github.com/DHalleTableau/SalesforceCertStudy,
> read PLAN.md and README.md, then build Phase N."* Keep this file
> updated as decisions change; see README.md's Status checklist for
> which phases are done.

## Local Environment Notes (read before touching git or pip)

Rediscovering these burns real context every session — don't. Both were hit and worked around while building Phase 1:

- **Working checkout location:** writes to any directory literally named `.git` fail with `Operation not permitted` under `~/Documents/Claude` (a local sandbox restriction, not a real permissions problem on this Mac). `git clone`/`git init` there will fail. **Clone into `$TMPDIR` instead** (e.g. `cd "$TMPDIR" && git clone https://github.com/DHalleTableau/SalesforceCertStudy.git`) and do all work from there.
- **No PyPI access in the assistant's sandbox:** `pip install` fails with a proxy 403 — it cannot reach PyPI. This means the assistant **cannot** create a venv and run `pip install -r requirements.txt` to verify Flask/SQLAlchemy code actually runs. For:
  - **Pure-Python sub-steps that only use the standard library** (e.g. `parse_exam_guides_csv`, `parse_prerequisites_csv` — just the `csv` module) — verify with plain `python3` directly, no venv/pip needed at all. This covers most of the small sub-steps.
  - **Anything needing Flask/SQLAlchemy/psycopg2/anthropic** — the assistant can only static-check (`python3 -m py_compile`), not actually run it. Say so plainly rather than claiming it works; ask the user to run the real boot/verify command in their own terminal (where `pip install` works fine).
- **`git push` requires the user's own terminal.** The assistant has no GitHub push credentials in its sandboxed environment (`gh auth status` shows the keyring token isn't visible to it even after the user runs `gh auth login`). The assistant commits locally; the user runs `git push origin main` themselves. **Always confirm a push actually landed** (`git fetch origin && git log --oneline origin/main -3`, or `git ls-remote <repo-url> HEAD` for a cache-proof check) **immediately after every single commit, no exceptions.** This was violated once mid-build — pushes were handed off but not re-verified for a long stretch, then the user's machine rebooted and wiped `$TMPDIR` (see below), silently losing every unpushed commit (all of Phase 2's `ingest.py`, all of Phase 3's `claude_client.py`/`worker.py`). Recovered by rewriting the missing files from the assistant's own conversation context, but it cost real rework that a `git ls-remote` after each push would have caught for free.
- **`$TMPDIR` does not survive a reboot.** The whole working checkout (code, venv, installed packages, the exported CA bundle) lives under `$TMPDIR` per these notes, and a reboot wipes it completely. After any reboot: re-clone into `$TMPDIR`, recreate the venv and install deps (see the exact command below -- do NOT use `pip install -r requirements.txt` directly), and re-export the CA bundle (`security find-certificate -a -p /Library/Keychains/System.keychain > salesforce-ca-bundle.pem`). None of this matters if commits are actually pushed promptly (see above) — the repo is the durable copy, `$TMPDIR` is not.
- **`pip install -r requirements.txt` fails on this machine** — `psycopg2-binary` tries to compile against a local Postgres install (`pg_config`) that doesn't exist here. It's only needed for the real Heroku Postgres connection (Phase 5+); local dev always falls back to sqlite (see `app.py`'s `_database_url()`). **Use this instead, every time a fresh venv is created:**
  ```bash
  cd "$TMPDIR/SalesforceCertStudy"
  python3 -m venv .venv && source .venv/bin/activate
  pip install Flask Flask-SQLAlchemy SQLAlchemy openai requests python-dotenv
  ```
  This one line covers every local sub-step tested so far (Flask/SQLAlchemy for anything touching models, `openai` for the internal-gateway calls, `requests` for Tier-1 fetch, `python-dotenv` for reading `.env`). Forgetting one of these mid-session (discovering it only when a route 500s) has happened more than once and wastes a full request/response round-trip each time — install all five up front instead of one at a time as errors surface.
  - **Real internal-gateway calls also need**, exported in the same terminal session (lost on reboot or new terminal window, not just `$TMPDIR` — re-export every time): `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL` (the gateway URL, no `/bedrock` suffix), `SALESFORCE_CA_BUNDLE=./salesforce-ca-bundle.pem`. See Locked-in decisions for the full credential/protocol writeup.
  - **A `.env` file** (gitignored, not committed) with `FLASK_SECRET_KEY`, `APP_LOGIN_USERNAME`/`APP_LOGIN_PASSWORD`, and `DATABASE_URL=` (blank, for the sqlite fallback) makes local browser-preview testing far less fiddly than exporting vars per-terminal-session — `app.py` loads it automatically via `python-dotenv`.

## Context

The user (a Salesforce Analytics SE, non-developer) is preparing over ~3 weeks for two certifications: **Agentforce Certified Specialist (AI-201)** and **Data 360 Certified Consultant (Data-Con-101)**. They have been practicing via chat, but the **latency between answering a question and receiving the next one + full feedback (~5–15s of model time in the request path) is the core problem**.

The solution is a **Heroku-hosted web app** that moves all question generation OUT of the user's request path into a background worker, so each question and its full detailed answer are pre-computed and served instantly. The app must **preserve the long, detailed feedback format** (a compressed/lean format was explicitly rejected) — latency is solved by pre-caching, not by shortening answers.

Target repo: **https://github.com/DHalleTableau/SalesforceCertStudy**.

### Locked-in decisions
- **Cert data sourcing → hybrid, minimal, a 2-tab Google Sheet, ingested by paste.** The user maintains a Google Sheet with two tabs:
  - **Exam Guides** — `Certification, Detail_Page_URL, Exam_Guide_URL, Aggregate Certification, Base/Extra`. `Base` → `Resource.role = "primary"`, `Extra` → `"additional"`. `Aggregate Certification = "Aggregate"` → `Cert.is_aggregate = True` (see below).
  - **Certification Prerequisites** — `Certification, PreReq 1..4`. Each populated PreReq cell becomes one `CertPrerequisite` edge (`cert_code` requires `prereq_cert_code`). Chains can nest more than one level (a prerequisite can itself have prerequisites and/or be aggregate).
  - **Ingestion is paste-only, not live fetch.** "Publish to web" on this sheet requires login even in incognito — the org's Google Workspace sharing policy blocks anonymous access, and the user can't change that policy. So both tabs are ingested the same way as a Tier-2 blocked page: the user copies each tab's contents (e.g. via File → Download → CSV, or a plain copy/paste of the cell range) and pastes it into the app's admin screen; `ingest.py` parses the pasted CSV/TSV text exactly as it would've parsed a fetched one. **Whenever the sheet changes, the user re-pastes manually** — there is no auto-sync.
  - **Aggregate vs. prerequisite session-setup behavior:** an **aggregate** cert has no exam of its own — selecting it auto-includes its full prerequisite tree with no prompt (it has no independent content to ask about). A **non-aggregate** cert with 1+ direct prerequisites prompts the user at **each non-aggregate level** while walking up the chain ("Also include <cert>'s prerequisites?"), auto-descending without asking through any aggregate nodes encountered along the way. This walk is done in application code against `CertPrerequisite` edges (no stored transitive closure) — see Phase 4.
- **Auth/hosting → internal Salesforce employees only, eventually ANY Salesforce employee (org-wide), not just the original author.** This was the intent from the start of the architecture, not scope creep discovered later — worth calling out because it briefly looked like a conflicting new requirement mid-build. Since everything already hangs off `session_id` (`question_queue`, `answers`), no data-model change is needed for multi-user — Phase 4's login just needs to issue a real per-user identity (not one shared hardcoded username/password) so sessions stay naturally isolated per person.
- **Hosting is fixed: Heroku Enterprise, internal org (`dashboard.heroku.com/enterprise/sfdc-sales-org`) — not a personal/public Heroku account, and not going to change.** This matters because the `worker` process needs network access to an internal-only Claude gateway (see next bullet) — a standard public Heroku account almost certainly couldn't reach it, but an internal Enterprise Heroku org may have real connectivity into Salesforce's corporate network (e.g. via Heroku Private Spaces) since Salesforce owns Heroku. **Not yet confirmed — verify actual reachability from a deployed dyno as an explicit Phase 5 check**, don't just assume it works because the org type is promising.
- **Claude API access must be internal-only — this is a 100% hard requirement, not a preference.** Public console.anthropic.com signup is blocked/redirected for corporate accounts. **RESOLVED — here's the actual working setup:**
  - **The gateway is a unified multi-provider proxy speaking the OpenAI Chat Completions API for every model**, not Anthropic's native Messages API. Confirmed via `GET {base_url}/v1/models`: Claude, GPT, and Gemini models are ALL listed as `"owned_by": "openai"`. A request in Anthropic's native tool_use format got a 200 but came back with garbled/truncated tool-call output — the gateway doesn't genuinely support that path even though it doesn't error. **Use the `openai` Python package, not `anthropic`**, with OpenAI-style `tools=[{"type": "function", ...}]` / `tool_choice={"type": "function", "function": {"name": ...}}`, parsing `response.choices[0].message.tool_calls[0].function.arguments` (a JSON string, needs `json.loads`) rather than Anthropic's `tool_use.input` (already a dict).
  - **Credential shape:** `OpenAI(api_key=<token>, base_url=<gateway URL>, http_client=<httpx.Client with verify=<ca bundle path>>)`. The token is a real key generated through the org's internal process (not console.anthropic.com); env vars are named `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL` (kept matching the org's Claude Code docs' naming even though the wire protocol is OpenAI-shaped, not Anthropic's) and `SALESFORCE_CA_BUNDLE`.
  - **TLS/CA cert:** the corporate-managed Mac already has the org's internal root/intermediate CAs in the System Keychain (via device management) — no need to track down a file from IT. Export with `security find-certificate -a -p /Library/Keychains/System.keychain > salesforce-ca-bundle.pem`. This is not sensitive (CA certs are public by design) but stays gitignored as local machine config, not app code.
  - `CLAUDE_CODE_USE_BEDROCK`, `ANTHROPIC_BEDROCK_BASE_URL` (note: no `/bedrock` suffix in the actual working URL, unlike an earlier internal doc that had one), and `CLAUDE_CODE_SKIP_BEDROCK_AUTH` are Claude-Code-CLI-specific env vars that do nothing for a standalone Python script — they were red herrings from the product's own config docs, not applicable here.
  - `MODEL` (`claude-sonnet-5` by default, override via `CLAUDE_MODEL` env var) IS a valid ID on this gateway — confirmed via the `/v1/models` list, so no model-ID translation needed.
  - **Real reliability quirk, not hypothetical — plan around it in any future prompt/schema work:** this gateway/model combination occasionally corrupts structured tool-call output on longer/more complex calls (`generate_question`'s multi-field, long-`feedback_md` schema hit this repeatedly during Phase 3; `derive_cert_overview`'s simpler schema never did). Two distinct failure modes seen: (1) a nested array-of-objects field (`options: [{key, text}, ...]`) sometimes came back as a garbled string with leaked tool-call-formatting tokens (`<parameter name="...">`, `</invoke>`) instead of real JSON, with counts like 24 or 156 (`len()` of a string, not a list — a tell if this resurfaces); (2) a required field occasionally missing from the arguments entirely. **Mitigations that fixed it** (all in `claude_client.py`/`worker.py`): use **flat parallel arrays** (`option_keys`, `option_texts`) instead of a nested array of objects — the model handles flat string arrays far more reliably than nested objects-in-arrays on this backend; set **`minItems`/`maxItems` in the JSON schema itself** per format, not just prose ("exactly 4" in a description is not enforced structurally); **strip trailing tool-call artifacts** from long text fields (`_strip_tool_call_artifacts`); and **validate + retry** (`_is_valid_question`, `MAX_GENERATION_ATTEMPTS = 5`) rather than trusting any single response. Any new prompt/schema added later that asks for a nested array-of-objects or a very long free-text field should assume it needs the same treatment.
  - **Still unconfirmed:** whether the deployed Heroku `worker` dyno can actually reach this gateway once deployed (Phase 5's first check) — this was all verified from the user's own laptop on the corporate network so far, not from Heroku.
- **Worker model → on-demand top-up.** Generate only when the queue is below threshold AND a session is active. No idle API calls.
- **Review export → CSV download + in-app review screen.**
- **Fresh-session flow →** choose cert(s) → load/derive cert overview → show overview → begin generating.
- **API key/token** lives in Heroku config vars, never committed (repo is public).

## Architecture Overview

Two Heroku process types sharing one Postgres database:

- **`web`** — Flask (Python 3.13) app. Serves login, session setup, the question UI, and review/export. **Never calls the Claude API in a request.** It only reads pre-generated questions from the queue and records answers.
- **`worker`** — a background loop. While a session is active and the queue for that session has fewer than ~5 ready questions, it calls the Claude API to generate the next question + full-detail answer and inserts it into the queue. Idle when the queue is full or no session is active.

```
User → web (Flask) → Postgres queue  ← worker → Claude API
                         ↑ serves instantly        ↑ fills ahead of demand
```

Python is chosen over Node (both are installed) because the domain content, prompt logic, and the user's comfort lean toward readable Python; Flask + a simple worker loop is the least machinery for the job.

## Data Model (Postgres)

- **`resources`** — `(id, cert_code, url, pasted_text, role)` where `role ∈ {primary, additional}`. Populated by parsing the user's pasted "Exam Guides" tab content (see Ingestion). `pasted_text` holds grounding content for blocked/dynamic Exam_Guide_URL pages the app can't fetch.
- **`certs`** — `(cert_code, name, detail_page_url, exam_guide_url, is_aggregate, duration_min, num_questions, passing_score, domains_json)`. Overview fields derived from the primary Exam Guide; `domains_json` = `[{name, weight_pct}]`. Cached after first derivation. `is_aggregate` comes straight from the sheet's "Aggregate Certification" column.
- **`cert_prerequisites`** — `(id, cert_code, prereq_cert_code)`. One direct edge per populated PreReq cell in the "Certification Prerequisites" tab. Resolved recursively in application code, not stored as a flattened closure, since aggregate/prerequisite handling needs the direct parent structure at each level.
- **`sessions`** — `(id, user, cert_codes, started_at, status)`. `cert_codes` holds the **fully resolved** set of certs to draw questions from for that session — i.e. after the aggregate/prerequisite walk at setup time, not just what the user directly clicked.
- **`question_queue`** — `(id, session_id, cert_code, domain, difficulty, format, stem, options_json, correct_json, feedback_md, status)`. `format ∈ {single, multi}`; `correct_json` is a list (multi is graded all-or-nothing); `feedback_md` is the **full long-form** explanation (why correct + why each wrong option is wrong). `status ∈ {ready, served, answered}`.
- **`answers`** — `(id, session_id, question_id, user_answer_json, is_correct, answered_at)`. Source for review + CSV.

All of the above are already implemented in `models.py` (Phase 1).

## Resource Ingestion (two-tier, no user-maintained scrapers)

1. **The two sheet tabs themselves are ingested by paste**, not live fetch (the org's Google Workspace sharing policy blocks anonymous access to "published" sheets). An admin screen has two paste boxes — `Exam Guides` and `Certification Prerequisites` — the user pastes each tab's contents into. `ingest.py` parses `Exam Guides` into `resources` rows (`role` = primary/additional from Base/Extra) plus `Cert.is_aggregate`/`detail_page_url`/`exam_guide_url`; it parses `Certification Prerequisites` into `cert_prerequisites` edges. Re-pasting is manual whenever the sheet changes.
2. **Tier 1 — auto-fetch:** for each fetchable Exam_Guide_URL *content* page (static PDFs, plain articles) referenced by a `resources` row, the app fetches and extracts text into the grounding corpus.
3. **Tier 2 — paste fallback:** Exam_Guide_URLs that are gated/JS-rendered/blocked (Trailhead pages have previously returned empty) are flagged; the user pastes that page's content once into `pasted_text`. No scraping code to maintain.
4. **Primary vs additional** (Base/Extra) governs weighting: primary sources drive the cert overview and are weighted most heavily in question grounding; additional sources supplement.

## Cert Overview Derivation

On fresh-session start, if `certs` row is unpopulated, the worker derives overview fields (duration, # questions, passing score, domain weightings) from the **primary** Exam Guide text and caches them. The web app then shows the overview screen before questions begin.

## Question Generation (worker)

For each slot to fill, the worker prompts Claude with: the cert + a domain chosen to **target the session's weak areas**, a **difficulty that ramps up** over the session, the required format (single 1-of-4, or multi 2–3-of-5), grounding excerpts from that cert's resources (primary-weighted), and instructions to return a structured object: stem, 4–5 options, correct answer(s), and **long-form feedback** (correct rationale + per-wrong-option rationale, terminology-focused — the user's weakest area). Inserted into `question_queue` as `ready`.

## User Flow

1. **Login** (simple, internal-only).
2. **Session setup** — pick one or both certs. For each selected cert with prerequisites: aggregate certs auto-include their full prerequisite tree silently; non-aggregate certs prompt "Also include <cert>'s prerequisites?" at each non-aggregate level walked, auto-descending without prompting through any aggregate nodes. The resolved cert set (selected + opted-in prerequisites) becomes the session's `cert_codes`.
3. **Overview** — show derived duration / # questions / passing grade / domain breakdown per resolved cert; worker begins filling the queue.
4. **Question loop** — web serves next `ready` question instantly; user answers; app records to `answers`, marks `answered`, immediately shows the stored full feedback and the next (already-ready) question. Worker tops up in the background.
5. **Review/Export** — in-app filterable screen (right / wrong / both) + **CSV download** (question, user answer, correct answer, domain, correct?, timestamp).

## Files to Create (in the repo)

- `app.py` — Flask web: routes for login, session setup, overview, question serve/answer, review, CSV export.
- `worker.py` — on-demand top-up loop: generation + overview derivation.
- `claude_client.py` — Claude API wrapper + the structured question/answer prompt (long-form feedback preserved).
- `models.py` — SQLAlchemy models for the tables above.
- `ingest.py` — Google Sheet (2 tabs, pasted CSV/TSV text) → `resources`/`cert_prerequisites` parsing + two-tier fetch/paste for individual Exam_Guide_URL content.
- `templates/` — login, setup, overview, question, review pages.
- `Procfile` — `web: gunicorn app:app` and `worker: python worker.py`.
- `requirements.txt`, `runtime.txt` (Python 3.13), `.env.example`, updated `README.md`.
- `.gitignore` — exclude `.env` / secrets.

## Secrets & Config
- `ANTHROPIC_API_KEY`, `DATABASE_URL`, `FLASK_SECRET_KEY`, login credential(s) → Heroku config vars only. `.env.example` documents them; real values never committed.

## Phased Implementation (to bound context per build session)

Build and commit one **phase** at a time (not one sub-step at a time — see below), each in its own fresh chat session. Use **Sonnet** for implementation (this is mostly straightforward Flask/SQLAlchemy scaffolding, not deep reasoning) — it runs faster and preserves far more context headroom per session than Opus. Reserve Opus for genuinely hard sub-problems if one comes up (e.g., debugging a subtle worker/queue race, refining the question-generation prompt).

**Starting a new phase's session — do these things in this exact order, don't let the model reorder them:**
1. `cd "$TMPDIR" && git clone https://github.com/DHalleTableau/SalesforceCertStudy.git && cd SalesforceCertStudy` — clone FIRST, into `$TMPDIR`, before anything else touches git. (A naive clone into the default working directory will hit the `.git` write restriction described in Local Environment Notes above and burn a large chunk of context rediscovering the workaround — this has happened more than once. Giving the exact command up front removes the judgment call entirely.)
2. Read `PLAN.md` and `README.md` in full, including the "Current progress" note right below this list -- it names the exact sub-step to resume at.
3. Set up the venv per Local Environment Notes' exact `pip install` line (not `-r requirements.txt`), and create a `.env` per that same section, before attempting to run or preview anything.
4. Then start on the resume point named in "Current progress" below.

**Current progress (update this every time a sub-step finishes or is left mid-way):** Phase 4, sub-step **4f done and verified** (`/session/<id>/review?filter=both|right|wrong` lists a session's `Answer`s joined to their questions, newest first; `_get_review_answers()` shared with the CSV export in 4g so both apply identical filtering). Verified through a real server with 3 seeded answers (2 correct, 1 incorrect): "both" shows all 3, "right" shows exactly the 2 correct, "wrong" shows exactly the 1 incorrect. Next up: **4g** (CSV export).

**Within a phase, stay in the SAME session across all its sub-steps — do not open a new chat per sub-step.** A phase like Ingestion or the Question UI bundles several independent pieces (a parser, a DB write, a route, a fetch helper). Once the session above is set up, ask for one sub-step at a time within it: request a single function/route, get a small self-contained test of just that piece, confirm it looks right, *then* ask for the next sub-step in that same conversation. Context carries forward fine within a session; it's re-running the clone/setup/full-file-reading dance from scratch that's expensive — that's why sub-steps stay in one session and only phases get a fresh one. Each phase below is broken into its sub-steps for exactly this reason. Prompt pattern for a sub-step: *"Build ONLY sub-step 2b now. Show me the function/route and a quick test. Then stop and wait for me before continuing to 2c."*

1. **Skeleton + data model** — `models.py`, minimal `app.py` that boots and creates tables, `requirements.txt`, `runtime.txt`, `Procfile`, `.gitignore`, `.env.example`. Verify: app boots locally, tables create in Postgres. **[Done]**
2. **Ingestion** — `ingest.py` + an admin screen with two paste boxes, built in sub-steps: **[Done]**
   - **2a.** `parse_exam_guides_csv(csv_text)` — pure function, no DB/Flask. Parses the `Exam Guides` tab's pasted CSV text into a list of dicts (`cert_code`, `name`, `detail_page_url`, `exam_guide_url`, `is_aggregate`, `role` from Base/Extra). Verify: call it with a small hand-written sample CSV string, print the result. **[Done]**
   - **2b.** `parse_prerequisites_csv(csv_text)` — pure function. Parses the `Certification Prerequisites` tab into a list of `(cert_code, prereq_cert_code)` edges from the PreReq1-4 columns. Verify: sample CSV including a 2-level chain, confirm the edge list is correct. **[Done]**
   - **2c.** `save_exam_guides(parsed_rows)` / `save_prerequisites(parsed_edges)` — functions that upsert the parsed data into `Cert`, `Resource`, `CertPrerequisite` via SQLAlchemy. Still no Flask route — callable directly. Verify: run against a throwaway sqlite db, query the rows back out. **[Done]**
   - **2d.** Flask admin route + template: two paste boxes + submit, calling 2a-2c and showing a row-count summary. Verify: run the app locally, paste real sheet content, confirm the DB has the expected rows. **[Done, verified through an actual running Flask server]**
   - **2e.** `fetch_resource_text(url)` — Tier-1 auto-fetch: tries to fetch an Exam_Guide_URL and extract readable text. Verify: run against 1-2 real exam-guide URLs, confirm text comes back or the page is correctly flagged blocked. **[Done]**
   - **2f.** Wire Tier-1/Tier-2 into the admin flow: after saving resources, attempt fetch for each, mark `fetch_status`, add a per-resource paste box for anything flagged `blocked_needs_paste`. Verify: a known-blocked page (e.g. Trailhead) ends up flagged; a plain article gets `fetched_text` populated. **[Done]**
   - **2g.** End-to-end: paste both real tabs through the running app, confirm `resources`/`certs`/`cert_prerequisites` all end up correct (including the real multi-level prereq chain and aggregate flags). Commit. **[Done — real 86-cert sheet, real 3-level Architect chain, both aggregate certs correctly flagged. Real-world finding: Tier-1 auto-fetch came back 0/84 for the real Exam_Guide_URLs (JS-rendered Salesforce Help pages) — Tier-2 manual paste is the real path in practice, and Phase 3's grounding logic should expect `pasted_text` to carry the real weight, not `fetched_text`.]**
3. **Worker + question generation** — `claude_client.py`, `worker.py`, cert-overview derivation from primary Exam Guide text, on-demand top-up loop. Verify: queue fills to ~5 `ready` rows before any question is served; long-form feedback intact. Sub-steps: **[Done]**
   - **3a.** `claude_client.generate_question(cert_name, domain, difficulty, format, grounding_text)` — one function, OpenAI-format forced function-call to the internal gateway, returning a dict matching `question_queue`'s shape (stem, options, correct, long-form feedback_md). **[Done, verified against the real gateway with a real token]** — see Locked-in decisions above for the credential/protocol details any future sub-step calling the model needs to reuse.
   - **3b.** `claude_client.derive_cert_overview(cert_name, primary_text)` — same OpenAI-format function-call pattern as 3a, returning duration_min/num_questions/passing_score/domains_json from Exam Guide text. **[Done, verified against a synthetic exam guide with known values]**
   - **3c.** Grounding-excerpt assembly: given a cert_code, pull its `Resource` rows (prefer `pasted_text`, fall back to `fetched_text`, primary-weighted) into the text passed to 3a/3b. Pure function, no API call, cheap to test with fixture data. **[Done]**
   - **3d.** `worker.py`'s top-up loop: for each active `StudySession`, if a cert's `question_queue` `ready` count < 5, call 3a (using 3c for grounding) and insert a row; call 3b once per cert if its `Cert` row's overview fields are empty. Idle sleep otherwise. Verify: start a session, run the worker briefly, confirm the queue reaches ~5 `ready` rows with intact long-form feedback and no Claude call happens from `app.py`. **[Done — verified against the real gateway: cert overview derived correctly (105 min/60 questions/68%/5 domains), 5 ready questions generated with a real single/multi format mix and long-form feedback intact.]**
4. **Question UI + review/export** — templates for setup/overview/question/review, question-serve and answer-recording routes, grading (multi all-or-nothing), review screen, CSV export. Verify: instant serve (no model call in request), correct grading, CSV matches right/wrong/both filter. Sub-steps:
   - **4a.** Simple login: Flask session-based auth against `APP_LOGIN_USERNAME`/`APP_LOGIN_PASSWORD` env vars, a `login_required` decorator applied to every other route, login route + template. (Real per-user SSO identity is deferred until the org-wide goal is actually pursued -- see Locked-in decisions; this single shared login is enough for personal use and doesn't block that later, since nothing else keys off of it.) Verify: hitting any other route redirects to login when logged out; correct credentials let you through.
   - **4b.** Aggregate/prerequisite resolution: a pure function that, given a list of selected cert_codes, walks `CertPrerequisite` edges and returns the resolved set plus any prompts still needed (aggregate certs auto-include their full tree silently; non-aggregate certs with prerequisites need a yes/no per level -- see Locked-in decisions' Aggregate vs. prerequisite session-setup behavior). No Flask/route yet -- cheap to test against fixture `Cert`/`CertPrerequisite` rows including a multi-level chain.
   - **4c.** Session setup route + template: pick cert(s), surface 4b's prompts, create the `StudySession` row with the resolved `cert_codes`. (The already-running `worker.py` picks this up automatically on its next poll -- no direct triggering code needed, that's the whole point of the on-demand top-up design.) Verify: create a session through the real form, confirm the row lands with the right resolved cert_codes, confirm the (separately running) worker starts filling its queue. **[Done]** — verified end-to-end through a real running server: prerequisite prompt correctly triggered for a non-aggregate cert with a prerequisite, "yes" resolved both certs into the session, a cert with no prerequisites created immediately with no prompt. (Didn't re-verify the worker picking it up live in this pass -- that mechanism was already proven in 3d and nothing about how StudySession rows are queried changed.)
   - **4d.** Overview route + template: show the resolved certs' derived duration/# questions/passing score/domain breakdown before the question loop starts. Verify: matches what's cached on the `Cert` rows. **[Done]** — verified both the "pending" (not-yet-derived) state and the real rendered data through a running server.
   - **4e.** Question loop: route to serve the next `ready` `QuestionQueueItem` (marking it `served`), template rendering options as radio (single) or checkboxes (multi), route to record an `Answer` (grading: multi is all-or-nothing), returning the stored `feedback_md` plus the next already-`ready` question. Verify: confirm no model call happens in this request path (the served row was already `ready` before the request), grading correctness for both formats. **[Done]** — verified through a real running server with directly-seeded `ready` questions (no model call needed to test this piece); confirmed by code inspection that `app.py` never imports `claude_client` at all.
   - **4f.** Review screen: filterable (right/wrong/both) list of a session's `Answer`s joined to their questions. Verify against a session with a mix of correct/incorrect answers. **[Done]**
   - **4g.** CSV export: same query as 4f, formatted as a downloadable CSV (question, user answer, correct answer, domain, correct?, timestamp). Verify: downloaded file's right/wrong/both counts match the review screen's filter.
5. **Deploy** — set Heroku config vars, `git push`, scale `web=1 worker=1`, repeat the latency/grading/export checks in prod behind the internal-only login. **First check, before anything else in this phase:** confirm the deployed `worker` dyno can actually reach the internal Claude gateway (e.g. a one-off `heroku run` hitting it) — this is unverified until tested against the real Heroku Enterprise org, and if it can't reach it, everything else in this phase is blocked on resolving that networking question first.

Each phase should end with a commit to `main` (or a short-lived branch) so the next phase's fresh session starts from a known, working state rather than from conversation history.

## Verification (end-to-end)
1. **Local:** run Postgres locally, `flask run` + `python worker.py`; create a session, confirm the overview renders and the queue fills to ~5 `ready` rows *before* answering.
2. **Latency check:** answer a question and confirm the next question + full feedback appear with no model call in the request (inspect that the served row was already `ready`).
3. **Ingestion:** paste the Google Sheet's two tabs, confirm `resources` rows get correct `primary/additional` roles and `cert_prerequisites` edges match the sheet (including a multi-level chain); confirm a fetchable Exam Guide populates overview fields and a blocked URL is flagged for paste.
4. **Grading:** verify multi-select is all-or-nothing; verify weak-domain targeting and difficulty ramp over a run.
5. **Prerequisite/aggregate walk:** selecting an aggregate cert silently pulls in its full prerequisite tree; selecting a non-aggregate cert with prerequisites prompts at each non-aggregate level and auto-descends through aggregate nodes without prompting.
6. **Export:** download CSV, confirm right/wrong/both filter matches the file.
7. **Deploy:** push to `main`, deploy to Heroku, set config vars, scale `web=1 worker=1`, repeat checks 2–6 in prod behind the internal-only login.
