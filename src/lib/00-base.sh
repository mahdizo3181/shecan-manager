# shellcheck shell=bash
# 00-base.sh - shared globals, temp dir, traps, fatal errors (start-up problems only).
#
# Library rules (all files in src/lib):
#   * no `set -e` here. The entry file decides shell options. Actions get errexit from act_run.
#   * everything must be `set -u` clean.
#   * return data through variables named by the caller (namerefs) or through stdout, never
#     through hidden globals that another screen might overwrite.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "bash 4.3 or newer is required (this is $BASH_VERSION)" >&2
  exit 1
fi
shopt -s extglob

GM_APP=${GM_APP:-gemini-menu}
GM_VERSION=${GM_VERSION:-0.1.0-phase1}
GM_DRY=${GM_DRY:-0}          # 1 = dry-run: actions describe instead of change
GM_YES=${GM_YES:-0}          # 1 = --yes: plain confirmations are auto-accepted
GM_INT=0                     # set to 1 by the SIGINT handler (Ctrl-C) in the main shell
GM_TMP=""

# Fatal error for *programming / start-up* mistakes only (bad menu definition, no terminal).
# Runtime problems inside actions must use act_fail / return codes instead.
gm_fatal() {
  printf 'fatal: %s\n' "$*" >&2
  exit 1
}

gm_tmp_init() {
  if [[ -z $GM_TMP || ! -d $GM_TMP ]]; then
    GM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gm.XXXXXX") || gm_fatal "cannot create a temporary directory"
  fi
}

# Runs in the MAIN shell on exit. Subshells (actions) have their own EXIT trap and never run this.
gm_on_exit() {
  ui_task_cleanup 2>/dev/null || true
  if [[ -t 0 ]]; then stty sane 2>/dev/null || true; fi
  if [[ -n $GM_TMP && -d $GM_TMP ]]; then rm -rf "$GM_TMP"; fi
}

# Ctrl-C in the main shell never exits the program. It raises a flag that a spinner notices, and
# while a prompt is waiting it prints a hint right away: `read -e` does NOT return on Ctrl-C (bash
# runs the trap mid-read and readline keeps the half-typed line), so the hint has to come from
# the handler itself. `q` is the way out.
GM_READING=0
gm_on_int() {
  GM_INT=1
  if ((GM_READING)); then
    printf '\n  %sCtrl-C does not quit the menu - type q to quit, b to go back.%s\n' "${C_DIM:-}" "${C_0:-}"
  fi
}

gm_install_traps() {
  trap gm_on_int INT
  trap 'exit 143' TERM
  trap gm_on_exit EXIT
}

is_dry() { [[ $GM_DRY == 1 ]]; }
