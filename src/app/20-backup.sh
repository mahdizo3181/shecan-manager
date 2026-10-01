# shellcheck shell=bash
# 20-backup.sh - backup directory, rollback manifest, tracked file writes.
#
# Every change an action makes is recorded in $BK/iran.manifest so it can be undone:
#   F_NEW path        file did not exist        -> remove on undo
#   F_BAK path copy   file replaced             -> copy back on undo
#   DIR_NEW path      directory created         -> rmdir if empty
#   SVC unit          unit enabled by us        -> disable --now
#   USER_NEW name     system user created       -> userdel
#   FW kind ip:port   firewall rule added       -> remove it
#   FW_DEL kind ip:port  rule removed           -> add it back
#
# Steps use iran_step / iran_step_done (bottom of this file): a failing step undoes only ITS OWN
# changes, earlier finished steps are kept and listed as PARTIAL in the result.

bk_dir() {
  local base n=1
  if [[ -z $BK ]]; then
    base=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
    BK=$base
    while [[ -e $BK ]]; do n=$((n + 1)); BK=$base-$n; done      # two runs in one second must not share a folder
    mkdir -p "$BK/files"
    chmod 700 "$BACKUP_ROOT" "$BK" "$BK/files"
  fi
}

manifest_add() { bk_dir; printf '%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" >>"$BK/$MANIFEST"; }
manifest_lines() { if [[ -n $BK && -f $BK/$MANIFEST ]]; then wc -l <"$BK/$MANIFEST"; else echo 0; fi; }

backup_file() {  # record + copy a file that is about to be created/replaced
  local p=$1 safe
  if [[ -e $p ]]; then
    bk_dir
    safe=$BK/files/$(printf '%s' "$p" | tr '/' '_')
    cp -p -- "$p" "$safe"
    manifest_add F_BAK "$p" "$safe"
  else
    manifest_add F_NEW "$p"
  fi
}

# put_file PATH MODE OWNER:GROUP   (content on stdin). Sets CHANGED=1|0.
# Identical content is left alone (idempotent); otherwise the old file is backed up first.
put_file() {
  local path=$1 mode=$2 owner=${3:-root:root} t
  CHANGED=0
  if is_dry; then
    cat >/dev/null
    dry_say "would write $path (mode $mode)"
    CHANGED=1
    return 0
  fi
  mkdir -p "$(dirname "$path")"          # minimal systems may lack /usr/local/sbin etc.
  t=$(mktemp -p "$(dirname "$path")" .gs.XXXXXX)
  cat >"$t"
  if [[ -f $path ]] && cmp -s "$t" "$path"; then
    rm -f "$t"
    chmod "$mode" "$path"
    chown "$owner" "$path"
    return 0
  fi
  backup_file "$path"
  chmod "$mode" "$t"
  chown "$owner" "$t"
  mv -f "$t" "$path"
  CHANGED=1
}

mkdir_tracked() {  # PATH MODE [OWNER:GROUP]
  if [[ -d $1 ]]; then return 0; fi
  if is_dry; then dry_say "would create directory $1"; return 0; fi
  mkdir -p "$1"
  chmod "$2" "$1"
  chown "${3:-root:root}" "$1"
  manifest_add DIR_NEW "$1"
}

undo_op() {
  case $1 in
    F_NEW)   if [[ $2 != "$DEFAULT_KEY_FILE" && $2 != "${KEY_FILE:-}" ]]; then rm -f -- "$2"; fi ;;   # keys are never deleted
    F_BAK)   cp -p -- "$3" "$2" ;;
    DIR_NEW) rmdir --ignore-fail-on-non-empty -- "$2" 2>/dev/null || true ;;
    SVC)     systemctl disable --now "$2" >/dev/null 2>&1 || true ;;
    USER_NEW) userdel "$2" >/dev/null 2>&1 || true ;;
    FW)      fw_remove "$2" "${3%%:*}" "${3##*:}" || true ;;
    FW_DEL)  fw_ensure "$2" "${3%%:*}" "${3##*:}" >/dev/null || true ;;
    *)       ui_warn "unknown manifest entry: $1" ;;
  esac
}

# Undo everything recorded after the first $1 lines of this run's manifest.
replay_manifest() {
  local from=$1 mf=$BK/$MANIFEST op a b
  [[ -n $BK && -s $mf ]] || return 0
  while IFS=$'\t' read -r op a b; do
    ui_note "undo: $op ${a:-}"
    undo_op "$op" "${a:-}" "${b:-}"
  done < <(tail -n +"$((from + 1))" "$mf" | tac)
  head -n "$from" "$mf" >"$mf.tmp" && mv -f "$mf.tmp" "$mf"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ -f $UNIT && -f $CONF ]]; then systemctl restart "$SVC" >/dev/null 2>&1 || true; fi
}

# ---- steps -----------------------------------------------------------------------------------------
ISTEP_NAME="" ISTEP_TIPPED=0

# iran_step "title": numbered heading + a rollback that undoes just this step's manifest entries
iran_step() {
  ISTEP_NAME=$1
  act_step "$1"
  act_on_fail replay_manifest "$(manifest_lines)"
}

# iran_step_done: the step is durable. A later failure keeps it and lists it as PARTIAL.
iran_step_done() {
  act_commit
  if is_dry; then return 0; fi
  act_partial "$ISTEP_NAME"
  if ((ISTEP_TIPPED == 0)); then
    act_tip "re-run the same command to continue, or 'gemini-menu iran rollback' to undo this whole run"
    ISTEP_TIPPED=1
  fi
}
