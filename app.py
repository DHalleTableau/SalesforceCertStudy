"""Flask web app for the Salesforce Cert Study tool.

This process NEVER calls the Claude API in a request — question
generation lives in worker.py (Phase 3). Login, session setup, the
question loop, and review/export routes are added in later phases; see
PLAN.md for the full architecture and phase breakdown.
"""
import os

from flask import Flask, jsonify, redirect, render_template, request, url_for

from ingest import (
    fetch_pending_resources,
    parse_exam_guides_csv,
    parse_prerequisites_csv,
    save_exam_guides,
    save_prerequisites,
)
from models import db, Resource


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

    @app.route("/healthz")
    def healthz():
        return jsonify(status="ok")

    @app.route("/admin/ingest", methods=["GET", "POST"])
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
            save_prerequisites(prereq_edges)

            fetch_counts = fetch_pending_resources()

            summary = {
                "exam_guide_rows": len(exam_guide_rows),
                "certs_touched": len(certs_touched),
                "prereq_edges": len(prereq_edges),
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
    def admin_paste_resource():
        resource_id = request.form.get("resource_id")
        pasted_text = request.form.get("pasted_text", "").strip()
        resource = Resource.query.get(resource_id) if resource_id else None
        if resource is not None and pasted_text:
            resource.pasted_text = pasted_text
            db.session.commit()
        return redirect(url_for("admin_ingest"))

    return app


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
