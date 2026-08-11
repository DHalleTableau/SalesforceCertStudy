"""Simple session-based login gate for the Salesforce Cert Study tool.

Real per-user SSO identity is deferred until the org-wide multi-user
goal is actually pursued (see PLAN.md's Locked-in decisions) -- this
is a single shared username/password, good enough for personal use,
and doesn't block adding real per-user auth later since nothing else
in the app keys off of it (StudySession.user_label is unused so far).
"""
import os
import secrets
from functools import wraps

from flask import redirect, render_template, request, session, url_for


def login_required(view):
    """Decorator: redirect to /login (preserving the target path) if
    the session isn't authenticated."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


def register_auth_routes(app):
    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
            expected_username = os.environ.get("APP_LOGIN_USERNAME", "")
            expected_password = os.environ.get("APP_LOGIN_PASSWORD", "")
            submitted_username = request.form.get("username", "")
            submitted_password = request.form.get("password", "")

            # secrets.compare_digest to avoid a timing side-channel;
            # expected_username must be non-empty so an unconfigured
            # deployment (no env vars set) can't be logged into with
            # blank credentials.
            valid = bool(expected_username) and secrets.compare_digest(
                submitted_username, expected_username
            ) and secrets.compare_digest(submitted_password, expected_password)

            if valid:
                session["logged_in"] = True
                next_path = request.args.get("next") or url_for("session_setup")
                return redirect(next_path)
            error = "Invalid username or password."

        return render_template("login.html", error=error)

    @app.route("/logout")
    def logout():
        session.pop("logged_in", None)
        return redirect(url_for("login"))
