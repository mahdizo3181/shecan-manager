# shellcheck shell=bash
# 20-render.sh - frames, status cards, badges, messages, spinner.
#
# Nothing in here clears the screen: every screen is appended below the previous output, so the
# scrollback (what the last action printed) is never destroyed.

UI_KVW=12          # label column of key/value rows inside frames

# ---- badges ------------------------------------------------------------------------------------
# ui_badge OUT style [TEXT]   style: ok active warn fail info off   -> "[TEXT]" in the style colour
ui_badge() {
  local -n __o_badge=$1
  local style=$2 text=${3:-} col
  case $style in
    ok | active) col=$C_OK; : "${text:=OK}" ;;
    warn)        col=$C_WARN; : "${text:=WARN}" ;;
    fail | err)  col=$C_ERR; : "${text:=FAIL}" ;;
    info)        col=$C_INFO; : "${text:=INFO}" ;;
    *)           col=$C_GRAY; : "${text:=OFF}" ;;
  esac
  __o_badge="${col}[${text}]${C_0}"
}

# ---- frames ------------------------------------------------------------------------------------
ui_box_top() {  # ui_box_top ["Title"]
  local title=${1:-} inner=$((UI_W - 2)) fill len
  if [[ -n $title ]]; then
    ui_vlen len "$title"
    ui_repeat fill "$G_H" $((inner - len - 3))
    printf '%s%s%s%s %s%s%s %s%s%s\n' "$C_GRAY" "$G_TL" "$G_H" "$C_0" "$C_TITLE$title" "$C_0" "$C_GRAY" "$fill" "$G_TR" "$C_0"
  else
    ui_repeat fill "$G_H" "$inner"
    printf '%s%s%s%s%s\n' "$C_GRAY" "$G_TL" "$fill" "$G_TR" "$C_0"
  fi
}

ui_box_row() {  # ui_box_row "content"   (clipped / padded to the frame)
  local text=${1:-} w=$((UI_W - 4))
  ui_clip text "$text" "$w"
  ui_pad text "$text" "$w"
  printf '%s%s%s %s %s%s%s\n' "$C_GRAY" "$G_V" "$C_0" "$text" "$C_GRAY" "$G_V" "$C_0"
}

ui_box_sep() {
  local fill
  ui_repeat fill "$G_H" $((UI_W - 2))
  printf '%s%s%s%s%s\n' "$C_GRAY" "$G_LT" "$fill" "$G_RT" "$C_0"
}

ui_box_bottom() {
  local fill
  ui_repeat fill "$G_H" $((UI_W - 2))
  printf '%s%s%s%s%s\n' "$C_GRAY" "$G_BL" "$fill" "$G_BR" "$C_0"
}

ui_box_blank() { ui_box_row ""; }

# label (dim) + value on one row
ui_box_kv() {  # ui_box_kv "Label" "value"
  local label
  ui_pad label "$1" "$UI_KVW"
  ui_box_row "${C_DIM}${label}${C_0} ${2:-}"
}

# label + [BADGE] + detail, straight from the probe cache (see 50-probe.sh)
ui_box_probe() {  # ui_box_probe "Label" PROBE_ID
  local id=$2 badge detail
  if [[ -z ${PROBE_LVL[$id]:-} ]]; then
    ui_badge badge off "--"
    ui_box_kv "$1" "$badge ${C_DIM}not checked yet${C_0}"
    return 0
  fi
  ui_badge badge "${PROBE_LVL[$id]}" "${PROBE_BADGE[$id]}"
  detail=${PROBE_MSG[$id]}
  ui_box_kv "$1" "$badge ${detail}"
}

ui_banner() {  # ui_banner "Title" "subtitle"
  ui_box_top
  ui_box_row "${C_TITLE}${1:-$GM_APP}${C_0}"
  if [[ -n ${2:-} ]]; then ui_box_row "${C_DIM}$2${C_0}"; fi
  ui_box_bottom
}

# ---- single-line messages ----------------------------------------------------------------------
ui_say()  { printf '  %s\n' "$*"; }
ui_blank() { printf '\n'; }
ui_ok()   { printf '  %s%s%s %s\n' "$C_OK" "$G_OK" "$C_0" "$*"; }
ui_warn() { printf '  %s%s%s %s\n' "$C_WARN" "$G_WARN" "$C_0" "$*"; }
ui_err()  { printf '  %s%s%s %s\n' "$C_ERR" "$G_ERR" "$C_0" "$*"; }
ui_info() { printf '  %s%s%s %s\n' "$C_INFO" "$G_INFO" "$C_0" "$*"; }
ui_note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
ui_step() { printf '\n  %s%s %s%s\n' "$C_TITLE" "$G_STEP" "$*" "$C_0"; }

