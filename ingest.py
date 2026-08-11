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

# playwright/trafilatura are imported lazily inside the fetch
# functions, not here, so the pure parse_* functions above stay
# testable with plain system python3 -- no venv/pip needed (see
# PLAN.md's Local Environment Notes).

_MIN_FETCHED_TEXT_LEN = 200


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


def _extract_page_text(page, url, timeout):
    """Navigate an already-open Playwright page to url and extract its
    main content with trafilatura. Returns (status, text) in the same
    contract as fetch_resource_text/fetch_pending_resources.

    A real browser (not requests + a tag-stripper) is required here --
    Salesforce's real Exam Guide URLs are JS-rendered Experience Cloud
    pages that return a near-empty loading shell to a plain HTTP GET
    (0/86 success rate with the old requests-based approach; see
    HISTORY.md). trafilatura.extract with favor_recall=True is a real
    main-content extractor, not the old hand-rolled HTMLParser that
    kept every nav/boilerplate text node too.
    """
    import trafilatura
    from playwright.sync_api import TimeoutError as PlaywrightTimeoutError

    try:
        page.goto(url, wait_until="networkidle", timeout=timeout * 1000)
        try:
            page.wait_for_selector("h1, h2", timeout=timeout * 1000)
        except PlaywrightTimeoutError:
            pass
        rendered_html = page.content()
    except Exception as e:
        print(f"  [fetch] exception loading {url}: {e!r}")
        return "blocked_needs_paste", None

    extracted = trafilatura.extract(
        rendered_html, output_format="json", with_metadata=True, favor_recall=True,
    )
    if not extracted:
        return "blocked_needs_paste", None

    import json

    text = (json.loads(extracted).get("text") or "").strip()
    if len(text) < _MIN_FETCHED_TEXT_LEN:
        return "blocked_needs_paste", None

    return "fetched", text


def fetch_resource_text(url, timeout=10):
    """Tier-1 auto-fetch: try to retrieve readable text from an
    Exam_Guide_URL content page, using a real headless browser so
    JS-rendered pages actually render before extraction.

    Returns (status, text):
      - status "fetched", text = extracted readable text, on success.
      - status "blocked_needs_paste", text = None, on any failure
        (navigation error/timeout, or extracted text too short to be
        real content -- a JS-rendered shell or login wall typically
        renders down to almost nothing even with a real browser).

    Single-URL entry point: opens and closes its own browser. Batch
    callers should use fetch_pending_resources, which shares one
    browser across every resource instead of relaunching per URL.
    """
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(user_agent=(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
        ))
        try:
            return _extract_page_text(page, url, timeout)
        finally:
            browser.close()


def fetch_pending_resources(timeout=10):
    """Attempt Tier-1 auto-fetch for every Resource that either hasn't
    been attempted yet (`pending`) or previously came back
    `blocked_needs_paste` with no manual paste supplied since --
    giving already-blocked resources a real second attempt with this
    fetch method rather than leaving them permanently stuck from an
    earlier failed attempt. Never touches a resource that already has
    real `pasted_text`, whatever its fetch_status.

    Records the outcome on each row (`fetch_status`, `fetched_text`).
    Resources that come back `blocked_needs_paste` are left for the
    user to fill in via the admin screen's per-resource paste box.

    Shares one browser across the whole batch (opening a new page per
    URL, not a new browser per URL) -- for ~86 resources, relaunching
    Chromium per URL would be needlessly slow.

    Must be called inside a Flask app context. Returns a
    {"fetched": n, "blocked": n} summary.
    """
    from playwright.sync_api import sync_playwright
    from models import db, Resource

    resources = Resource.query.filter(
        db.or_(
            Resource.fetch_status == "pending",
            db.and_(
                Resource.fetch_status == "blocked_needs_paste",
                Resource.pasted_text.is_(None),
            ),
        )
    ).all()

    counts = {"fetched": 0, "blocked": 0}
    if not resources:
        return counts

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            for resource in resources:
                page = browser.new_page(user_agent=(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
                ))
                try:
                    status, text = _extract_page_text(page, resource.url, timeout)
                finally:
                    page.close()

                resource.fetch_status = status
                if status == "fetched":
                    resource.fetched_text = text
                    counts["fetched"] += 1
                else:
                    counts["blocked"] += 1
        finally:
            browser.close()

    db.session.commit()
    return counts
