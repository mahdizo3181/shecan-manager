# shellcheck shell=bash
# 40-action.sh - the action runner: one place that gives every operation the same guarantees.
#
#   act_run "Label" function [args...]        run function as an action, print ONE result line
#
# Guarantees
#   * errexit + ERR trap are really on inside the action. (The old design broke this: bash silently
#     disables `set -e` for everything called from `cmd || true` / `if cmd` / `cmd && ...`.
#     act_run therefore REFUSES to run from such a context - it returns 70 and says so - instead
#     of pretending.)  Call it as its own statement and read $ACT_RC or $?:
#           act_run "Restart relay" iran_restart; rc=$?
#   * Ctrl-C ends only the action: its rollbacks and deferred cleanups run, the result line says
#     INTERRUPTED and the caller (the menu) carries on.
#   * exit codes:  0 ok | 10 cancelled | 130 interrupted | 70 runner misuse | other = failed
#   * the action runs in a subshell: it cannot change the caller's variables. Persist state on
#     disk or print it; read it afterwards from there.
#
# Helpers for use INSIDE an action (they all end the action, even when errexit is suppressed):
#   act_step "title"            numbered progress heading
#   must cmd args...            run a command; on failure print it and end the action with its code
#   act_do "what" cmd args...   like must, but in dry-run only says what it would do
#   act_fail "message" [rc]     print an error and end the action (default rc 1)
#   act_cancel ["message"]      end the action as "cancelled, nothing changed" (rc 10)
#   act_defer cmd args...       cleanup that always runs when the action ends (LIFO)
#   act_on_fail cmd args...     rollback that runs only when the action ends non-zero (LIFO)
#   act_commit                  forget the rollbacks registered so far (the step is durable now)
#   act_partial "what stays"    record that the failure left something applied (shown as PARTIAL)
#   act_tip "what to do next"   one-line advice shown under the PARTIAL list (e.g. how to undo)

ACT_IN=0 ACT_RC=0 ACT_LABEL="" ACT_STATE="" ACT_N=0 ACT_SUPPRESSED=0
ACT_DEFERS=() ACT_ROLLBACKS=()

# Is errexit being ignored in the calling context? (plain statement call only: inside `if f` the
# probe would always answer "yes")
act_probe_ctx() {
  local r
  r=$(
    set -e
    false
    echo x
  )
  if [[ $r == x ]]; then ACT_SUPPRESSED=1; else ACT_SUPPRESSED=0; fi
  return 0
}

act_run() {
  local __label=$1 __rc __t0=$SECONDS
  shift
  ACT_LABEL=$__label
  act_probe_ctx
  if ((ACT_SUPPRESSED)); then
    ui_err "internal error: act_run was called from a context where errexit is disabled (|| && if)."
    ui_note "Call it as its own statement:   act_run \"Label\" fn; rc=\$?"
    ACT_RC=70
    return 70
  fi
  gm_tmp_init
  ACT_STATE=$GM_TMP/act.state
  : >"$ACT_STATE"
  GM_INT=0
  trap gm_on_int INT           # the main shell survives Ctrl-C; the subshell below handles it
  (act_child "$@")
  __rc=$?
  GM_INT=0
  ACT_RC=$__rc
  act_report "$__rc" "$__label" $((SECONDS - __t0))
  if declare -F gm_audit >/dev/null; then gm_audit "action '$__label' rc=$__rc dry=$GM_DRY"; fi
  return "$__rc"
}

# ---- inside the subshell -----------------------------------------------------------------------
act_child() {
  ACT_IN=1 ACT_N=0 ACT_DEFERS=() ACT_ROLLBACKS=() IN_HINTED=0
  set -eE
  trap 'act_on_err $? "${BASH_COMMAND:-?}"' ERR
  trap 'act_on_int' INT
  trap 'act_on_exit $?' EXIT
  "$@"
}

act_on_err() {  # act_on_err RC "command"
  trap - ERR
  if (($1 == 10)); then exit 10; fi      # a cancelled prompt: not an error, no noise
  ui_err "step failed (exit $1): $2"
  exit "$1"
}

