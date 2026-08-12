"""SQLAlchemy models for the Salesforce Cert Study App.

Two Heroku processes share these models against one Postgres database:
- `web` (app.py) only ever reads `question_queue` rows that are already
  `ready` and writes `answers`. It never calls the Claude API.
- `worker` (worker.py, added in Phase 3) is the only process that calls
  the Claude API and inserts new `question_queue` rows ahead of demand.

See /Users/daniel.halle/.claude/plans/imperative-launching-lynx.md for the
full architecture this implements.
"""
import uuid
from datetime import datetime, timezone

from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


def _uuid():
    return str(uuid.uuid4())


def utcnow():
    return datetime.now(timezone.utc)


class Resource(db.Model):
    """A single link the user tagged as primary or additional for a cert.

    Populated by ingest.py (Phase 2) from the "Exam Guides" tab of the
    user's Google Sheet: one row per link, `role` = "primary" for rows
    marked Base, "additional" for rows marked Extra. `pasted_text`/
    `fetched_text` hold grounding content: `fetched_text` is filled by
    Tier-1 auto-fetch for plain URLs; `pasted_text` is filled by the user
    for Tier-2 gated/JS-rendered pages the app can't fetch.
    """

    __tablename__ = "resources"

    id = db.Column(db.String, primary_key=True, default=_uuid)
    cert_code = db.Column(db.String, nullable=False, index=True)
    url = db.Column(db.String, nullable=False)
    role = db.Column(db.String, nullable=False)  # "primary" | "additional"
    fetch_status = db.Column(db.String, nullable=False, default="pending")
    # "pending" | "fetched" | "blocked_needs_paste"
    fetched_text = db.Column(db.Text, nullable=True)
    pasted_text = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow)

    def __repr__(self):
        return f"<Resource {self.cert_code} {self.role} {self.url}>"


class Cert(db.Model):
    """Cached overview metadata for one certification exam.

    Derived by worker.py (Phase 3) from the cert's primary Exam Guide
    resource(s) the first time a session for that cert starts, then
    cached here so it isn't re-derived every session.

    `is_aggregate` mirrors the "Aggregate Certification" column: an
    aggregate cert has no exam of its own and is earned automatically
    once its prerequisites (see CertPrerequisite) are met, so question
    generation for it draws entirely from those prerequisites rather
    than from this cert's own (nonexistent) exam guide.
    """

    __tablename__ = "certs"

    cert_code = db.Column(db.String, primary_key=True)
    name = db.Column(db.String, nullable=False)
    detail_page_url = db.Column(db.String, nullable=True)
    exam_guide_url = db.Column(db.String, nullable=True)
    is_aggregate = db.Column(db.Boolean, nullable=False, default=False)
    duration_min = db.Column(db.Integer, nullable=True)
    num_questions = db.Column(db.Integer, nullable=True)
    passing_score = db.Column(db.Integer, nullable=True)  # percent
    domains_json = db.Column(db.JSON, nullable=True)  # [{name, weight_pct}]
    derived_at = db.Column(db.DateTime(timezone=True), nullable=True)

    prerequisites = db.relationship(
        "CertPrerequisite",
        foreign_keys="CertPrerequisite.cert_code",
        backref="cert",
        lazy="dynamic",
    )

    def __repr__(self):
        return f"<Cert {self.cert_code} aggregate={self.is_aggregate}>"


class CertPrerequisite(db.Model):
    """One direct edge: `cert_code` requires `prereq_cert_code` first.

    Mirrors the "Certification Prerequisites" sheet tab (PreReq 1-4
    columns become one row each). Chains are resolved by walking this
    table recursively in application code (Phase 4 session setup) since
    a prerequisite can itself have further prerequisites and/or be
    flagged aggregate on `Cert.is_aggregate` — there is no flattened
    closure stored here, only direct edges.
    """

    __tablename__ = "cert_prerequisites"

    id = db.Column(db.String, primary_key=True, default=_uuid)
    cert_code = db.Column(
        db.String, db.ForeignKey("certs.cert_code"), nullable=False, index=True
    )
    prereq_cert_code = db.Column(
        db.String, db.ForeignKey("certs.cert_code"), nullable=False
    )

    prereq_cert = db.relationship("Cert", foreign_keys=[prereq_cert_code])

    def __repr__(self):
        return f"<CertPrerequisite {self.cert_code} <- {self.prereq_cert_code}>"


