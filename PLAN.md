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
- **Auth/hosting → internal Salesforce employees only.** Simple login is acceptable; hosted where only SF employees can reach it.
- **Worker model → on-demand top-up.** Generate only when the queue is below threshold AND a session is active. No idle API calls.
- **Review export → CSV download + in-app review screen.**
- **Fresh-session flow →** choose cert(s) → load/derive cert overview → show overview → begin generating.
- **API key** lives in Heroku config vars, never committed (repo is public).

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

Build and commit one phase at a time, each in its own fresh chat session. **Tell the new session to clone the repo and read this file (`PLAN.md`) and `README.md`** — that's all the context it needs; no other file or path has to be remembered or passed along. Use **Sonnet** for implementation (this is mostly straightforward Flask/SQLAlchemy scaffolding, not deep reasoning) — it runs faster and preserves far more context headroom per session than Opus. Reserve Opus for genuinely hard sub-problems if one comes up (e.g., debugging a subtle worker/queue race, refining the question-generation prompt).

**Within a phase, ask for one sub-step at a time, not the whole phase.** A phase like Ingestion or the Question UI bundles several independent pieces (a parser, a DB write, a route, a fetch helper); asking for all of them plus verification in one prompt is what runs a session out of context. Instead: request a single function/route, get a small self-contained test of just that piece, confirm it looks right, *then* ask for the next sub-step in the same session (context carries forward within a session — it's only fresh *phases* that need a new session). Each phase below is broken into its sub-steps for exactly this reason. Prompt pattern: *"Build ONLY sub-step 2a. Show me the function/route and a quick test. Then stop and wait for me before continuing to 2b."*

1. **Skeleton + data model** — `models.py`, minimal `app.py` that boots and creates tables, `requirements.txt`, `runtime.txt`, `Procfile`, `.gitignore`, `.env.example`. Verify: app boots locally, tables create in Postgres. **[Done]**
2. **Ingestion** — `ingest.py` + an admin screen with two paste boxes, built in sub-steps:
   - **2a.** `parse_exam_guides_csv(csv_text)` — pure function, no DB/Flask. Parses the `Exam Guides` tab's pasted CSV text into a list of dicts (`cert_code`, `name`, `detail_page_url`, `exam_guide_url`, `is_aggregate`, `role` from Base/Extra). Verify: call it with a small hand-written sample CSV string, print the result.
   - **2b.** `parse_prerequisites_csv(csv_text)` — pure function. Parses the `Certification Prerequisites` tab into a list of `(cert_code, prereq_cert_code)` edges from the PreReq1-4 columns. Verify: sample CSV including a 2-level chain, confirm the edge list is correct.
   - **2c.** `save_exam_guides(parsed_rows)` / `save_prerequisites(parsed_edges)` — functions that upsert the parsed data into `Cert`, `Resource`, `CertPrerequisite` via SQLAlchemy. Still no Flask route — callable directly. Verify: run against a throwaway sqlite db, query the rows back out.
   - **2d.** Flask admin route + template: two paste boxes + submit, calling 2a-2c and showing a row-count summary. Verify: run the app locally, paste real sheet content, confirm the DB has the expected rows.
   - **2e.** `fetch_resource_text(url)` — Tier-1 auto-fetch: tries to fetch an Exam_Guide_URL and extract readable text. Verify: run against 1-2 real exam-guide URLs, confirm text comes back or the page is correctly flagged blocked.
   - **2f.** Wire Tier-1/Tier-2 into the admin flow: after saving resources, attempt fetch for each, mark `fetch_status`, add a per-resource paste box for anything flagged `blocked_needs_paste`. Verify: a known-blocked page (e.g. Trailhead) ends up flagged; a plain article gets `fetched_text` populated.
   - **2g.** End-to-end: paste both real tabs through the running app, confirm `resources`/`certs`/`cert_prerequisites` all end up correct (including the real multi-level prereq chain and aggregate flags). Commit.
3. **Worker + question generation** — `claude_client.py`, `worker.py`, cert-overview derivation from primary Exam Guide text, on-demand top-up loop. Verify: queue fills to ~5 `ready` rows before any question is served; long-form feedback intact. (Break into sub-steps the same way once started — e.g. the Claude prompt/parsing, then the top-up loop, then overview derivation.)
4. **Question UI + review/export** — templates for setup/overview/question/review, question-serve and answer-recording routes, grading (multi all-or-nothing), review screen, CSV export. Verify: instant serve (no model call in request), correct grading, CSV matches right/wrong/both filter. (Also expect to sub-step this one — it has a similar number of independent pieces to Ingestion.)
5. **Deploy** — set Heroku config vars, `git push`, scale `web=1 worker=1`, repeat the latency/grading/export checks in prod behind the internal-only login.

Each phase should end with a commit to `main` (or a short-lived branch) so the next phase's fresh session starts from a known, working state rather than from conversation history.

## Verification (end-to-end)
1. **Local:** run Postgres locally, `flask run` + `python worker.py`; create a session, confirm the overview renders and the queue fills to ~5 `ready` rows *before* answering.
2. **Latency check:** answer a question and confirm the next question + full feedback appear with no model call in the request (inspect that the served row was already `ready`).
3. **Ingestion:** paste the Google Sheet's two tabs, confirm `resources` rows get correct `primary/additional` roles and `cert_prerequisites` edges match the sheet (including a multi-level chain); confirm a fetchable Exam Guide populates overview fields and a blocked URL is flagged for paste.
4. **Grading:** verify multi-select is all-or-nothing; verify weak-domain targeting and difficulty ramp over a run.
5. **Prerequisite/aggregate walk:** selecting an aggregate cert silently pulls in its full prerequisite tree; selecting a non-aggregate cert with prerequisites prompts at each non-aggregate level and auto-descends through aggregate nodes without prompting.
6. **Export:** download CSV, confirm right/wrong/both filter matches the file.
7. **Deploy:** push to `main`, deploy to Heroku, set config vars, scale `web=1 worker=1`, repeat checks 2–6 in prod behind the internal-only login.
