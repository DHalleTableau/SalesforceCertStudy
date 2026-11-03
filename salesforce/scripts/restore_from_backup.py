#!/usr/bin/env python3
"""Turn a backup (scripts/backup_org.sh) into load-ready CSVs for an EMPTY org.

Run from the salesforce/ folder:
    python3 scripts/restore_from_backup.py backups/2026-11-03

Writes restore/<same-date>/*.csv and prints the exact `sf` commands to run, in
order. Parents are matched by Cert_Code__c (never by record Id), so this works
in a brand-new org after you have deployed force-app/ and assigned the
CertStudy_Admin permission set to the loading user.

What it restores: Cert, Cert_Prerequisite, Cert_Resource, Question.
What it does NOT restore: Study_Session / Answer (learner history). Those point
at users of the old org; keep the CSVs as an archive.

Questions that were Served/Answered in the old org come back as Ready (without
their session), so they can be served again. Retired stays Retired.
"""
import csv
import os
import sys

csv.field_size_limit(sys.maxsize)

# (backup file, restore file, sobject, columns to keep, in load order)
PLAN = [
    ("Cert", "Cert__c",
     ["Name", "Cert_Code__c", "Is_Aggregate__c", "Duration_Min__c", "Num_Questions__c",
      "Passing_Score__c", "Domains_JSON__c", "Overview_Derived_At__c"]),
    ("Cert_Prerequisite", "Cert_Prerequisite__c",
     ["Cert__r.Cert_Code__c", "Prereq_Cert__r.Cert_Code__c", "Legacy_Id__c"]),
    ("Cert_Resource", "Cert_Resource__c",
     ["Cert__r.Cert_Code__c", "URL__c", "Role__c", "Content__c", "Legacy_Id__c"]),
    ("Question", "Question__c",
     ["Cert__r.Cert_Code__c", "Domain__c", "Difficulty__c", "Style__c", "Format__c", "Stem__c",
      "Options_JSON__c", "Correct_JSON__c", "Feedback_MD__c", "Status__c", "Legacy_Id__c"]),
]


def read(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit(__doc__)
    src = sys.argv[1].rstrip("/")
    out_dir = os.path.join("restore", os.path.basename(src))
    os.makedirs(out_dir, exist_ok=True)

    cert_codes = {r["Cert_Code__c"] for r in read(os.path.join(src, "Cert.csv")) if r.get("Cert_Code__c")}
    if not cert_codes:
        sys.exit("Cert.csv has no rows; refusing to build a restore.")

    commands = []
    for backup_name, sobject, cols in PLAN:
        rows = read(os.path.join(src, backup_name + ".csv"))
        kept, skipped = [], 0
        for r in rows:
            row = {c: r.get(c, "") for c in cols}
            # Every parent reference must name a cert that exists in this backup.
            parents = [c for c in cols if c.endswith("__r.Cert_Code__c")]
            if any(row[c] not in cert_codes for c in parents):
                skipped += 1
                continue
            if sobject == "Question__c" and row["Status__c"] != "Retired":
                row["Status__c"] = "Ready"
            kept.append(row)

        path = os.path.join(out_dir, sobject + ".csv")
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=cols, lineterminator="\n")
            w.writeheader()
            w.writerows(kept)
        print(f"{sobject:<22} {len(kept):>6} rows written" + (f"  ({skipped} skipped: missing/unknown cert)" if skipped else ""))

        if sobject == "Cert__c":
            cmd = (f"sf data upsert bulk --sobject Cert__c --file {path} --external-id Cert_Code__c "
                   "--line-ending LF --wait 10 --target-org certstudy")
        else:
            cmd = (f"sf data import bulk --sobject {sobject} --file {path} "
                   "--line-ending LF --wait 10 --target-org certstudy")
        commands.append(cmd)

    print("\nRun these in order (empty org only; the child loads INSERT and would duplicate on a rerun):\n")
    for c in commands:
        print(c)
    print("\nAfterwards: run CertStudyTest to confirm, and check that Cert__c.Grounding_Chars__c "
          "is populated (the resource trigger sets it); if not, re-save the resources.")


if __name__ == "__main__":
    main()
