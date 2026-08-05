"""Background top-up worker for the Salesforce Cert Study tool.

Placeholder for Phase 1 so the Procfile's `worker` process boots cleanly.
Phase 3 fills this in with the real on-demand top-up loop: while a
session is active and its `question_queue` has fewer than ~5 `ready`
rows, call the Claude API (claude_client.py) to generate the next
question + full-detail answer. Idle when the queue is full or no
session is active. See
/Users/daniel.halle/.claude/plans/imperative-launching-lynx.md.
"""
import time

from models import db
from app import app


def main():
    with app.app_context():
        db.create_all()
    print("worker: Phase 1 stub running. Top-up logic lands in Phase 3.")
    while True:
        time.sleep(30)


if __name__ == "__main__":
    main()
