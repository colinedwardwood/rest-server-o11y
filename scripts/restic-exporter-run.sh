#!/usr/bin/env bash
set -euo pipefail

# A small wrapper intended for systemd ExecStart.
# Prefer running the pinned venv interpreter directly (created by `uv sync` or a manual venv),
# falling back to `uv run` if no venv python is present.

PROJECT_DIR="${RESTIC_EXPORTER_PROJECT_DIR:-/opt/restic-exporter}"
ENTRYPOINT_MODULE="${RESTIC_EXPORTER_ENTRYPOINT_MODULE:-exporter.exporter}"

if [[ ! -d "${PROJECT_DIR}" ]]; then
  echo "RESTIC_EXPORTER_PROJECT_DIR does not exist: ${PROJECT_DIR}" >&2
  exit 1
fi

cd "${PROJECT_DIR}"

if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
  exec "${PROJECT_DIR}/.venv/bin/python" -m "${ENTRYPOINT_MODULE}"
fi

if command -v uv >/dev/null 2>&1; then
  exec uv run -m "${ENTRYPOINT_MODULE}"
fi

cat >&2 <<EOF
Could not run restic-exporter.

Tried:
  - ${PROJECT_DIR}/.venv/bin/python -m ${ENTRYPOINT_MODULE}  (preferred)
  - uv run -m ${ENTRYPOINT_MODULE}

Fix:
  - create a venv in ${PROJECT_DIR} (e.g. run: uv sync), or
  - install uv so it is in PATH for the service.
EOF
exit 1