act_on_int() {
  trap - INT ERR
  printf '\n'
  ui_warn "Interrupted (Ctrl-C) - stopping this operation"
  exit 130
}

act_on_exit() {
  local rc=$1 i
  trap - EXIT INT ERR
  set +e
  if ((rc != 0 && ${#ACT_ROLLBACKS[@]} > 0)); then
    ui_warn "rolling back the steps of this operation that were not completed"
    for ((i = ${#ACT_ROLLBACKS[@]} - 1; i >= 0; i--)); do eval "${ACT_ROLLBACKS[i]}" || true; done
  fi
  for ((i = ${#ACT_DEFERS[@]} - 1; i >= 0; i--)); do eval "${ACT_DEFERS[i]}" || true; done
  ui_task_cleanup
}

act_step()     { ACT_N=$((ACT_N + 1)); ui_step "[$ACT_N] $*"; }
act_defer()    { ACT_DEFERS+=("$(printf '%q ' "$@")"); }
act_on_fail()  { ACT_ROLLBACKS+=("$(printf '%q ' "$@")"); }
act_commit()   { ACT_ROLLBACKS=(); }
act_partial()  { printf '%s\n' "$*" >>"${ACT_STATE:-/dev/null}"; }
act_tip()      { printf 'tip: %s\n' "$*" >>"${ACT_STATE:-/dev/null}"; }

act_cancel() {
  if [[ -n ${1:-} ]]; then ui_note "$1"; fi
  if ((ACT_IN)); then exit 10; fi
  return 10
}

act_fail() {
  ui_err "${1:-failed}"
  if ((ACT_IN)); then exit "${2:-1}"; fi
  return "${2:-1}"
}

must() {
  local __rc=0
  "$@" || __rc=$?
  if ((__rc == 0)); then return 0; fi
  ui_err "command failed (exit $__rc): $*"
  if ((ACT_IN)); then exit "$__rc"; fi
  return "$__rc"
}

act_do() {  # act_do "description" cmd args...
  local __what=$1
  shift
  if is_dry; then
    ui_info "${C_WARN}dry-run${C_0}: would $__what"
    return 0
  fi
  ui_note "$__what"
  must "$@"
}

# ---- result line -------------------------------------------------------------------------------
act_report() {  # act_report RC "label" SECONDS
  local rc=$1 label=$2 secs=$3 badge line meta=""
  if ((secs > 0)); then meta=" ${C_DIM}(${secs}s)${C_0}"; fi
  ui_blank
  if ((rc == 0)); then
    if is_dry; then
      ui_badge badge warn "DRY-RUN"
      ui_say "$badge  $label ${C_DIM}- nothing was changed${C_0}"
    elif [[ ${ACT_QUIET_OK:-0} != 1 ]]; then
      ui_badge badge ok " OK "
      ui_say "$badge  $label$meta"
    fi
  elif ((rc == 10)); then
    ui_badge badge warn "CANCELLED"
    ui_say "$badge  $label ${C_DIM}- nothing was changed${C_0}"
  elif ((rc == 130)); then
    ui_badge badge warn "INTERRUPTED"
    ui_say "$badge  $label ${C_DIM}- stopped by Ctrl-C${C_0}"
  elif ((rc == 70)); then
    ui_badge badge fail "ERROR"
    ui_say "$badge  $label ${C_DIM}- runner misuse, see above${C_0}"
  else
    ui_badge badge fail "FAILED"
    ui_say "$badge  $label ${C_DIM}(exit $rc)${C_0}"
  fi
  if ((rc != 0 && rc != 10)) && [[ -s $ACT_STATE ]]; then
    local -a tips=()
    ui_badge badge warn "PARTIAL"
    ui_say "$badge  these parts were applied and KEPT:"
    while IFS= read -r line; do
      if [[ $line == tip:* ]]; then tips+=("${line#tip: }"); else ui_say "       - $line"; fi
    done <"$ACT_STATE"
    for line in "${tips[@]}"; do ui_note "       $G_SEP $line"; done
  elif ((rc != 0)); then
    ui_note "  (details are in the messages above)"
  fi
  return 0
}
