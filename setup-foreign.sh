#!/usr/bin/env bash
# setup-foreign.sh - backward-compatible shim. The logic lives in gemini-menu:
#     setup-foreign.sh [flags]         ==  gemini-menu --role foreign apply [flags]
#     setup-foreign.sh test|audit ...  ==  gemini-menu --role foreign test|audit ...
#     setup-foreign.sh --yes test      ==  ... test --yes     (was silently run as `apply`: fixed)
# Run `gemini-menu foreign help` for every command and flag.
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
engine=""
for cand in "$here/dist/gemini-menu.sh" "$(command -v gemini-menu || true)" "$here/gemini-menu.sh"; do
  if [[ -n $cand && -x $cand ]]; then engine=$cand; break; fi
done
if [[ -z $engine ]]; then
  echo "setup-foreign.sh: gemini-menu was not found (build it with ./build.sh, or copy it next to this script)." >&2
  exit 1
fi

has_cmd=0 skip=0
for a in "$@"; do
  if ((skip)); then skip=0; continue; fi
  case $a in
    --role | --foreign-ip | --iran-ip | --ss-port | --key-file | --shecan-url-file | --xray-version | --xray-bin | --backup-dir | --db | --restart-cmd) skip=1 ;;
    -*) ;;
    *) has_cmd=1; break ;;
  esac
done
if ((has_cmd)); then exec "$engine" --role foreign "$@"; fi
exec "$engine" --role foreign apply "$@"
