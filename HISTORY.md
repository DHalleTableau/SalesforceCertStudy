# Build History & Lessons Learned

Detailed narrative behind non-obvious decisions in `PLAN.md`. Read this
only if you need the "why" behind something, or if a past problem
resurfaces — it is NOT needed to do the next task. `PLAN.md` stays
deliberately short; this file holds the story that was trimmed out of
it to keep fresh sessions cheap to start.

## The internal Claude gateway (Phase 3)

The org blocked public console.anthropic.com signup for corporate
accounts, redirecting to an internal Slack canvas. That canvas
described Claude Code CLI's own Bedrock-proxy setup
(`CLAUDE_CODE_USE_BEDROCK=1`, `ANTHROPIC_BEDROCK_BASE_URL` ending in
`/bedrock`, `CLAUDE_CODE_SKIP_BEDROCK_AUTH=1`, `NODE_EXTRA_CA_CERTS`) —
none of which apply to a standalone Python script; those are Claude
Code CLI/Node-specific config keys.

Once a real token was obtained through the org's internal process, the
actual working setup turned out to be simpler and different from that
doc: `GET {base_url}/v1/models` revealed every model (Claude, GPT,
Gemini) listed as `"owned_by": "openai"` — the gateway is a unified
multi-provider proxy speaking the OpenAI Chat Completions API for
every model, not Anthropic's native Messages API. A request in
Anthropic's native tool_use format got an HTTP 200 but came back
garbled — the gateway doesn't error on that format, it just doesn't
support it properly. Switching to the `openai` package with
OpenAI-style function-calling fixed it immediately.

The TLS side resolved easily once discovered: the corporate-managed
Mac already had the org's internal root/intermediate CAs in the
System Keychain (via device management) — `security find-certificate
-a -p /Library/Keychains/System.keychain` exports them straight to a
usable PEM bundle. No need to track down a file from IT.

### The structured-output flakiness debugging session

Even with the OpenAI-format fix, `generate_question`'s multi-field,
long-`feedback_md` schema hit real reliability problems on this
gateway/model combination that a simpler schema (`derive_cert_overview`)
never did. Two distinct failure modes, found by iterating with live
debug scripts against the real gateway:

1. **Nested array-of-objects corruption.** The `options` field
   (`[{key, text}, ...]`) sometimes came back as a garbled string with
   leaked tool-call-formatting tokens (`<parameter name="...">`,
   `</invoke>`) instead of real JSON. `len()` on that string gave
   misleadingly plausible-looking counts (24, 156) that looked like
   real (wrong) option counts until inspected directly — a tell if
   this resurfaces.
2. **Missing required fields.** `feedback_md` occasionally absent from
   the arguments entirely, not just corrupted.

Fixes, all landed in `claude_client.py`/`worker.py`:
- **Flat parallel arrays** (`option_keys`, `option_texts`) instead of
  a nested array of `{key, text}` objects — this model/gateway handles
  flat string arrays far more reliably than nested objects-in-arrays.
- **`minItems`/`maxItems` in the JSON schema itself**, per format, not
  just prose ("exactly 4" in a description text isn't structurally
  enforced — a multi-select request literally came back with 24
  options once, before this fix).
- **Strip trailing tool-call artifacts** from long text fields
  (`_strip_tool_call_artifacts`).
- **Validate + retry** (`_is_valid_question`, `MAX_GENERATION_ATTEMPTS
  = 5`) rather than trusting any single response.

If a new prompt/schema is added later that asks for a nested
array-of-objects or a very long free-text field, assume it needs the
same treatment.

## The lost-commits incident (between Phase 2 and Phase 3)

After one push-verification checkpoint, subsequent commits were
handed off to the user to push without re-verifying they landed —
violating the very rule now in Local Environment Notes. Real
`origin/main` sat stuck at an old commit for a long stretch while all
of Phase 2's `ingest.py` and all of Phase 3's `claude_client.py`/
`worker.py` were built, tested, and (incorrectly) believed pushed.
Then the user's machine rebooted, wiping `$TMPDIR` — which held the
only copies. Recovered by rewriting every missing file from the
assistant's own conversation context (nothing was lost from the
assistant's side, it just never reached git). Cost real rework that a
`git ls-remote <repo> HEAD` after every single push would have caught
immediately, for free. Hence the current hard rule: verify every push,
no exceptions.

## The repeated fresh-session clone-location failures (Phase 4)

Multiple fresh-session resume attempts hit the exact same wall: told
in prose to "clone the repo, read PLAN.md," the new session cloned
into whatever directory it started in, hit the `.git` write
restriction (see Local Environment Notes), and burned its entire
context thrashing through workarounds (disabling git template dirs,
trying GitHub's raw content API) before ever reading a line of
PLAN.md — because the `$TMPDIR` requirement only lives *inside*
PLAN.md, which hadn't been read yet at the moment it decided where to
clone. Fixed by putting the literal clone command directly in the
resume prompt text itself, not as a pointer to documentation. See
`PLAN.md`'s "Phased Implementation" section for the current copy-paste
resume block — always use it verbatim, never paraphrase "clone the
repo, read the docs."

## Other resolved quirks

- **Writes to any directory literally named `.git` fail** under the
  assistant's default working directory (a local sandbox restriction,
  not a real permissions problem on the Mac). Clone into `$TMPDIR`
  instead.
- **`pip install -r requirements.txt` fails** on `psycopg2-binary`
  trying to compile against a local Postgres (`pg_config`) that
  doesn't exist on this machine. Only needed for the real Heroku
  Postgres connection; local dev always falls back to sqlite. Install
  the specific packages actually needed for local testing instead (see
  Local Environment Notes' exact line).
- **Flask/SQLAlchemy relative sqlite URI quirk:** `"sqlite:///local.db"`
  resolves against Flask's guessed `instance_path`, which put the
  database file in a surprising location (the process's working
  directory, not the project folder) when the app was launched via an
  absolute script path from a different cwd. Fixed by anchoring the
  fallback path to `app.py`'s own directory explicitly
  (`_database_url()` in `app.py`).
- **Sheet placeholder values:** the real Exam Guides sheet used the
  literal text `"NOT FOUND"` for aggregate certs' (nonexistent)
  `Exam_Guide_URL`, rather than leaving the cell blank. `ingest.py`'s
  `_clean_url()` treats a small set of placeholder strings (`"not
  found"`, `"n/a"`, `"na"`, `"none"`, `"tbd"`) as blank.
- **Real-world ingestion finding:** Tier-1 auto-fetch came back 0/84
  for the real sheet's `Exam_Guide_URL`s — `help.salesforce.com/s/
  articleView` pages are Lightning/Experience Cloud SPAs that render a
  JS-only loading shell without JS execution, same class of page as
  the already-known-blocked Trailhead certificate pages. In practice,
  `Resource.pasted_text` (Tier 2, filled in manually) is the content
  that actually matters — not `fetched_text`.
