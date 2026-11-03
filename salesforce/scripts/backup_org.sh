#!/usr/bin/env bash
# Back up the Cert Study data from the org to dated CSV files.
#
# Run from the salesforce/ folder:
#   bash scripts/backup_org.sh [target-org-alias]      (default alias: certstudy)
#
# Output: backups/YYYY-MM-DD/*.csv  (gitignored: holds the full study corpus)
#   Content (restorable with scripts/restore_from_backup.py):
#     Cert, Cert_Prerequisite, Cert_Resource, Question
#   History (read-only archive, NOT restored: points at org-specific users):
#     Study_Session, Answer
set -euo pipefail

ORG="${1:-certstudy}"
OUT="backups/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

export_obj() {
  local name="$1" query="$2"
  echo "Exporting $name ..."
  sf data export bulk --query "$query" --output-file "$OUT/$name.csv" \
    --result-format csv --line-ending LF --wait 10 --target-org "$ORG"
}

export_obj Cert "SELECT Name, Cert_Code__c, Is_Aggregate__c, Duration_Min__c, Num_Questions__c, Passing_Score__c, Domains_JSON__c, Overview_Derived_At__c FROM Cert__c"
export_obj Cert_Prerequisite "SELECT Cert__r.Cert_Code__c, Prereq_Cert__r.Cert_Code__c, Legacy_Id__c FROM Cert_Prerequisite__c"
export_obj Cert_Resource "SELECT Cert__r.Cert_Code__c, URL__c, Role__c, Content__c, Legacy_Id__c FROM Cert_Resource__c"
export_obj Question "SELECT Cert__r.Cert_Code__c, Domain__c, Difficulty__c, Style__c, Format__c, Stem__c, Options_JSON__c, Correct_JSON__c, Feedback_MD__c, Status__c, Legacy_Id__c FROM Question__c"
export_obj Study_Session "SELECT Id, User_Key__c, User__c, Cert_Codes__c, Mode__c, Status__c, Started_At__c, Completed_At__c, Last_Activity__c, Question_Target__c, Time_Limit_Min__c, Timer_Mode__c, Elapsed_Seconds__c FROM Study_Session__c"
export_obj Answer "SELECT Study_Session__c, Question__c, Question__r.Stem__c, User_Answer__c, Is_Correct__c, Answered_At__c FROM Answer__c"

echo
echo "Row counts:"
python3 -I - "$OUT" <<'PY'
import csv, glob, os, sys
csv.field_size_limit(sys.maxsize)
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.csv"))):
    with open(path, newline="", encoding="utf-8") as f:
        n = sum(1 for _ in csv.DictReader(f))
    print(f"  {os.path.basename(path):<28} {n}")
PY
echo "Done: $OUT"
