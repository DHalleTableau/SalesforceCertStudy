"""Flask web app for the Salesforce Cert Study tool.

Phase 1 scope: app boots, connects to Postgres, and creates tables. This
process NEVER calls the Claude API in a request — question generation
lives in worker.py (Phase 3). Login, session setup, the question loop,
and review/export routes are added in later phases per
/Users/daniel.halle/.claude/plans/imperative-launching-lynx.md.
"""
import os

from flask import Flask, jsonify

from models import db


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

    return app


def _database_url():
    """Read DATABASE_URL, falling back to a local SQLite file for quick
    local boot checks. Heroku Postgres URLs use the "postgres://" scheme;
    SQLAlchemy 1.4+ requires "postgresql://".
    """
    url = os.environ.get("DATABASE_URL", "sqlite:///local.db")
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    return url


app = create_app()


if __name__ == "__main__":
    app.run(debug=True)
