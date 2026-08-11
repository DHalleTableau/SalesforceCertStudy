"""Flask web app for the Salesforce Cert Study tool.

This process NEVER calls the Claude API in a request — question
generation lives in worker.py (Phase 3). Login, session setup, the
question loop, and review/export routes are added in later phases; see
PLAN.md for the full architecture and phase breakdown.
"""
import csv
import io
import json
import os

from dotenv import load_dotenv

load_dotenv()

from flask import Flask, Response, jsonify, redirect, render_template, request, url_for

from auth import login_required, register_auth_routes
from cert_resolution import resolve_certs
from ingest import (
    fetch_pending_resources,
    parse_exam_guides_csv,
    parse_prerequisites_csv,
    save_exam_guides,
    save_prerequisites,
)
from models import Answer, Cert, QuestionQueueItem, StudySession, db, Resource, utcnow


def create_app():
    app = Flask(__name__)
    app.config["SQLALCHEMY_DATABASE_URI"] = _database_url()
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    app.config["SECRET_KEY"] = os.environ.get(
        "FLASK_SECRET_KEY", "dev-only-not-secure"
    )

    db.init_app(app)

    with app.app_context():
        db.create_all()

    register_auth_routes(app)

    @app.route("/healthz")
    def healthz():
        return jsonify(status="ok")

    @app.route("/admin/ingest", methods=["GET", "POST"])
    @login_required
    def admin_ingest():
        summary = None
        if request.method == "POST":
            exam_guide_rows = parse_exam_guides_csv(
                request.form.get("exam_guides_csv", "")
            )
            certs_touched = save_exam_guides(exam_guide_rows)

            prereq_edges = parse_prerequisites_csv(
                request.form.get("prerequisites_csv", "")
            )
            skipped_prereq_edges = save_prerequisites(prereq_edges)

            fetch_counts = fetch_pending_resources()

            summary = {
                "exam_guide_rows": len(exam_guide_rows),
                "certs_touched": len(certs_touched),
                "prereq_edges": len(prereq_edges),
                "skipped_prereq_edges": skipped_prereq_edges,
                "fetched": fetch_counts["fetched"],
                "blocked": fetch_counts["blocked"],
            }

        blocked_resources = (
            Resource.query.filter_by(fetch_status="blocked_needs_paste")
            .order_by(Resource.cert_code)
            .all()
        )

        return render_template(
            "admin_ingest.html", summary=summary, blocked_resources=blocked_resources
        )

    @app.route("/admin/ingest/paste-resource", methods=["POST"])
    @login_required
    def admin_paste_resource():
        resource_id = request.form.get("resource_id")
        pasted_text = request.form.get("pasted_text", "").strip()
        resource = Resource.query.get(resource_id) if resource_id else None
        if resource is not None and pasted_text:
            resource.pasted_text = pasted_text
            db.session.commit()
        return redirect(url_for("admin_ingest"))

    @app.route("/session/setup", methods=["GET", "POST"])
    @login_required
    def session_setup():
        if request.method == "GET":
            certs = Cert.query.order_by(Cert.name).all()
            return render_template("session_setup.html", certs=certs, prompt=None)

        selected_cert_codes = request.form.getlist("cert_codes")
        answered_prompts = json.loads(request.form.get("answered_json", "{}"))

        prompt_cert_code = request.form.get("prompt_cert_code")
        if prompt_cert_code:
            answered_prompts[prompt_cert_code] = request.form.get("answer") == "yes"

        result = resolve_certs(selected_cert_codes, answered_prompts)

        if result["pending_prompt"]:
            prompt_cert = Cert.query.get(result["pending_prompt"])
            return render_template(
                "session_setup.html",
                certs=None,
                prompt=prompt_cert,
                selected_cert_codes=selected_cert_codes,
                answered_json=json.dumps(answered_prompts),
            )

        study_session = StudySession(cert_codes=result["resolved"], status="active")
        db.session.add(study_session)
        db.session.commit()

        return redirect(url_for("session_overview", session_id=study_session.id))

    @app.route("/session/<session_id>/overview")
    @login_required
    def session_overview(session_id):
        study_session = StudySession.query.get_or_404(session_id)
        certs = [
            Cert.query.get(cert_code) for cert_code in study_session.cert_codes
        ]
        certs = [c for c in certs if c is not None]
        return render_template(
            "session_overview.html", session=study_session, certs=certs
        )

    @app.route("/session/<session_id>/question")
    @login_required
    def session_question(session_id):
        study_session = StudySession.query.get_or_404(session_id)
        if study_session.status != "active":
            return redirect(url_for("session_review", session_id=session_id))
        question = _serve_next_ready_question(session_id)
        return render_template(
            "question.html", session=study_session, question=question, feedback=None
        )

    @app.route("/session/<session_id>/end", methods=["POST"])
    @login_required
    def session_end(session_id):
        study_session = StudySession.query.get_or_404(session_id)
        study_session.status = "ended"
        db.session.commit()
        return redirect(url_for("session_review", session_id=session_id))

    @app.route("/session/<session_id>/answer", methods=["POST"])
    @login_required
    def session_answer(session_id):
        study_session = StudySession.query.get_or_404(session_id)
        question = QuestionQueueItem.query.get_or_404(request.form.get("question_id"))
        selected = request.form.getlist("selected")

        is_correct = set(selected) == set(question.correct_json)

        db.session.add(
            Answer(
                session_id=session_id,
                question_id=question.id,
                user_answer_json=selected,
                is_correct=is_correct,
            )
        )
        question.status = "answered"
        db.session.commit()

        feedback = {
            "is_correct": is_correct,
            "feedback_md": question.feedback_md,
            "correct_json": question.correct_json,
        }
        next_question = _serve_next_ready_question(session_id)

        return render_template(
            "question.html",
            session=study_session,
            question=next_question,
            feedback=feedback,
        )

    @app.route("/session/<session_id>/review")
    @login_required
    def session_review(session_id):
        study_session = StudySession.query.get_or_404(session_id)
        filter_value = request.args.get("filter", "both")
        answers = _get_review_answers(session_id, filter_value)
        rows = [_build_review_row(answer) for answer in answers]
        return render_template(
            "review.html",
            session=study_session,
            rows=rows,
            filter_value=filter_value,
        )

    @app.route("/session/<session_id>/export.csv")
    @login_required
    def session_export_csv(session_id):
        study_session = StudySession.query.get_or_404(session_id)
        filter_value = request.args.get("filter", "both")
        answers = _get_review_answers(session_id, filter_value)

        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(
            [
                "Question",
                "Certification",
                "Your Answer",
                "Correct Answer",
                "Domain",
                "Correct?",
                "Explanation",
            ]
        )
        for answer in answers:
            row = _build_review_row(answer)
            writer.writerow(
                [
                    row["stem"],
                    row["cert_code"],
                    row["your_answer"],
                    row["correct_answer"],
                    row["domain"],
                    "Yes" if row["is_correct"] else "No",
                    row["feedback_md"],
                ]
            )

        first_question = (
            QuestionQueueItem.query.filter_by(session_id=session_id)
            .order_by(QuestionQueueItem.created_at.asc())
            .first()
        )
        # "Session start" for naming purposes is when questions actually
        # started generating, not StudySession.started_at (set at
        # creation, before anything's been generated yet) -- falls back
        # to started_at for the edge case of exporting before any
        # question has ever been generated.
        start_time = (
            first_question.created_at if first_question else study_session.started_at
        )
        filename = f"SalesforceCertStudy-{start_time.strftime('%Y%m%d-%H%M')}.csv"

        return Response(
            buffer.getvalue(),
            mimetype="text/csv",
            headers={
                "Content-Disposition": f'attachment; filename="{filename}"'
            },
        )

    return app


