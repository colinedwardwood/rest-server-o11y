#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="restic-exporter.service"
UNIT_SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC_PATH="${UNIT_SRC_DIR}/${SERVICE_NAME}"

UNIT_DST_PATH="/etc/systemd/system/${SERVICE_NAME}"
CONF_DIR="/etc/restic-exporter"
ENV_FILE="${CONF_DIR}/restic-exporter.env"

USER_NAME="restic-exporter"
GROUP_NAME="restic-exporter"

WRAPPER_SRC_PATH="${UNIT_SRC_DIR}/scripts/restic-exporter-run.sh"
WRAPPER_DST_PATH="/usr/local/bin/restic-exporter-run"

usage() {
  cat <<'EOF'
Installs and starts the restic-exporter systemd service.

Requirements:
  - Linux with systemd (systemctl available)
  - git + python3 (installer can bootstrap the exporter checkout + venv)

Usage:
  sudo ./scripts/install-restic-exporter.sh [--project-dir /opt/restic-exporter] [--repo-url URL] [--ref REF] [--no-bootstrap] [--write-env]

Options:
  --project-dir  Path to your restic-exporter project checkout (default: /opt/restic-exporter).
  --repo-url     Git URL for restic-exporter (default: https://github.com/ngosang/restic-exporter.git).
  --ref          Git ref to checkout (tag/branch/commit). If omitted and repo exists, keeps current ref.
  --no-bootstrap Do not clone/update or create a venv; only install the unit + wrapper.
  --write-env    Write /etc/restic-exporter/restic-exporter.env from current env:
                RESTIC_REPOSITORY and RESTIC_PASSWORD (and any RESTIC_* you export).
EOF
}

PROJECT_DIR="/opt/restic-exporter"
REPO_URL="https://github.com/ngosang/restic-exporter.git"
REF=""
BOOTSTRAP="true"
WRITE_ENV="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --ref)
      REF="${2:-}"
      shift 2
      ;;
    --no-bootstrap)
      BOOTSTRAP="false"
      shift
      ;;
    --write-env)
      WRITE_ENV="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found. This installer requires systemd." >&2
  exit 1
fi

if [[ ! -f "${UNIT_SRC_PATH}" ]]; then
  echo "Unit file not found at: ${UNIT_SRC_PATH}" >&2
  exit 1
fi

if [[ ! -f "${WRAPPER_SRC_PATH}" ]]; then
  echo "Wrapper script not found at: ${WRAPPER_SRC_PATH}" >&2
  exit 1
fi

