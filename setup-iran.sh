#!/usr/bin/env bash
# setup-iran.sh - thin wrapper kept for compatibility. The logic now lives in gemini-menu.sh
# (same flags as before: --foreign-ip --ss-port --key-file --shecan-url-file --xray-version
#  --xray-bin --dry-run --rollback --backup-dir --yes, and the `watch` argument).
# For the interactive menu just run: ./gemini-menu.sh
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
menu=$here/gemini-menu.sh
if [[ ! -x $menu ]]; then menu=$(command -v gemini-menu || true); fi
if [[ -z $menu ]]; then
  echo "setup-iran.sh: gemini-menu.sh was not found next to this script (copy both files together)." >&2
  exit 1
fi
if [[ ${1:-} == watch ]]; then exec "$menu" watch; fi
exec "$menu" --role iran setup "$@"
