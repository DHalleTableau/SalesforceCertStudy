# SalesforceCertStudy

A Heroku-hosted practice-exam tutor for Salesforce certifications. It
generates continuous, unlimited cert-like questions for one or more
certs at once, with full detailed per-question feedback (why the correct
answer is correct, why each wrong option is wrong), score tracking with
weak-domain targeting, and ramping difficulty.

The core design goal: **question generation never happens in the user's
request path.** A background `worker` process keeps a rolling buffer of
~5 upcoming questions (with their full-detail feedback) pre-generated in
Postgres ahead of demand; the `web` app only ever reads a `ready` row and
serves it instantly. This is what makes the app fast — not a shorter
feedback format.

**Full architecture, data model, and the phased build plan live in
[PLAN.md](PLAN.md).** Starting a fresh session to build the next phase?
Just say: *"Clone this repo, read PLAN.md and README.md, then build
Phase N."*

## Architecture

Two Heroku process types sharing one Postgres database:

- **`web`** (`app.py`) — Flask app. Serves login, session setup, the
  question UI, and review/export. Never calls the Claude API in a
  request.
- **`worker`** (`worker.py`) — background loop. While a session is
  active and its queue has fewer than ~5 `ready` questions, calls the
  Claude API to generate the next question + full-detail answer and
  inserts it into the queue.

```
User → web (Flask) → Postgres queue  ← worker → Claude API
                         ↑ serves instantly        ↑ fills ahead of demand
```

## Status

Built in phases, each committed independently so the app is runnable at
every step:

- [x] **Phase 1 — Skeleton + data model.** `models.py` (SQLAlchemy
      tables for resources/certs/cert_prerequisites/sessions/
      question_queue/answers, including aggregate-cert and prerequisite
      support), a Flask app that boots and creates tables, `worker.py`
      stub, `requirements.txt`, `runtime.txt`, `Procfile`,
      `.env.example`, `.gitignore`.
- [x] **Phase 2 — Resource ingestion.** `ingest.py` (CSV parsing +
      SQLAlchemy upserts for both sheet tabs + Tier-1 fetch/Tier-2
      paste), `/admin/ingest` route + template. Verified against real
      sheet data: 86 certs, correct aggregate flags, a real 3-level
      prerequisite chain. Note: Tier-1 auto-fetch essentially never
      succeeds for this sheet's real Exam_Guide_URLs (they're
      JS-rendered Experience Cloud pages) — expect to use the
      per-resource paste box for any cert you actually want grounded.
- [x] **Phase 3 (in progress) — Worker + question generation.**
      `claude_client.py` (question generation + cert-overview
      derivation, both verified against the real internal gateway),
      `worker.py`'s on-demand top-up loop (verified: fills a session's
      queue to 5 ready rows with long-form feedback intact). See
      PLAN.md for the internal-gateway credential/protocol details.
- [ ] Phase 4 — Question UI + review/export.
- [ ] Phase 5 — Heroku deploy.

## Local setup (Phase 1 check)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in DATABASE_URL for a local Postgres, or leave unset for sqlite
python app.py           # boots Flask, creates tables
curl http://127.0.0.1:5000/healthz
```

## Secrets

`ANTHROPIC_API_KEY`, `DATABASE_URL`, `FLASK_SECRET_KEY`, and the app
login credentials live only in Heroku config vars — this repo is public
and nothing real is committed. `.env.example` documents the required
variables.
