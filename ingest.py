"""Parsing + persistence + fetch helpers for the two Google Sheet tabs.

Both tabs are ingested by paste, not live fetch -- see PLAN.md's
"Locked-in decisions" and "Local Environment Notes" for why. That's a
separate concern from individual Exam_Guide_URL *content* pages
referenced by a resource row, which Tier 1 below tries to fetch
automatically -- those are two different URLs at two different levels.

The parse_* functions are pure (no Flask/DB dependency, sub-steps
2a/2b); the save_* functions write into models.py's SQLAlchemy models
and must be called inside a Flask app context (sub-step 2c); the admin
route wiring these together is in app.py (sub-step 2d). fetch_resource_text
(sub-step 2e) is Tier-1 auto-fetch for individual Exam_Guide_URL pages.
"""
import csv
import io
from html.parser import HTMLParser

# requests is imported lazily inside fetch_resource_text(), not here,
# so the pure parse_* functions above stay testable with plain system
# python3 -- no venv/pip needed (see PLAN.md's Local Environment Notes).


def _normalize_header(name):
    return name.strip().lower().replace(" ", "_")


_PLACEHOLDER_VALUES = {"", "not found", "n/a", "na", "none", "tbd"}


def _clean_url(value):
    """Treat sheet placeholders like "NOT FOUND" (seen on aggregate
    certs, which have no exam guide of their own) the same as blank."""
    if value is None or value.strip().lower() in _PLACEHOLDER_VALUES:
        return None
    return value


def parse_exam_guides_csv(csv_text):
    """Parse the "Exam Guides" tab into one dict per non-blank data row.

    Expected columns (matched case-insensitively, spaces as underscores):
    Certification, Detail_Page_URL, Exam_Guide_URL,
    Aggregate Certification, Base/Extra.

    Cert-level fields (cert_code, detail_page_url, is_aggregate) repeat
    on every row for that cert; a later save step (sub-step 2c) dedupes
    when it upserts into `certs`.
    """
    reader = csv.DictReader(io.StringIO(csv_text))
    rows = []
    for raw_row in reader:
        normalized = {
            _normalize_header(k): (v or "").strip()
            for k, v in raw_row.items()
            if k is not None
        }
        cert_code = normalized.get("certification", "")
        if not cert_code:
            continue  # blank row

        base_extra = normalized.get("base/extra", "").lower()
        role = "primary" if base_extra == "base" else "additional"

        aggregate = normalized.get("aggregate_certification", "").lower()
        is_aggregate = aggregate == "aggregate"

        rows.append(
            {
                "cert_code": cert_code,
                "detail_page_url": _clean_url(normalized.get("detail_page_url")),
                "exam_guide_url": _clean_url(normalized.get("exam_guide_url")),
                "is_aggregate": is_aggregate,
                "role": role,
            }
        )
    return rows


def parse_prerequisites_csv(csv_text):
    """Parse the "Certification Prerequisites" tab into direct edges.

    Expected columns: Certification, PreReq 1..N (any number of PreReq
    columns is supported via prefix match, not hardcoded to 4). Returns
    a list of {"cert_code", "prereq_cert_code"} dicts, one per populated
    PreReq cell. A cert can have multiple prerequisites (multiple edges
    with the same cert_code); chains beyond one level are resolved by
    walking these edges in application code (see PLAN.md), not stored
    here as a flattened closure.
    """
    reader = csv.DictReader(io.StringIO(csv_text))
    edges = []
    for raw_row in reader:
        normalized = {
            _normalize_header(k): (v or "").strip()
            for k, v in raw_row.items()
            if k is not None
        }
        cert_code = normalized.get("certification", "")
        if not cert_code:
            continue  # blank row

        for key, value in normalized.items():
            if key.startswith("prereq") and value:
                edges.append({"cert_code": cert_code, "prereq_cert_code": value})
    return edges


def save_exam_guides(parsed_rows):
    """Upsert parse_exam_guides_csv() output into Cert and Resource.

    Cert-level fields (detail_page_url, exam_guide_url, is_aggregate)
    are deduped across a cert's repeated rows: the primary (Base) row's
    exam_guide_url wins; is_aggregate is true if any row said so.
    Resources are upserted by (cert_code, url) so re-pasting the same
    sheet content is idempotent rather than creating duplicates.

    Must be called inside a Flask app context. Returns the list of
    Cert objects touched.
    """
    from models import db, Cert, Resource

    certs_by_code = {}
    for row in parsed_rows:
        cert_code = row["cert_code"]
        cert = certs_by_code.get(cert_code) or Cert.query.get(cert_code)
        if cert is None:
            cert = Cert(cert_code=cert_code, name=cert_code, is_aggregate=False)
            db.session.add(cert)
        certs_by_code[cert_code] = cert

        if row["detail_page_url"]:
            cert.detail_page_url = row["detail_page_url"]
        if row["role"] == "primary" and row["exam_guide_url"]:
            cert.exam_guide_url = row["exam_guide_url"]
        if row["is_aggregate"]:
            cert.is_aggregate = True

        if row["exam_guide_url"]:
            resource = Resource.query.filter_by(
                cert_code=cert_code, url=row["exam_guide_url"]
            ).first()
            if resource is None:
                db.session.add(
                    Resource(
                        cert_code=cert_code,
                        url=row["exam_guide_url"],
                        role=row["role"],
                    )
                )
            else:
                resource.role = row["role"]

    db.session.commit()
    return list(certs_by_code.values())