class StudySession(db.Model):
    """One practice run. May cover one or both certs at once."""

    __tablename__ = "sessions"

    id = db.Column(db.String, primary_key=True, default=_uuid)
    user_label = db.Column(db.String, nullable=False, default="default")
    cert_codes = db.Column(db.JSON, nullable=False)  # e.g. ["AI-201"]
    started_at = db.Column(db.DateTime(timezone=True), default=utcnow)
    status = db.Column(db.String, nullable=False, default="active")
    # "active" | "ended"

    queue_items = db.relationship(
        "QuestionQueueItem", backref="session", lazy="dynamic"
    )
    answers = db.relationship("Answer", backref="session", lazy="dynamic")

    def __repr__(self):
        return f"<StudySession {self.id} {self.cert_codes} {self.status}>"


class QuestionQueueItem(db.Model):
    """One pre-generated question + its full-detail answer.

    Written only by worker.py. `status` moves ready -> served -> answered
    as the web app hands it out and records a response; web never writes
    stem/options/feedback here.
    """

    __tablename__ = "question_queue"

    id = db.Column(db.String, primary_key=True, default=_uuid)
    session_id = db.Column(
        db.String, db.ForeignKey("sessions.id"), nullable=False, index=True
    )
    cert_code = db.Column(db.String, nullable=False)
    domain = db.Column(db.String, nullable=True)
    difficulty = db.Column(db.Integer, nullable=False, default=1)  # 1-5, ramps up
    format = db.Column(db.String, nullable=False)  # "single" | "multi"
    stem = db.Column(db.Text, nullable=False)
    options_json = db.Column(db.JSON, nullable=False)  # [{"key": "A", "text": "..."}, ...]
    correct_json = db.Column(db.JSON, nullable=False)  # ["A"] or ["B", "D"]
    feedback_md = db.Column(db.Text, nullable=False)  # long-form: why correct + why each wrong option is wrong
    status = db.Column(db.String, nullable=False, default="ready", index=True)
    # "ready" | "served" | "answered"
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow)
    served_at = db.Column(db.DateTime(timezone=True), nullable=True)

    def __repr__(self):
        return f"<QuestionQueueItem {self.cert_code} {self.status}>"


class Contribution(db.Model):
    """A regular user's suggested study material for a cert -- a URL
    or an uploaded file, plus an optional note. Submitted via
    /contribute, reviewed only by an admin via /admin/contributions.
    Submitting here never touches Resource/grounding content directly
    -- the admin still imports it manually (paste flow in
    /admin/ingest) after reviewing, same as any other source.

    file_content stores the uploaded file's raw bytes directly in
    Postgres (no new infrastructure) -- fine for occasional small/
    medium study-guide uploads; capped at request level by Flask's
    MAX_CONTENT_LENGTH, not enforced here.
    """

    __tablename__ = "contributions"

    id = db.Column(db.String, primary_key=True, default=_uuid)
    cert_code = db.Column(db.String, nullable=False, index=True)
    contributor_name = db.Column(db.String, nullable=True)
    url = db.Column(db.String, nullable=True)
    file_name = db.Column(db.String, nullable=True)
    file_content = db.Column(db.LargeBinary, nullable=True)
    note = db.Column(db.Text, nullable=True)
    status = db.Column(db.String, nullable=False, default="pending", index=True)
    # "pending" | "reviewed"
    submitted_at = db.Column(db.DateTime(timezone=True), default=utcnow)

    def __repr__(self):
        return f"<Contribution {self.cert_code} {self.status}>"


class Answer(db.Model):
    """A recorded response to one served question. Source for review + CSV export."""

    __tablename__ = "answers"

    id = db.Column(db.String, primary_key=True, default=_uuid)
    session_id = db.Column(
        db.String, db.ForeignKey("sessions.id"), nullable=False, index=True
    )
    question_id = db.Column(
        db.String, db.ForeignKey("question_queue.id"), nullable=False
    )
    user_answer_json = db.Column(db.JSON, nullable=False)  # ["A"] or ["B", "D"]
    is_correct = db.Column(db.Boolean, nullable=False)
    answered_at = db.Column(db.DateTime(timezone=True), default=utcnow)

    question = db.relationship("QuestionQueueItem")

    def __repr__(self):
        return f"<Answer {self.question_id} correct={self.is_correct}>"
