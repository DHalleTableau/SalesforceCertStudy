"""Background top-up worker for the Salesforce Cert Study tool.

On-demand top-up (see PLAN.md's Locked-in decisions), scoped per cert
rather than per session: while any session is active, keep a shared
pool of POOL_SIZE ready, *unclaimed* questions (session_id IS NULL)
for each cert some active session actually needs, generating one
replacement at a time via claude_client.py as the pool runs low.
Idle when every needed cert's pool is full, or no session is active.
This is the only process that calls the model -- app.py never does.

Per-cert (not per-session) generation is a deliberate fix for two
problems seen in practice: an abandoned/mistaken session used to soak
up a full batch-of-5 generation run that a real, waiting user was
stuck behind (observed ~10 minute delays); and there was no way to
"cancel" a session's in-flight generation when it ended or backed out,
because generation was tied to the session in the first place. Under
this model there's nothing to cancel -- a session backing out just
means its cert stops appearing in the "still needed" set on the very
next poll cycle.
"""
import re
import time
from datetime import datetime, timezone

from app import app
from claude_client import assemble_grounding_text, derive_cert_overview, generate_question
from models import Cert, QuestionQueueItem, StudySession, db

POOL_SIZE = 5
POLL_INTERVAL_SECONDS = 5


def ensure_cert_overview(cert_code):
    """Derive and cache overview fields for a cert if not already done.

    Cheap no-op on every call after the first: skips as soon as
    duration_min is populated, so this is safe to call every poll.
    """
    cert = Cert.query.get(cert_code)
    if cert is None or cert.duration_min is not None:
        return

    grounding = assemble_grounding_text(cert_code)
    if not grounding:
        return  # no usable resources pasted for this cert yet

    overview = derive_cert_overview(cert.name, grounding)
    cert.duration_min = overview["duration_min"]
    cert.num_questions = overview["num_questions"]
    cert.passing_score = overview["passing_score"]
    cert.domains_json = overview["domains_json"]
    cert.derived_at = datetime.now(timezone.utc)
    db.session.commit()


def _cert_total_generated(cert_code):
    """Total QuestionQueueItem rows ever generated for this cert,
    claimed or not -- the shared rotation basis for difficulty/format/
    style/domain, all keyed the same way so a cert's pool gets a
    consistent, varied mix regardless of which sessions end up
    claiming which rows.
    """
    return QuestionQueueItem.query.filter_by(cert_code=cert_code).count()


def _next_pool_difficulty(total_generated):
    """Mixed pool, no ramp: cycles 1-5. Personalized per-session
    difficulty ramping doesn't apply once generation happens ahead of
    any specific session's progress -- deferred until there's a real
    per-user mechanism to target. Kept as its own function (not
    inlined) so that mechanism can replace just this rule later
    without touching the schema or the rest of generation.
    """
    return (total_generated % 5) + 1


def _next_format(total_generated):
    """Simple mix: every 6th generated question is multi-select. Real
    exams the app was tested against used single-select exclusively,
    but multi-select isn't being dropped -- just made less frequent
    (was every 3rd). Easy to retune this ratio further either way.
    """
    return "multi" if total_generated % 6 == 5 else "single"


def _next_style(total_generated):
    """Mix of terminology recall and three scenario sub-types, rotated
    over an 8-slot cycle (terminology getting the majority, each
    scenario flavor getting one slot) -- offset from _next_format's
    cadence so the two rotations don't always land on the same slot.

    The three scenario flavors exist because real exam experience
    called out two specific patterns generic "how would you handle
    this" scenarios weren't covering: prioritization ("what's the
    fastest/first thing to do") and root-cause diagnosis ("what did
    the team/client most likely do wrong"), alongside the original
    general scenario style.
    """
    slot = total_generated % 8
    if slot == 5:
        return "scenario-general"
    if slot == 6:
        return "scenario-first-action"
    if slot == 7:
        return "scenario-root-cause"
    return "terminology"


def _next_domain(cert, total_generated):
    """Round-robin through cert.domains_json instead of leaving domain
    choice open -- left as None, the model kept defaulting to whatever
    was most prominent in the grounding text, regardless of how many
    other domains the cert actually covers.

    NOT full weak-domain targeting (picking domain from the user's
    incorrect-answer history) -- that's still deferred until there's
    real answer history to target against. This just guarantees each
    call is explicitly pointed at a different domain in rotation.
    Falls back to None (let the model choose) if the cert's overview
    hasn't been derived yet, or it has no domain breakdown.
    """
    domains = cert.domains_json or []
    if not domains:
        return None
    return domains[total_generated % len(domains)]["name"]


AVOID_STEMS_LIMIT = 40


MAX_GENERATION_ATTEMPTS = 5


MIN_FEEDBACK_LENGTH = 100

MIN_SENTENCE_LENGTH_FOR_DUPLICATE_CHECK = 15