def save_prerequisites(parsed_edges):
    """Upsert parse_prerequisites_csv() output into CertPrerequisite.

    Skips an edge if that exact (cert_code, prereq_cert_code) pair
    already exists, so re-pasting the same sheet content is idempotent.

    Also skips (and reports, rather than crashing) any edge whose
    cert_code or prereq_cert_code isn't a known Cert -- a real
    recurring risk with paste-based ingestion: the two tabs can drift
    (a rename, a typo, a cert added to one tab but not the other).
    SQLite silently allowed this dangling reference in earlier local
    testing since it doesn't enforce foreign keys by default; Postgres
    correctly rejects it, which is what surfaced this gap in the first
    place. Must be called inside a Flask app context.

    Returns a list of skipped edges (each with a "reason" key) so the
    caller can surface them instead of silently dropping data.
    """
    from models import db, Cert, CertPrerequisite

    known_codes = {c.cert_code for c in Cert.query.all()}
    skipped = []

    for edge in parsed_edges:
        cert_code = edge["cert_code"]
        prereq_cert_code = edge["prereq_cert_code"]

        if cert_code not in known_codes:
            skipped.append({**edge, "reason": f"'{cert_code}' not found in Exam Guides tab"})
            continue
        if prereq_cert_code not in known_codes:
            skipped.append(
                {**edge, "reason": f"'{prereq_cert_code}' not found in Exam Guides tab"}
            )
            continue

        exists = CertPrerequisite.query.filter_by(
            cert_code=cert_code, prereq_cert_code=prereq_cert_code
        ).first()
        if exists is None:
            db.session.add(CertPrerequisite(**edge))

    db.session.commit()
    return skipped


class _VisibleTextExtractor(HTMLParser):
    """Collects text nodes outside <script>/<style>/<noscript>."""

    _SKIP_TAGS = {"script", "style", "noscript"}

    def __init__(self):
        super().__init__()
        self._skip_depth = 0
        self.chunks = []

    def handle_starttag(self, tag, attrs):
        if tag in self._SKIP_TAGS:
            self._skip_depth += 1

    def handle_endtag(self, tag):
        if tag in self._SKIP_TAGS and self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data):
        if self._skip_depth == 0:
            stripped = data.strip()
            if stripped:
                self.chunks.append(stripped)


def _extract_visible_text(html_text):
    extractor = _VisibleTextExtractor()
    extractor.feed(html_text)
    return "\n".join(extractor.chunks)


def fetch_resource_text(url, timeout=10):
    """Tier-1 auto-fetch: try to retrieve readable text from an
    Exam_Guide_URL content page.

    Returns (status, text):
      - status "fetched", text = extracted readable text, on success.
      - status "blocked_needs_paste", text = None, if the request
        fails, returns a non-200, isn't HTML/plain-text, or the
        extracted text is too short to be real content (a JS-rendered
        shell or login wall typically renders down to almost nothing).

    Only HTML/plain-text is handled -- PDFs and other content types
    are always flagged blocked_needs_paste for now (no PDF-extraction
    dependency yet; the user pastes those via Tier 2 instead).
    """
    import requests

    try:
        response = requests.get(
            url,
            timeout=timeout,
            headers={
                "User-Agent": "Mozilla/5.0 (compatible; SalesforceCertStudyBot/1.0)"
            },
        )
    except requests.RequestException:
        return "blocked_needs_paste", None

    if response.status_code != 200:
        return "blocked_needs_paste", None

    content_type = response.headers.get("Content-Type", "")
    if "html" not in content_type and "text/plain" not in content_type:
        return "blocked_needs_paste", None

    text = _extract_visible_text(response.text)
    if len(text.strip()) < 200:
        return "blocked_needs_paste", None

    return "fetched", text


def fetch_pending_resources():
    """Attempt Tier-1 auto-fetch for every Resource still `pending`.

    Records the outcome on each row (`fetch_status`, `fetched_text`).
    Resources that come back `blocked_needs_paste` are left for the
    user to fill in via the admin screen's per-resource paste box
    (sub-step 2f) -- their `pasted_text` stays None until they do.

    Must be called inside a Flask app context. Returns a
    {"fetched": n, "blocked": n} summary.
    """
    from models import db, Resource

    counts = {"fetched": 0, "blocked": 0}
    for resource in Resource.query.filter_by(fetch_status="pending").all():
        status, text = fetch_resource_text(resource.url)
        resource.fetch_status = status
        if status == "fetched":
            resource.fetched_text = text
            counts["fetched"] += 1
        else:
            counts["blocked"] += 1

    db.session.commit()
    return counts
