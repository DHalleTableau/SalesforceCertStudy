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

## The autocompact-thrashing incident (Phase 4, after the clone-location fix)

Fixing the clone-location prose problem above (putting the literal
`cd`+`git clone` command directly in the resume prompt) did NOT fully
fix repeated fresh-session context failures — sessions still hit
context almost immediately, even with a much-trimmed `PLAN.md` and
with unrelated MCP tool connectors disabled (ruling out both "docs too
big" and "unrelated tool schemas too big" as the dominant cause,
though both were reasonable hypotheses at the time and the trimming
was still worth keeping).

The actual system message on a later attempt was specific: "Autocompact
is thrashing: the context refilled to the limit within 3 turns of the
previous compact, 3 times in a row. A file being read or a tool output
is likely too large for the context window." That pointed at one huge
recurring output, not gradual accumulation.

Root cause, found by inspecting the actual checkout: **`.venv`
contains 5000+ files** (every installed package's files). The
sequence that likely triggered it: the resume prompt said "read
PLAN.md" without an absolute path; the `Read` tool requires an
absolute path (Bash's `cd` doesn't carry over to it); a relative
`Read("PLAN.md")` right after cloning fails; the session then likely
tried to recover by exploring the directory (`ls -R`, `find .`, or
similar) to locate the file, which — run from the repo root without
excluding `.venv` — dumps a massive listing into context in one shot.
That alone can exceed a compact's worth of headroom, and if the
recovery attempt repeats, it thrashes exactly as described.

Fixed by making the resume prompt explicit about both failure points:
run `pwd` right after cloning and use that literal absolute path for
every subsequent file read, and never run a recursive listing/search
from the checkout root (`.venv`'s file count called out explicitly as
the reason). Both now also stated as standing rules in Local
Environment Notes, not just the resume block, since the "no recursive
listing" rule matters any time work happens in this checkout, not only
at session start.

### Round two: same pattern, one step later (checking for `.env`)

The absolute-path fix above worked — a subsequent fresh-session attempt
cleanly cloned, read `PLAN.md`/`README.md` via the absolute path, and
set up the venv without incident. It then thrashed at the very next
step: "Checked if .env already exists." Same failure signature as
before (autocompact thrashing right after an exploratory step), one
bullet later in the resume flow.

Cause: the `.env` bullet in Local Environment Notes said "create a
`.env`" but gave no literal check-for-existence command — the exact
same vague-paraphrase gap that caused the clone-location failures,
just recurring at a different step. The fresh session improvised its
own check, almost certainly something unscoped (`ls`, `find`) that,
run from the repo root, swept `.venv`'s 5000+ files again.

Fixed the same way as the clone step: gave the `.env` bullet a literal
`test -f .env || cat > .env <<'EOF' ... EOF` command and told the
resume prompt to use it verbatim, never to improvise a check with
`ls`/`find`. General lesson (worth checking for elsewhere in
`PLAN.md`): **any instruction telling a fresh session to "check for" or
"create" something needs the literal command inline, not prose** — prose
here has twice now caused the session to invent its own recovery step
that swept `.venv`.

## Phase 5 deploy findings

- **The `se-smb` Heroku Enterprise team's apps default to the `cnb`
  (Cloud Native Buildpacks) stack, not a classic Heroku stack.** First
  sign: `heroku create --space se-smb-internal` (a Private Space)
  produced an app with `Stack: cnb`. Consequence: `runtime.txt` is
  rejected outright at build time ("The runtime.txt file isn't
  supported... replaced by .python-version") — not a warning, a hard
  build failure. Fixed by deleting `runtime.txt` and adding
  `.python-version` containing just the major version (`3.13`, no
  patch version, no `python-` prefix, no quotes) per Heroku's own error
  message. `Procfile` and `requirements.txt` were unaffected.
- **Postgres add-on service slug is `heroku-postgresql`, not
  `heroku-postgres`** on this org's catalog (`heroku addons:plans
  heroku-postgres` → "Couldn't find that add-on service"). Find the
  real slug with `heroku addons:services | grep -i postgres` rather
  than assuming the commonly-documented slug.
- **Essential-tier Postgres plans don't support Private Spaces.** An
  app created inside a space (`se-smb-internal` here) needs at least
  Standard tier (`heroku-postgresql:standard-0`) — Essential-0/1/2 are
  Common Runtime only.
- **Smart-quote paste corruption in `heroku config:set`.** Copy-pasting
  a multi-value `config:set` command with `"..."`-quoted values into a
  terminal produced a stuck `dquote>` prompt — the straight double
  quotes had been silently converted to curly/smart quotes somewhere in
  the copy path, so bash never saw a matching closing quote. Fixed by
  dropping quotes entirely for values with no spaces (tokens, URLs,
  usernames, passwords) — `VAR=value` with no quotes at all, which
  isn't vulnerable to this since there's no quote character to mangle.
- **A `config:set` command with unfilled placeholder text
  (`<your token here>`) sets the literal placeholder string as the
  var's value with no error** — Heroku has no way to know it wasn't a
  real value. Caught by grepping `heroku config --shell` for the
  affected var names after every `config:set` and eyeballing for
  placeholder-looking text, not by assuming the command succeeded
  because it exited cleanly.

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

## Phase 5: worker cannot reach the internal gateway (open, unresolved)

`heroku run -a sf-cert-study -- python3 -c "from claude_client import
_build_client; c = _build_client(); print(c.models.list())"` failed
with `httpx.ConnectTimeout` / `openai.APITimeoutError`. This is a
TCP-level connect timeout, not an auth failure, TLS error, or HTTP 4xx
-- the connection to the gateway never establishes at all from inside
the Heroku dyno.

Same underlying pattern as the web-access block found earlier in this
phase: the app's own public URL returned 403 from Heroku's router
until accessed over the Salesforce VPN with the right IP in the
space's Trusted IP Ranges. The gateway is almost certainly similarly
locked to Salesforce's internal network -- a Heroku dyno's outbound
traffic (from `sf-cert-study`'s Outbound IPs: 44.218.186.40,
54.86.78.213, 54.174.229.51, plus an IPv6 block) isn't part of that
network, so the connection is dropped before it ever reaches the
gateway.

Not yet resolved. Plausible fixes, none yet attempted:
- A Private Space peering / AWS PrivateLink connection from
  `se-smb-internal` into Salesforce's internal network (if such a
  thing exists for this org).
- An IP allowlist on the gateway's own side that could be given
  Heroku's outbound IPs.
- A different access pattern entirely (e.g. a proxy running inside
  Salesforce's network that Heroku calls through).

Next step: check for internal documentation on server-to-server /
programmatic access to this gateway (as opposed to a developer's
laptop over VPN) -- same category of "undocumented internal setup" as
the original gateway credentials (see "The internal Claude gateway"
section above), likely already solved by someone else in the org.
