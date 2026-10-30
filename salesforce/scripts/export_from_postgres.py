"""Export the Heroku Postgres data into Bulk-API-ready CSVs for the
Salesforce objects in force-app/.

Usage (from the repo root, venv active, on VPN):
    export DATABASE_URL=$(heroku config:get DATABASE_URL -a sf-cert-study)
    python salesforce/scripts/export_from_postgres.py --out salesforce/export
    # or against the local sqlite copy:
    python salesforce/scripts/export_from_postgres.py --db sqlite:///local.db --out salesforce/export

Writes:
    Cert__c.csv              upsert on Cert_Code__c
    Cert_Prerequisite__c.csv upsert on Legacy_Id__c
    Cert_Resource__c.csv     upsert on Legacy_Id__c
    Question__c.csv          upsert on Legacy_Id__c  (all previously generated
                             questions, re-pooled as Ready so new learners get
                             them with zero generation cost; --skip-questions
                             to omit, --only-unused for never-served rows only)

Sessions, answers and contributions are not exported (personal practice
history / admin queue, not needed in the new home).

The output folder is gitignored-worthy: it contains the full study corpus.
"""
import argparse
import csv
import json
import os
import sys

from sqlalchemy import create_engine, text

LTA_MAX = 131072
LTA_MID = 32768


def _clip(value, limit, label, warnings):
    if value is None:
        return ""
    value = str(value)
    if len(value) > limit:
        warnings.append(f"{label}: truncated {len(value)} -> {limit} chars")
        return value[:limit]
    return value


def _write(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)
    print(f"  {os.path.basename(path)}: {len(rows)} rows")


def _json_text(value):
    if value is None:
        return ""
    return value if isinstance(value, str) else json.dumps(value)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.environ.get("DATABASE_URL"))
    ap.add_argument("--out", default="salesforce/export")
    ap.add_argument("--skip-questions", action="store_true")
    ap.add_argument("--only-unused", action="store_true")
    args = ap.parse_args()
    if not args.db:
        sys.exit("Set DATABASE_URL or pass --db")
    db_url = args.db.replace("postgres://", "postgresql://", 1)
    os.makedirs(args.out, exist_ok=True)
    warnings = []
    engine = create_engine(db_url)

    with engine.connect() as conn:
        certs = conn.execute(text(
            "SELECT cert_code, name, is_aggregate, duration_min, num_questions, "
            "passing_score, domains_json, derived_at FROM certs ORDER BY cert_code"
        )).mappings().all()
        _write(
            os.path.join(args.out, "Cert__c.csv"),
            ["Cert_Code__c", "Name", "Is_Aggregate__c", "Duration_Min__c", "Num_Questions__c",
             "Passing_Score__c", "Domains_JSON__c", "Overview_Derived_At__c"],
            [[
                c["cert_code"],
                _clip(c["name"], 80, f"cert {c['cert_code']} name", warnings),
                "true" if c["is_aggregate"] else "false",
                c["duration_min"] if c["duration_min"] is not None else "",
                c["num_questions"] if c["num_questions"] is not None else "",
                c["passing_score"] if c["passing_score"] is not None else "",
                _clip(_json_text(c["domains_json"]), LTA_MID, f"cert {c['cert_code']} domains", warnings),
                c["derived_at"].strftime("%Y-%m-%dT%H:%M:%SZ") if c["derived_at"] else "",
            ] for c in certs],
        )
        known = {c["cert_code"] for c in certs}

        prereqs = conn.execute(text(
            "SELECT id, cert_code, prereq_cert_code FROM cert_prerequisites"
        )).mappings().all()
        rows = []
        for p in prereqs:
            if p["cert_code"] not in known or p["prereq_cert_code"] not in known:
                warnings.append(f"prereq {p['cert_code']} <- {p['prereq_cert_code']}: unknown cert, skipped")
                continue
            rows.append([p["id"], p["cert_code"], p["prereq_cert_code"]])
        _write(
            os.path.join(args.out, "Cert_Prerequisite__c.csv"),
            ["Legacy_Id__c", "Cert__r.Cert_Code__c", "Prereq_Cert__r.Cert_Code__c"],
            rows,
        )

        resources = conn.execute(text(
            "SELECT id, cert_code, url, role, fetched_text, pasted_text FROM resources"
        )).mappings().all()
        rows = []
        empty = 0
        for r in resources:
            if r["cert_code"] not in known:
                warnings.append(f"resource {r['id']}: unknown cert {r['cert_code']}, skipped")
                continue
            content = r["pasted_text"] or r["fetched_text"] or ""
            if not content.strip():
                empty += 1
            url = r["url"] or ""
            if len(url) > 255:
                warnings.append(f"resource {r['id']}: URL over 255 chars, dropped")
                url = ""
            rows.append([
                r["id"], r["cert_code"], url,
                "Primary" if r["role"] == "primary" else "Additional",
                _clip(content, LTA_MAX, f"resource {r['id']} ({r['cert_code']})", warnings),
            ])
        _write(
            os.path.join(args.out, "Cert_Resource__c.csv"),
            ["Legacy_Id__c", "Cert__r.Cert_Code__c", "URL__c", "Role__c", "Content__c"],
            rows,
        )
        if empty:
            print(f"  note: {empty} resources have no content yet (exported anyway, as placeholders)")

        if not args.skip_questions:
            sql = ("SELECT id, cert_code, domain, difficulty, format, stem, options_json, "
                   "correct_json, feedback_md, session_id FROM question_queue")
            if args.only_unused:
                sql += " WHERE session_id IS NULL AND status = 'ready'"
            questions = conn.execute(text(sql)).mappings().all()
            rows = []
            for q in questions:
                if q["cert_code"] not in known:
                    continue
                rows.append([
                    q["id"], q["cert_code"],
                    _clip(q["domain"], 255, f"question {q['id']} domain", warnings),
                    q["difficulty"], q["format"],
                    _clip(q["stem"], LTA_MID, f"question {q['id']} stem", warnings),
                    _clip(_json_text(q["options_json"]), LTA_MID, f"question {q['id']} options", warnings),
                    _json_text(q["correct_json"]),
                    _clip(q["feedback_md"], LTA_MAX, f"question {q['id']} feedback", warnings),
                    "Ready",
                ])
            _write(
                os.path.join(args.out, "Question__c.csv"),
                ["Legacy_Id__c", "Cert__r.Cert_Code__c", "Domain__c", "Difficulty__c", "Format__c",
                 "Stem__c", "Options_JSON__c", "Correct_JSON__c", "Feedback_MD__c", "Status__c"],
                rows,
            )

    if warnings:
        print("\nWarnings:")
        for w in warnings:
            print(f"  - {w}")


if __name__ == "__main__":
    main()
