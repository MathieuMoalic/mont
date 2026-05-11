#!/usr/bin/env bash
set -euo pipefail

# Seeds a dev DB with a vegan fruit/veg catalog.
#
# Usage:
#   backend/scripts/seed_foods_dev.sh [path/to/mont.sqlite]
#
# If no DB path is provided, it uses:
# - $MONT_DATABASE_PATH if set
# - otherwise "mont.sqlite" (same default as the backend)

DB_PATH="${1:-${MONT_DATABASE_PATH:-mont.sqlite}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/seed_foods_vegan.sql"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is not installed; cannot seed ${DB_PATH}" >&2
  exit 1
fi

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "Missing seed file: ${SQL_FILE}" >&2
  exit 1
fi

# Ensure the DB exists. Migrations should be applied by the backend on startup.
touch "${DB_PATH}"

sqlite3 "${DB_PATH}" < "${SQL_FILE}"
echo "Seeded foods into ${DB_PATH}"

