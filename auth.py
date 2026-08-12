"""Session-based login gates for the Salesforce Cert Study tool.

Two tiers, two separate credential pairs:
- Regular login (/login, APP_LOGIN_USERNAME/PASSWORD): shared across
  the whole team, gates session setup/practice/review.
- Admin login (/admin/login, ADMIN_LOGIN_USERNAME/PASSWORD): a
  separate credential that also implies regular access, gates
  /admin/ingest and the contributions review queue. Added when the
  contributions feature made "only admins can do X" something that
  actually needs enforcing, not just a matter of which pages link to
  which -- before that, everyone shared one login and there was no
  real distinction.

Still not real per-user SSO identity -- deferred until the org-wide
multi-user goal is actually pursued (see PLAN.md's Locked-in
decisions). Nothing else in the app keys off of individual identity
(StudySession.user_label is unused so far).
"""
import os
import secrets
from functools import wraps

from flask import redirect, render_template, request, session, url_for


def _credentials_valid(expected_username, expected_password):
    """Timing-safe check against a submitted username/password in the
    current request. expected_username must be non-empty so an
    unconfigured deployment (no env vars set) can't be logged into
    with blank credentials.
    """
    submitted_username = request.form.get("username", "")
    submitted_password = request.form.get("password", "")
    return bool(expected_username) and secrets.compare_digest(
        submitted_username, expected_username
    ) and secrets.compare_digest(submitted_password, expected_password)


def login_required(view):
    """Decorator: redirect to /login (preserving the target path) if
    the session isn't authenticated."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


def admin_required(view):
    """Decorator: redirect to /admin/login (preserving the target
    path) if the session isn't admin-authenticated. Being logged in
    as a regular user is not enough."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("is_admin"):
            return redirect(url_for("admin_login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


def register_auth_routes(app):
    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
            expected_username = os.environ.get("APP_LOGIN_USERNAME", "")
            expected_password = os.environ.get("APP_LOGIN_PASSWORD", "")
            if _credentials_valid(expected_username, expected_password):
                session["logged_in"] = True
                next_path = request.args.get("next") or url_for("session_setup")
                return redirect(next_path)
            error = "Invalid username or password."

        return render_template("login.html", error=error)

    @app.route("/admin/login", methods=["GET", "POST"])
    def admin_login():
        error = None
        if request.method == "POST":
            expected_username = os.environ.get("ADMIN_LOGIN_USERNAME", "")
            expected_password = os.environ.get("ADMIN_LOGIN_PASSWORD", "")
            if _credentials_valid(expected_username, expected_password):
                session["is_admin"] = True
                session["logged_in"] = True
                next_path = request.args.get("next") or url_for("admin_ingest")
                return redirect(next_path)
            error = "Invalid username or password."

        return render_template("admin_login.html", error=error)

    @app.route("/logout")
    def logout():
        session.pop("logged_in", None)
        session.pop("is_admin", None)
        return redirect(url_for("login"))
