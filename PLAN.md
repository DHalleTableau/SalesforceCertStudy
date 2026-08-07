# Salesforce Cert Study App — Architecture Plan

> Canonical living plan, kept in the repo so any fresh session gets
> full context by cloning + reading this file. This file is kept
> deliberately short and dense -- see `HISTORY.md` for the detailed
> narrative behind non-obvious decisions (only needed for "why", not
> for doing the next task).

## Local Environment Notes (read before touching git or pip)

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
- **Local venv setup** (`pip install -r requirements.txt` fails here
  on `psycopg2-binary` — see HISTORY.md):
  ```bash
  cd "$TMPDIR/SalesforceCertStudy"
  python3 -m venv .venv && source .venv/bin/activate
  pip install Flask Flask-SQLAlchemy SQLAlchemy openai requests python-dotenv
  ```
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
mid-way):** Phase 4 **complete (4a-4g all done)**. Next: **Phase 5 —
Deploy**. First check before anything else in that phase: confirm the
deployed `worker` dyno can reach the internal Claude gateway.

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