def _has_duplicate_sentence(text):
    """True if any non-trivial sentence appears more than once verbatim
    -- a real repetition artifact seen in model output (e.g. a stem's
    closing question restated as a trailing paragraph). Short
    sentences are excluded since those can coincidentally repeat
    without it being a real artifact.
    """
    sentences = [s.strip() for s in re.split(r"(?<=[.?!])\s+", text) if s.strip()]
    significant = [s for s in sentences if len(s) >= MIN_SENTENCE_LENGTH_FOR_DUPLICATE_CHECK]
    return len(significant) != len(set(significant))


def _is_valid_question(question, format):
    """The model doesn't always respect exact option-count constraints
    perfectly, or occasionally leaks tool-call formatting artifacts
    that get stripped down to almost nothing (see
    claude_client._strip_tool_call_artifacts) -- validate before
    inserting into the queue rather than trusting it blindly.

    Returns (True, "") or (False, "<reason>") so callers can log why a
    candidate was rejected instead of just a bare pass/fail.
    """
    expected_options = 4 if format == "single" else 5
    actual_options = len(question.get("options", []))
    if actual_options != expected_options:
        return False, f"expected {expected_options} options, got {actual_options}"

    min_correct, max_correct = (1, 1) if format == "single" else (2, 3)
    correct = question.get("correct", [])
    if not (min_correct <= len(correct) <= max_correct):
        return False, f"expected {min_correct}-{max_correct} correct, got {len(correct)}"

    option_keys = {o.get("key") for o in question.get("options", [])}
    if not set(correct).issubset(option_keys):
        return False, f"correct keys {correct} not a subset of option keys {option_keys}"

    feedback_len = len(question.get("feedback_md", ""))
    if feedback_len < MIN_FEEDBACK_LENGTH:
        return False, f"feedback_md too short after cleanup: {feedback_len} chars"

    if _has_duplicate_sentence(question.get("stem", "")):
        return False, "stem contains a duplicated sentence"

    return True, ""


def _needed_cert_codes():
    """Every cert_code that some currently-active session cares about.
    Recomputed fresh each poll cycle -- this is the whole mechanism
    that lets an ended/backed-out session stop costing generation
    time with no explicit cancellation: if no active session lists a
    cert anymore, it simply stops appearing here next cycle.
    """
    needed = set()
    for session in StudySession.query.filter_by(status="active").all():
        needed.update(session.cert_codes)
    return needed


def top_up_cert_pool(cert_code):
    """Generate at most one replacement question for cert_code's
    shared pool, if it's currently short of POOL_SIZE unclaimed ready
    rows. One at a time, not a batch -- the next poll cycle re-checks
    and generates another if still short, so a cert with many
    concurrent claimants gets refilled steadily rather than in one
    long blocking run.
    """
    ensure_cert_overview(cert_code)

    cert = Cert.query.get(cert_code)
    if cert is None:
        return

    unclaimed_ready_count = QuestionQueueItem.query.filter_by(
        cert_code=cert_code, session_id=None, status="ready"
    ).count()
    if unclaimed_ready_count >= POOL_SIZE:
        return

    grounding = assemble_grounding_text(cert_code)
    if not grounding:
        return  # nothing to generate from yet

    total_generated = _cert_total_generated(cert_code)
    difficulty = _next_pool_difficulty(total_generated)
    format = _next_format(total_generated)
    style = _next_style(total_generated)
    domain = _next_domain(cert, total_generated)

    # Cross-session, cert-wide: nothing stopped a brand-new session
    # from repeating a question asked in an earlier one. Capped to the
    # most recent AVOID_STEMS_LIMIT so the prompt doesn't grow
    # unbounded over weeks of practice.
    avoid_stems = [
        item.stem
        for item in QuestionQueueItem.query.filter_by(cert_code=cert_code)
        .order_by(QuestionQueueItem.created_at.desc())
        .limit(AVOID_STEMS_LIMIT)
        .all()
    ]

    question = None
    for attempt_num in range(MAX_GENERATION_ATTEMPTS):
        candidate = generate_question(
            cert_name=cert.name,
            domain=domain,
            difficulty=difficulty,
            format=format,
            style=style,
            grounding_text=grounding,
            avoid_stems=avoid_stems,
        )
        is_valid, reason = _is_valid_question(candidate, format)
        if is_valid:
            question = candidate
            break
        print(f"  [attempt {attempt_num + 1}/{MAX_GENERATION_ATTEMPTS}] rejected: {reason}")

    if question is None:
        # Couldn't get a well-formed question after retries -- skip
        # this slot for now rather than insert bad data; the next poll
        # cycle will try again.
        return

    db.session.add(
        QuestionQueueItem(
            session_id=None,
            cert_code=cert_code,
            domain=question.get("domain"),
            difficulty=question["difficulty"],
            format=question["format"],
            stem=question["stem"],
            options_json=question["options"],
            correct_json=question["correct"],
            feedback_md=question["feedback_md"],
            status="ready",
        )
    )
    db.session.commit()
    print(
        f"  generated {cert_code} [{format}/{style}] domain={domain} "
        f"difficulty={difficulty} pool={unclaimed_ready_count + 1}/{POOL_SIZE}"
    )


def main():
    with app.app_context():
        db.create_all()
        print("worker: on-demand top-up loop running")
        while True:
            for cert_code in _needed_cert_codes():
                top_up_cert_pool(cert_code)
            time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
