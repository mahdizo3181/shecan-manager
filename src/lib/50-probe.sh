# shellcheck shell=bash
# 50-probe.sh - status probes: cached, run in parallel, with a spinner and a timeout.
#
# A probe is a function that prints ONE line, tab-separated:
#       LEVEL <TAB> BADGE <TAB> detail text [<TAB> what to do about it]
#   LEVEL is ok | warn | fail | info | off (it picks the colour), BADGE is the short word shown
#   in the brackets ("ACTIVE", "FAIL", "OFF", ...).
# Probes run in subshells, all at once, so a slow one (DNS) costs the time of the slowest, not
# the sum - and the screen shows a spinner instead of freezing. A probe that does not answer within
# GM_PROBE_TIMEOUT seconds (default 12) is shown as a warning and never blocks the menu.
#
#   probe_register ID function "Label"     once, at start-up
#   probe_refresh [force]                  re-run them unless the cache is younger than the TTL
#   probe_invalidate                       mark stale (the menu does this after every action)
#   ui_box_probe "Label" ID                draw one row of a status card from the cache

declare -A PROBE_FN=() PROBE_LABEL=() PROBE_LVL=() PROBE_BADGE=() PROBE_MSG=() PROBE_HINT=()
PROBE_IDS=()
PROBE_AT=-1                        # SECONDS value of the last refresh; -1 = stale
PROBE_TTL=${GM_STATUS_TTL:-30}

probe_register() {  # probe_register ID function "Label"
  [[ $1 =~ ^[a-z0-9_]+$ ]] || gm_fatal "probe id must be [a-z0-9_]+: $1"
  PROBE_IDS+=("$1")
  PROBE_FN[$1]=$2
  PROBE_LABEL[$1]=${3:-$1}
}

probe_invalidate() { PROBE_AT=-1; }

probe_refresh() {  # probe_refresh [force]
  local force=${1:-0} id pid rc=0 n=${#PROBE_IDS[@]} lvl badge msg hint line f
  local -a pids=()
  if ((n == 0)); then return 0; fi
  if ((!force && PROBE_AT >= 0 && SECONDS - PROBE_AT < PROBE_TTL)); then return 0; fi
  gm_tmp_init
  for id in "${PROBE_IDS[@]}"; do
    f=$GM_TMP/probe.$id
    : >"$f"
    ("${PROBE_FN[$id]}") >"$f" 2>/dev/null &
    pids+=("$!")
  done
  UI_WAIT_TIMEOUT=${GM_PROBE_TIMEOUT:-12} ui_spin_wait "Checking status ($n checks)..." "${pids[@]}" || rc=$?
  if ((rc == 130)); then
    ui_warn "status refresh interrupted - showing the previous values"
    return 130
  fi
  for id in "${PROBE_IDS[@]}"; do
    f=$GM_TMP/probe.$id
    line=""
    if [[ -s $f ]]; then IFS= read -r line <"$f" || true; fi
    lvl="" badge="" msg="" hint=""
    IFS=$'\t' read -r lvl badge msg hint <<<"$line" || true
    case $lvl in
      ok | warn | fail | info | off) ;;
      *)
        lvl=warn badge="?"
        if ((rc == 124)); then msg="did not answer in time (skipped)"; else msg="the check returned no usable result"; fi
        hint="Press r to try again."
        ;;
    esac
    ui_safe badge "$badge" 10
    ui_safe msg "$msg" $((UI_W - UI_KVW - 18))
    ui_safe hint "$hint" $((UI_W - 10))
    PROBE_LVL[$id]=$lvl PROBE_BADGE[$id]=$badge PROBE_MSG[$id]=$msg PROBE_HINT[$id]=$hint
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  PROBE_AT=$SECONDS
  return 0
}

# worst level in the cache: prints ok | warn | fail
probe_worst() {
  local id w=ok
  for id in "${PROBE_IDS[@]}"; do
    case ${PROBE_LVL[$id]:-} in
      fail) echo fail; return 0 ;;
      warn) w=warn ;;
    esac
  done
  echo "$w"
}

# Full report with "what to do" lines (the Health check screen).
probe_report() {
  local id badge
  if ((${#PROBE_IDS[@]} == 0)); then ui_note "no checks are registered"; return 0; fi
  for id in "${PROBE_IDS[@]}"; do
    ui_badge badge "${PROBE_LVL[$id]:-off}" "${PROBE_BADGE[$id]:-?}"
    ui_say "$badge ${C_B}${PROBE_LABEL[$id]}${C_0}  ${PROBE_MSG[$id]:-not checked yet}"
    if [[ ${PROBE_LVL[$id]:-} =~ ^(warn|fail)$ && -n ${PROBE_HINT[$id]:-} ]]; then
      ui_note "      $G_SEP ${PROBE_HINT[$id]}"
    fi
  done
}
