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

**Answer from asking in the internal Claude Code support channel:**
confirmed there is genuinely no documented supported path for a
server-side/cloud-hosted process (Heroku dyno or otherwise) to reach
`eng-ai-model-gateway.sfproxy.devx-preprod.aws-esvc1-useast2.aws.sfdc.cl`
directly -- the only supported setup is a developer machine on VPN
(DevBar/installer). No IP allowlist process, no PrivateLink/VPC peering
option, no proxy tier for cloud apps. This is an actual infrastructure
gap, not something fixable from the app side. Escalated further to
`#community-claude-code` with the outbound IPs + `ConnectTimeout` error
for the DevX/infra team; response pending as of this writing.

**Interim workaround while waiting on that escalation:** run
`worker.py` locally (on the VPN-connected Mac, where the gateway is
already reachable) pointed at the deployed Heroku Postgres via
`DATABASE_URL`, while `web` stays deployed and serves real traffic
normally on Heroku. The two processes only share a database, not a
network -- `worker` never needed to be co-located with `web`, it just
needs DB access + gateway access from wherever it runs. Not yet
verified whether the space-attached Postgres is reachable from outside
Heroku's network at all -- untested as of this writing, same class of
Private-Space-network-isolation risk as everything else in this phase.

## Phase 5 outcome so far: deployed, two blockers, one working interim path

End-to-end verified working (real production data, real generated
questions, real grading/feedback): ingestion, session setup,
overview, the full question loop (single + multi select), all running
via `app.py` + `worker.py` **locally**, both pointed at the deployed
Heroku Postgres (`DATABASE_URL` from `heroku config:get -a
sf-cert-study`). This is not a toy test -- it's the real app working
against real data, just with the two processes running on a laptop
instead of Heroku dynos.

Two separate blockers remain on actually using the Heroku-hosted
`web`/`worker` themselves, both requiring someone outside this app:
1. **Trusted IP Ranges** (`se-smb-internal` space) blocks the app's own
   public URL from any IP not already allowlisted; adding an IP needs
   a `se-smb` team admin (role `member` can't self-service this).
2. **Gateway network access** -- confirmed no supported path exists
   yet for a Heroku dyno to reach the internal Claude gateway; escalated
   to `#community-claude-code`. See the earlier "Phase 5: worker cannot
   reach gateway" section above for the full diagnostic chain.

Bugs found and fixed along the way (all real, not environment quirks):
- `save_prerequisites` crashed on any prerequisite edge referencing a
  cert missing from Exam Guides -- SQLite silently allowed this
  dangling reference in earlier local testing; Postgres correctly
  rejected it. Fixed to skip + report instead of crashing (see the
  earlier "Fix crash on prereq edges" entry).
- `session_overview.html` had stale placeholder text instead of a
  link to the actual question loop (4e was built after this template
  was written, and the template was never updated).
- A genuinely blank Exam Guides paste (missing "Certification" column
  entirely -- the pasted sheet used "Title" instead) silently parsed
  to zero rows with no error, which cascaded into a long, confusing
  chain of symptoms (a seemingly-empty production database, seemingly
  lost data) that were actually all downstream of that one empty
  parse. Diagnosed by adding temporary debug prints directly in the
  request handler to see `Cert.query.count()` immediately after the
  save, which caught it going into the wall.
- `worker.py` never printed anything on a *successful* generation,
  only on rejected retries -- made a fully-succeeded queue (5/5 ready)
  look permanently stuck, since the terminal only ever showed old
  failure messages scrolling by with nothing after them. Fixed by
  logging on success too.

Also found: multiple abandoned `StudySession` rows (empty
`cert_codes`, from early testing before the checkbox-not-checked issue
was caught) still show up as `status="active"` forever -- nothing in
this app ever marks a session `ended`. Harmless so far (worker.py
just loops over them doing nothing since `cert_codes` is empty), but
worth cleaning up or adding session-ending logic eventually.

## `$TMPDIR` wiped mid-session, and I couldn't re-create it myself

During the question-variability work, the entire checkout vanished
mid-edit (not a reboot the user triggered knowingly -- just discovered
when a routine file edit suddenly returned "File does not exist").
Nothing was lost: everything through the last `git push` was safe on
GitHub, and the one not-yet-committed feature (style rotation) was
still visible in the assistant's own conversation context and got
reapplied verbatim once the repo was back.

New wrinkle vs. the previously-documented version of this problem: the
assistant's own sandbox could NOT recreate `$TMPDIR/SalesforceCertStudy`
itself this time -- `git clone` and even a plain `mkdir` both failed
with "Operation not permitted." The sandbox's write allowlist is
scoped to the exact path `$TMPDIR/SalesforceCertStudy`, which only
works while that path already exists; creating it fresh needs write
permission on its *parent* (`$TMPDIR` itself), which the assistant
does not have. Only the user's own terminal (unrestricted by this
sandbox) could run the clone command to recreate it. Once it existed
on disk again, the assistant's tools could read/write into it exactly
as before.

