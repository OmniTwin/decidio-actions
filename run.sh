#!/usr/bin/env bash
# Decidio deploy approvals: the one entry point the action runs. `step` picks the script; nothing else is read from it.
set -euo pipefail
case "${DECIDIO_STEP:-}" in
  request) exec bash "$(dirname "$0")/request.sh" ;;
  verify) exec bash "$(dirname "$0")/verify.sh" ;;
  *) echo "::error title=Decidio::step must be request (in the workflow that runs on push) or verify (the first step of the deploy job)" >&2; exit 1 ;;
esac
