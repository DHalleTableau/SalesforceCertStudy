#!/bin/bash
# Starts worker.py against production, reading secrets from .env.worker
# (gitignored -- create it once from .env.worker.example) instead of
# retyping the env vars every time.
set -e
cd "$(dirname "$0")"

if [ ! -f .env.worker ]; then
  echo "Missing .env.worker -- copy .env.worker.example to .env.worker and fill in real values first."
  exit 1
fi

source .venv/bin/activate
set -a
source .env.worker
set +a
python3 worker.py