if [[ "${BOOTSTRAP}" == "true" ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "git not found. Install it first: sudo apt update && sudo apt install -y git" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found. Install it first: sudo apt update && sudo apt install -y python3 python3-venv" >&2
    exit 1
  fi

  if [[ ! -d "${PROJECT_DIR}" ]]; then
    install -d -m 0755 -o root -g root "${PROJECT_DIR}"
  fi

  if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
    if [[ -n "$(ls -A "${PROJECT_DIR}" 2>/dev/null || true)" ]]; then
      echo "Project dir exists but is not a git repo and is not empty: ${PROJECT_DIR}" >&2
      echo "Either empty it, point --project-dir elsewhere, or pass --no-bootstrap." >&2
      exit 1
    fi

    if [[ -n "${REF}" ]]; then
      git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${PROJECT_DIR}"
    else
      git clone "${REPO_URL}" "${PROJECT_DIR}"
    fi
  else
    # Update existing repo (best-effort). If --ref is provided, move to it.
    if [[ -n "${REF}" ]]; then
      git -C "${PROJECT_DIR}" fetch --tags --force
      git -C "${PROJECT_DIR}" checkout --force "${REF}"
    else
      git -C "${PROJECT_DIR}" pull --ff-only || true
    fi
  fi

  # Create/refresh venv and install project dependencies into it.
  # This avoids depending on `uv` at service runtime.
  if [[ ! -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
    (cd "${PROJECT_DIR}" && python3 -m venv .venv)
  fi
  "${PROJECT_DIR}/.venv/bin/python" -m pip install --upgrade pip >/dev/null

  # Install runtime dependencies WITHOUT installing the repo as a package.
  #
  # The upstream restic-exporter repo is not structured as an installable wheel/sdist
  # (e.g. it contains top-level directories like `exporter/` and `grafana/`), which
  # makes `pip install /path/to/repo` fail with setuptools' package discovery errors.
  #
  # Instead, read dependencies from pyproject.toml and install those into the venv.
  PYPROJECT="${PROJECT_DIR}/pyproject.toml"
  if [[ ! -f "${PYPROJECT}" ]]; then
    echo "pyproject.toml not found in ${PROJECT_DIR}; cannot determine dependencies." >&2
    echo "Either provide a valid repo checkout or pass --no-bootstrap." >&2
    exit 1
  fi

  deps="$(
    "${PROJECT_DIR}/.venv/bin/python" - "${PYPROJECT}" <<'PY'
import sys
import tomllib

pyproject_path = sys.argv[1]
with open(pyproject_path, "rb") as f:
    data = tomllib.load(f)

deps = data.get("project", {}).get("dependencies", [])
if not isinstance(deps, list):
    raise SystemExit("pyproject.toml: project.dependencies is not a list")

for d in deps:
    # Print one requirement per line for xargs.
    print(d)
PY
  )"

  if [[ -n "${deps}" ]]; then
    # shellcheck disable=SC2086
    printf '%s\n' "${deps}" | xargs -r "${PROJECT_DIR}/.venv/bin/python" -m pip install
  fi

  # Ensure the service user can read the checkout + venv.
  chmod -R a+rX "${PROJECT_DIR}"
fi

if ! getent group "${GROUP_NAME}" >/dev/null 2>&1; then
  groupadd --system "${GROUP_NAME}"
fi

if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  useradd \
    --system \
    --gid "${GROUP_NAME}" \
    --home-dir "/var/lib/restic-exporter" \
    --create-home \
    --shell "/usr/sbin/nologin" \
    "${USER_NAME}"
fi

install -d -m 0750 -o root -g "${GROUP_NAME}" "${CONF_DIR}"

if [[ "${WRITE_ENV}" == "true" ]]; then
  tmp_env="$(mktemp)"
  {
    echo "# Generated by install-restic-exporter.sh on $(date -Is)"
    echo "# Permissions are restricted; edit as needed."
    echo
    echo "# Required:"
    echo "# RESTIC_REPOSITORY=rest:http://127.0.0.1:8000/"
    echo "# RESTIC_PASSWORD=..."
    echo
    echo "# Where the restic-exporter project checkout lives:"
    echo "# RESTIC_EXPORTER_PROJECT_DIR=/opt/restic-exporter"
    echo

    # Copy any RESTIC_* variables from the current environment.
    # This allows you to do:
    #   export RESTIC_REPOSITORY=...
    #   export RESTIC_PASSWORD=...
    #   sudo -E ./scripts/install-restic-exporter.sh --write-env
    env | awk -F= '/^RESTIC_[A-Z0-9_]*=/{print $0}' || true

    # If provided, persist project dir too (helpful for systemd).
    if [[ -n "${PROJECT_DIR}" ]]; then
      echo "RESTIC_EXPORTER_PROJECT_DIR=${PROJECT_DIR}"
    fi
  } >"${tmp_env}"

  install -m 0640 -o root -g "${GROUP_NAME}" "${tmp_env}" "${ENV_FILE}"
  rm -f "${tmp_env}"
else
  if [[ ! -f "${ENV_FILE}" ]]; then
    cat >"${ENV_FILE}" <<'EOF'
# restic-exporter environment
#
# Required:
# RESTIC_REPOSITORY=rest:http://127.0.0.1:8000/
# RESTIC_PASSWORD=change-me
#
# Where the restic-exporter project checkout lives:
# RESTIC_EXPORTER_PROJECT_DIR=/opt/restic-exporter
#
# Optional: override module entrypoint (defaults to exporter.exporter)
# RESTIC_EXPORTER_ENTRYPOINT_MODULE=exporter.exporter
#
# Optional (depends on your exporter implementation):
# RESTIC_CACHE_DIR=/var/lib/restic-exporter
EOF
    chown root:"${GROUP_NAME}" "${ENV_FILE}"
    chmod 0640 "${ENV_FILE}"
  fi
fi

install -m 0755 "${WRAPPER_SRC_PATH}" "${WRAPPER_DST_PATH}"
install -m 0644 "${UNIT_SRC_PATH}" "${UNIT_DST_PATH}"

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo
echo "Installed and started: ${SERVICE_NAME}"
echo "Config file: ${ENV_FILE}"
echo
echo "Useful commands:"
echo "  systemctl status ${SERVICE_NAME} --no-pager"
echo "  journalctl -u ${SERVICE_NAME} -n 200 --no-pager"

