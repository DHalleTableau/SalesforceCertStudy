"""Background top-up worker for the Salesforce Cert Study tool.

On-demand top-up (see PLAN.md's Locked-in decisions): while a session
is active and a cert's `question_queue` has fewer than READY_THRESHOLD
`ready` rows, generate the next question via claude_client.py and
insert it. Idle when every active session's queues are full, or no
session is active. This is the only process that calls the model --
app.py never does.
"""
import time
from datetime import datetime, timezone

from app import app
from claude_client import assemble_grounding_text, derive_cert_overview, generate_question
from models import Answer, Cert, QuestionQueueItem, StudySession, db

READY_THRESHOLD = 5
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


def _next_difficulty(session_id, cert_code):
    """Ramp difficulty with how many questions the user has already
    answered for this cert in this session: 1 for the first 3, 2 for
    the next 3, etc., capped at 5.
    """
    answered_count = (
        Answer.query.join(QuestionQueueItem)
        .filter(
            QuestionQueueItem.session_id == session_id,
            QuestionQueueItem.cert_code == cert_code,
        )
        .count()
    )
    return min(5, 1 + answered_count // 3)


def _next_format(ready_count):
    """Simple mix: every 3rd generated question is multi-select.

    Weak-domain targeting (picking `domain` from the user's incorrect-
    answer history) is deferred -- domain=None below lets the model
    choose from the grounding content for now. Refine once there's
    real answer history to target against.
    """
    return "multi" if ready_count % 3 == 2 else "single"


def top_up_session(session):
    """Fill each of session's certs' queues up to READY_THRESHOLD."""
    for cert_code in session.cert_codes:
        ensure_cert_overview(cert_code)

        cert = Cert.query.get(cert_code)
        if cert is None:
            continue

        ready_count = QuestionQueueItem.query.filter_by(
            session_id=session.id, cert_code=cert_code, status="ready"
        ).count()

        while ready_count < READY_THRESHOLD:
            grounding = assemble_grounding_text(cert_code)
            if not grounding:
                break  # nothing to generate from yet -- don't spin forever

            difficulty = _next_difficulty(session.id, cert_code)
            format = _next_format(ready_count)

            question = generate_question(
                cert_name=cert.name,
                domain=None,
                difficulty=difficulty,
                format=format,
                grounding_text=grounding,
            )

            db.session.add(
                QuestionQueueItem(
                    session_id=session.id,
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
            ready_count += 1


def main():
    with app.app_context():
        db.create_all()
        print("worker: on-demand top-up loop running")
        while True:
            for session in StudySession.query.filter_by(status="active").all():
                top_up_session(session)
            time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