Lesson: if `$TMPDIR/SalesforceCertStudy` is ever gone, the assistant
cannot self-heal by re-cloning -- always hand the exact `mkdir -p
$TMPDIR && cd $TMPDIR && git clone ...` command to the user to run in
their own terminal first.

## Procfile never bound to an address at all (found via admin feedback)

The `se-smb` admins reported "we need to bind to the IPv6 address" and
that the app appeared to be crashing, separately from an access bug
they were independently investigating. They also said Trusted IP
Ranges shouldn't be needed for this app at all -- "it should work as
configured" -- which meant the earlier Trusted-IP-Ranges diagnosis
(the fix that got a real 403 to go away) was real and worth doing
regardless, but likely wasn't the *whole* story, and possibly wasn't
even the actual root cause of what the admins were seeing when they
tested it themselves.

Checked `Procfile`: `web: gunicorn app:app` -- no `--bind` flag at
all. Gunicorn's default bind is `127.0.0.1:8000`, not
`0.0.0.0:$PORT` or any address Heroku's router can actually reach.
This is a real, independent bug: a dyno bound only to localhost would
never be reachable from the platform's router no matter what
IP-allowlist state the surrounding space is in, and would plausibly
present as exactly what the admins described ("crashing"/
inaccessible) if their own testing bypassed whatever the Trusted-IP
issue was in some other way.

Fixed by binding explicitly to the IPv6 wildcard per the admins'
specific guidance: `web: gunicorn app:app --bind [::]:$PORT`.

## Playwright broke the Heroku build (greenlet has no prebuilt wheel there)

Adding `playwright`/`trafilatura` to `requirements.txt` (for the
Tier-1 auto-fetch rewrite) broke `git push heroku main`: `greenlet`
(a transitive dependency of `playwright`'s sync API) has no prebuilt
wheel for this Python version on Heroku's `cnb` build image, and
compiling it from source failed (`g++`... `returned non-zero exit
status 1`).

Even if that compiled, it wouldn't have helped -- a standard Heroku
dyno has no Chromium binary and can't run one without a dedicated
Playwright/Chromium buildpack (already flagged as a known, deferred
limitation when this feature was planned: ingestion only ever runs
via the local `app.py` workaround, never on the deployed app).

Fixed by removing `playwright`/`trafilatura` from `requirements.txt`
entirely and documenting them as a separate **local-only** `pip
install` step in `PLAN.md` instead. `requirements.txt` now installs
cleanly on both local (`pip install -r requirements.txt`) and Heroku's
build. General lesson: a dependency only ever used by a local-only
workflow doesn't belong in the file Heroku's build reads, even if it's
also used locally -- `requirements.txt` should reflect what `web`/
`worker` actually need, not everything installed in the local venv.

## The actual crash: psycopg2-binary==2.9.9 has no real Python 3.13 wheel

`heroku logs` (not curl -- curl only ever showed generic Heroku edge
error pages, never the app's own logs) revealed the real, single root
cause behind both "Access Denied" and "Application Error": `web` and
`worker` were crashing identically on
`ImportError: .../psycopg2/_psycopg...so: undefined symbol:
_PyInterpreterState_Get` -- a binary ABI mismatch between the pinned
`psycopg2-binary==2.9.9` and the Python 3.13.15 runtime Heroku's
`cnb` builder actually uses. `psycopg2-binary` only added proper
Python 3.13 wheels starting at 2.9.10; local testing never hit this
because the local venv had installed an unpinned, newer `2.9.12`
(the version actually pinned in `requirements.txt` was stale and
never got exercised locally).

This means the earlier Trusted-IP-Ranges fix and the gunicorn
`--bind` fix, while both real and worth keeping, were never actually
the last blocker on their own -- the dyno couldn't even boot at all
underneath either of them. Fixed by bumping the pin to
`psycopg2-binary==2.9.10`.

Lesson: `heroku logs` (the app's own runtime output) is a much more
direct diagnostic than testing the public URL with `curl` -- curl can
only ever show what Heroku's edge/router decided to return, which
looks identical whether the real cause is a network/access issue or
the dyno never booting at all. Check `heroku logs` early next time
something is unreachable, not just the HTTP response.