ui_rule() {  # ui_rule ["title"]   a light divider line between blocks of output
  local title=${1:-} fill len
  if [[ -n $title ]]; then
    ui_vlen len "$title"
    ui_repeat fill "$G_H" $((UI_W - 6 - len))
    printf '  %s%s%s %s%s%s %s%s%s\n' "$C_GRAY" "$G_H$G_H" "$C_0" "$C_TITLE" "$title" "$C_0" "$C_GRAY" "$fill" "$C_0"
  else
    ui_repeat fill "$G_H" $((UI_W - 2))
    printf '  %s%s%s\n' "$C_GRAY" "$fill" "$C_0"
  fi
}

# ---- spinner -----------------------------------------------------------------------------------
UI_TASK_PIDS=()
UI_TASK_OUT=""        # captured output of the last ui_task
UI_TASK_RC=0

ui_task_cleanup() {
  local p
  for p in "${UI_TASK_PIDS[@]:-}"; do
    [[ -n $p ]] && kill "$p" 2>/dev/null
  done
  UI_TASK_PIDS=()
  return 0
}

# ui_spin_wait "label" PID...   waits for background jobs with a spinner on a terminal.
# Environment: UI_WAIT_TIMEOUT=seconds (0 = none). Returns 0 done, 124 timed out (jobs killed),
# 130 interrupted by Ctrl-C (jobs killed). On 0 the caller does `wait PID` to get each exit status.
ui_spin_wait() {
  local label=$1 pid alive f=0 t0=$SECONDS rc=0 to=${UI_WAIT_TIMEOUT:-0}
  shift
  UI_TASK_PIDS=("$@")
  if ((UI_TTY)); then
    printf '  %s %s%s' "${UI_SPIN[0]}" "$label" "$C_DIM"
  else
    printf '  %s %s\n' "$G_ELL" "$label"
  fi
  while :; do
    alive=0
    for pid in "$@"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    ((alive)) || break
    if ((GM_INT)); then rc=130; break; fi
    if ((to > 0 && SECONDS - t0 >= to)); then rc=124; break; fi
    if ((UI_TTY)); then
      f=$(((f + 1) % ${#UI_SPIN[@]}))
      printf '\r\e[K  %s%s%s %s%s' "$C_TITLE" "${UI_SPIN[f]}" "$C_0" "$label" "$C_DIM"
    fi
    sleep 0.1
  done
  if ((rc != 0)); then
    # killed jobs are reaped here; finished jobs are left for the caller's `wait PID` (exit status)
    for pid in "$@"; do kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null; done
  fi
  UI_TASK_PIDS=()
  if ((UI_TTY)); then printf '\r\e[K%s' "$C_0"; fi
  return "$rc"
}

# ui_task "label" cmd [args...]
# Runs cmd in the background (a subshell: it cannot change this shell's variables, return data on
# stdout), shows a spinner, then one result line. Output is captured in UI_TASK_OUT, status in
# UI_TASK_RC. On failure the last lines of output are shown. UI_TASK_QUIET=1 prints nothing on
# success.
ui_task() {
  local label=$1 out pid rc=0 t0=$SECONDS
  shift
  out=$(mktemp "${GM_TMP:-${TMPDIR:-/tmp}}/task.XXXXXX") || return 1
  (
    "$@"
  ) >"$out" 2>&1 &
  pid=$!
  ui_spin_wait "$label" "$pid" || rc=$?
  if ((rc == 0)); then
    wait "$pid" 2>/dev/null
    rc=$?
  fi
  UI_TASK_RC=$rc
  UI_TASK_OUT=$(<"$out")
  rm -f "$out"
  if ((rc == 0)); then
    if [[ ${UI_TASK_QUIET:-0} != 1 ]]; then ui_ok "$label ${C_DIM}($((SECONDS - t0))s)${C_0}"; fi
  else
    ui_err "$label ${C_DIM}(exit $rc)${C_0}"
    if [[ -n $UI_TASK_OUT ]]; then
      local line
      while IFS= read -r line; do ui_note "    ${line:0:$((UI_W - 8))}"; done < <(tail -n 5 <<<"$UI_TASK_OUT")
    fi
  fi
  return "$rc"
}