def _get_review_answers(session_id, filter_value):
    """Answers for a session, optionally filtered to right/wrong,
    newest first. Shared by the review screen (4f) and CSV export
    (4g) so both apply identical filtering logic.
    """
    query = Answer.query.filter_by(session_id=session_id)
    if filter_value == "right":
        query = query.filter_by(is_correct=True)
    elif filter_value == "wrong":
        query = query.filter_by(is_correct=False)
    return query.order_by(Answer.answered_at.desc()).all()


def _option_texts(question, keys):
    """Map option keys (e.g. ["A", "C"]) to "<key>. <text>" (e.g.
    "A. Chunking"), for a given QuestionQueueItem -- review/export
    keep the letter alongside the text so it's easy to cross-reference
    against the explanation column, which refers to options by letter.
    """
    lookup = {opt["key"]: opt["text"] for opt in question.options_json}
    return [f"{key}. {lookup.get(key, '?')}" for key in keys]


def _build_review_row(answer):
    """Shared view-model for one review row: resolves option keys to
    their text and pulls in the full explanation, so both the review
    screen and CSV export show the same usable-as-a-study-guide detail
    rather than just letters and a right/wrong flag.
    """
    question = answer.question
    return {
        "stem": question.stem,
        "cert_code": question.cert_code,
        "your_answer": ", ".join(_option_texts(question, answer.user_answer_json)),
        "correct_answer": ", ".join(_option_texts(question, question.correct_json)),
        "domain": question.domain or "",
        "is_correct": answer.is_correct,
        "feedback_md": question.feedback_md,
    }


def _serve_next_ready_question(session_id):
    """Instantly serve the oldest `ready` QuestionQueueItem for a
    session, marking it `served`. No model call here -- if this
    returns None, nothing is `ready` yet and the caller shows a
    "waiting" state; the (separately running) worker fills the queue
    in the background, never in this request path.
    """
    question = (
        QuestionQueueItem.query.filter_by(session_id=session_id, status="ready")
        .order_by(QuestionQueueItem.created_at)
        .first()
    )
    if question is not None:
        question.status = "served"
        question.served_at = utcnow()
        db.session.commit()
    return question


def _database_url():
    """Read DATABASE_URL, falling back to a local SQLite file for quick
    local boot checks. Heroku Postgres URLs use the "postgres://" scheme;
    SQLAlchemy 1.4+ requires "postgresql://".

    The fallback path is anchored to this file's own directory (not a
    relative "sqlite:///local.db", which Flask resolves against its
    guessed instance_path -- that landed local.db in a surprising place
    when this app was launched via an absolute path from a different
    working directory).
    """
    url = os.environ.get("DATABASE_URL")
    if not url:
        default_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "local.db"
        )
        return f"sqlite:///{default_path}"
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    return url


app = create_app()


if __name__ == "__main__":
    app.run(debug=True)
