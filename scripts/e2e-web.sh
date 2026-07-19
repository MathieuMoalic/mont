#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BACKEND_PORT="${BACKEND_PORT:-6001}"
CHROMEDRIVER_PORT="${CHROMEDRIVER_PORT:-4444}"
BACKEND_BIND="127.0.0.1:${BACKEND_PORT}"
BACKEND_BASE_URL="http://${BACKEND_BIND}"
E2E_PASSWORD="${E2E_PASSWORD:-e2e-password}"
E2E_PASSWORD_HASH='$argon2id$v=19$m=19456,t=2,p=1$/r2D8Aih393Yo6s/cVm2kQ$9LqLDbM91Hcolz3le7ZgTLMYIvbCb42UkWep7xs3uAI'
E2E_HEADED="${E2E_HEADED:-0}"

TMP_DIR="$(mktemp -d)"
BACKEND_LOG="${TMP_DIR}/backend.log"
CHROMEDRIVER_LOG="${TMP_DIR}/chromedriver.log"
BACKEND_PID=""
CHROMEDRIVER_PID=""
FLUTTER_PID=""

cleanup() {
  local exit_code=$?

  if [[ -n "${BACKEND_PID}" ]] && kill -0 "${BACKEND_PID}" 2>/dev/null; then
    kill "${BACKEND_PID}" 2>/dev/null || true
    wait "${BACKEND_PID}" 2>/dev/null || true
  fi

  if [[ -n "${CHROMEDRIVER_PID}" ]] && kill -0 "${CHROMEDRIVER_PID}" 2>/dev/null; then
    kill "${CHROMEDRIVER_PID}" 2>/dev/null || true
    wait "${CHROMEDRIVER_PID}" 2>/dev/null || true
  fi

  if [[ -n "${FLUTTER_PID}" ]] && kill -0 "${FLUTTER_PID}" 2>/dev/null; then
    kill "${FLUTTER_PID}" 2>/dev/null || true
    wait "${FLUTTER_PID}" 2>/dev/null || true
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "E2E failed. Logs directory: ${TMP_DIR}" >&2
    if [[ -f "${BACKEND_LOG}" ]]; then
      echo "--- backend.log (tail) ---" >&2
      tail -n 120 "${BACKEND_LOG}" >&2 || true
    fi
    if [[ -f "${CHROMEDRIVER_LOG}" ]]; then
      echo "--- chromedriver.log (tail) ---" >&2
      tail -n 120 "${CHROMEDRIVER_LOG}" >&2 || true
    fi
  fi

  rm -rf "${TMP_DIR}"
  exit ${exit_code}
}
trap cleanup EXIT INT TERM

port_is_occupied() {
  local port="$1"
  lsof -iTCP:"${port}" -sTCP:LISTEN -t >/dev/null 2>&1
}

wait_for_http_200() {
  local url="$1"
  local timeout_seconds="$2"
  local start
  start="$(date +%s)"

  while true; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout_seconds )); then
      echo "Timeout waiting for ${url}" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_chromedriver() {
  local timeout_seconds="$1"
  local start
  start="$(date +%s)"

  while true; do
    if curl -fsS "http://127.0.0.1:${CHROMEDRIVER_PORT}/status" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout_seconds )); then
      echo "Timeout waiting for ChromeDriver on port ${CHROMEDRIVER_PORT}" >&2
      return 1
    fi
    sleep 0.2
  done
}

if port_is_occupied "${BACKEND_PORT}"; then
  echo "Port ${BACKEND_PORT} is already in use. Refusing to start e2e backend." >&2
  exit 1
fi

if port_is_occupied "${CHROMEDRIVER_PORT}"; then
  echo "Port ${CHROMEDRIVER_PORT} is already in use. Refusing to start ChromeDriver." >&2
  exit 1
fi

if [[ -z "${CHROME_EXECUTABLE:-}" ]]; then
  echo "CHROME_EXECUTABLE is not set. Enter via: nix develop -c just e2e-web" >&2
  exit 1
fi

if [[ ! -x "${CHROME_EXECUTABLE}" ]]; then
  echo "CHROME_EXECUTABLE does not exist or is not executable: ${CHROME_EXECUTABLE}" >&2
  exit 1
fi

if [[ "${E2E_HEADED}" == "1" ]] && [[ -z "${DISPLAY:-}" ]]; then
  echo "E2E_HEADED=1 requires a display server (DISPLAY is not set)." >&2
  exit 1
fi

export MONT_BIND_ADDR="${BACKEND_BIND}"
export MONT_DATABASE_PATH="${TMP_DIR}/mont-e2e.sqlite"
export MONT_LOG_FILE="${BACKEND_LOG}"
export MONT_PASSWORD_HASH="${E2E_PASSWORD_HASH}"
export MONT_JWT_SECRET="mont-e2e-jwt-secret"
unset MONT_GADGETBRIDGE_ZIP
unset MONT_USDA_API_KEY
unset MONT_LLM_API_KEY

(
  cd "${REPO_ROOT}/backend"
  cargo run -- -q
) >"${BACKEND_LOG}" 2>&1 &
BACKEND_PID=$!

chromedriver --port="${CHROMEDRIVER_PORT}" --allowed-ips=127.0.0.1 >"${CHROMEDRIVER_LOG}" 2>&1 &
CHROMEDRIVER_PID=$!

wait_for_http_200 "${BACKEND_BASE_URL}/healthz" 60
wait_for_chromedriver 30

drive_help="$(
  cd "${REPO_ROOT}/flutter"
  flutter drive --help 2>&1
)"

drive_cmd=(
  flutter
  drive
  --driver=test_driver/integration_test.dart
  --target=integration_test/app_test.dart
  -d
  web-server
  --dart-define=API_BASE_URL="${BACKEND_BASE_URL}"
  --dart-define=E2E_TEST_PASSWORD="${E2E_PASSWORD}"
)

if grep -q -- '--browser-name' <<<"${drive_help}"; then
  drive_cmd+=(--browser-name=chrome)
fi

if grep -q -- '--headless' <<<"${drive_help}"; then
  if [[ "${E2E_HEADED}" != "1" ]]; then
    drive_cmd+=(--headless)
  fi
fi

(
  cd "${REPO_ROOT}/flutter"
  "${drive_cmd[@]}"
) &
FLUTTER_PID=$!
wait "${FLUTTER_PID}"
