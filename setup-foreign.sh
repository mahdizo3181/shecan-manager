#!/usr/bin/env bash
# setup-foreign.sh - thin wrapper kept for compatibility. The logic now lives in gemini-menu.sh
# (same commands and flags as before: [apply|test|audit] --iran-ip --ss-port --key-file --db
#  --xray-bin --restart-cmd --fix-sniffing --all-domains --dry-run --rollback
#  --restore-full-db --backup-dir --yes).
# For the interactive menu just run: ./gemini-menu.sh
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
menu=$here/gemini-menu.sh
if [[ ! -x $menu ]]; then menu=$(command -v gemini-menu || true); fi
if [[ -z $menu ]]; then
  echo "setup-foreign.sh: gemini-menu.sh was not found next to this script (copy both files together)." >&2
  exit 1
fi
case ${1:-} in
  apply|test|audit) cmd=$1; shift ;;
  *) cmd=apply ;;
esac
exec "$menu" --role foreign --legacy "$cmd" "$@"
