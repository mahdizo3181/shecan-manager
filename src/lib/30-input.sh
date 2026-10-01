# shellcheck shell=bash
# 30-input.sh - buffered line input, validators and prompts that never kill the caller.
#
# Return-code contract shared by every prompt_* / confirm* function:
#     0  value accepted
#     1  (confirm only) the answer was "no"
#    10  cancelled: the user typed b / back / cancel, pressed Ctrl-D, or there is no terminal
#
# Everything the user types is VISIBLE and editable (readline: backspace, arrows, paste). There is no
# hidden input in this tool: nothing it asks for is a password.
# An invalid value never ends a prompt: it prints one inline error line and asks again.
# Inside an action a cancelled prompt is handled with:   prompt_ipv4 ip "Foreign IP" || act_cancel
#
# Input comes from the terminal even when the script itself is piped (curl ... | bash): when
# stdin is not a terminal, /dev/tty is opened on fd 9. GM_INPUT=stdin forces plain stdin (tests).

IN_FD=0 IN_OK=0 IN_TTY=0 IN_EOF=0 IN_VALUE="" IN_ERR="" IN_HINTED=0

in_init() {
  IN_OK=0 IN_TTY=0 IN_FD=0
  if [[ ${GM_INPUT:-} == stdin ]]; then
    IN_OK=1
  elif [[ -t 0 ]]; then
    IN_OK=1 IN_TTY=1
  elif [[ -r /dev/tty ]] && : 2>/dev/null </dev/tty; then
    exec 9</dev/tty
    IN_FD=9 IN_OK=1 IN_TTY=1
  fi
}

# "Label [default]: " (colour escapes wrapped for readline)
in_prompt() {  # in_prompt OUT "label" ["default"]
  local -n __o_ip=$1
  local __p="  ${R_TITLE}$2${R_0}"
  if [[ -n ${3:-} ]]; then __p+=" ${R_DIM}[$3]${R_0}"; fi
  __o_ip="$__p: "
}

# One-time reminder per action / per menu, so the prompts themselves stay short.
in_hint_once() {
  if ((IN_HINTED == 0)); then
    ui_note "Enter accepts the [default]. Type b to cancel at any prompt. Ctrl-C stops the operation."
    IN_HINTED=1
  fi
}

# in_read OUT "prompt"   -> 0 got a line, 1 end of input, 130 Ctrl-C (only seen in the main shell:
# inside an action the INT trap ends the action first). Leading/trailing blanks are trimmed.
in_read() {
  local -n __o_ir=$1
  local __p=$2 __l="" __rc=0
  IN_EOF=0
  __o_ir=""
  if ((!IN_OK)); then IN_EOF=1; return 1; fi
  GM_INT=0
  if ((IN_TTY)); then
    GM_READING=1
    IFS= read -e -r -u "$IN_FD" -p "$__p" __l || __rc=$?
    GM_READING=0
  else
    __p=${__p//[$'\001\002']/}
    printf '%s' "$__p"
    IFS= read -r -u "$IN_FD" __l || __rc=$?
    if ((__rc == 1)) && [[ -n $__l ]]; then __rc=0; fi       # last line without a newline
  fi
  if ((__rc != 0)); then
    printf '\n'
    if ((__rc > 128 || GM_INT)); then return 130; fi
    IN_EOF=1
    return 1
  fi
  __l=${__l##+([[:space:]])}
  __l=${__l%%+([[:space:]])}
  __o_ir=$__l
  return 0
}

# ---- validators ------------------------------------------------------------------------------
# v_NAME value [args]  -> 0 valid. They set IN_VALUE (the normalised value) and, when invalid,
# IN_ERR (the message shown to the user). Pure functions: no output, no exit.
v_nonempty() {
  IN_VALUE=$1
  if [[ -n $1 ]]; then return 0; fi
  IN_ERR="a value is required"
  return 1
}

v_ipv4() {
  local v=$1 i o
  IN_ERR="not an IPv4 address (example: 203.0.113.10)"
  [[ $v =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for i in 1 2 3 4; do
    o=${BASH_REMATCH[i]}
    if ((${#o} > 1)) && [[ $o == 0* ]]; then return 1; fi
    ((10#$o <= 255)) || return 1
  done
  IN_VALUE=$v IN_ERR=""
}

v_int_range() {  # v_int_range value MIN MAX
  local v=$1 min=$2 max=$3
  IN_ERR="enter a whole number from $min to $max"
  [[ $v =~ ^[0-9]{1,9}$ ]] || return 1
  ((10#$v >= min && 10#$v <= max)) || return 1
  IN_VALUE=$((10#$v)) IN_ERR=""
}

v_port() { v_int_range "$1" 1 65535 || { IN_ERR="a port is a number from 1 to 65535"; return 1; }; }

v_hostname() {  # accepts "https://Host.Example/x", "full:host" ... and normalises to "host.example"
  local h=${1,,}
  h=${h#full:}
  h=${h#http://}
  h=${h#https://}
  h=${h%%/*}
  h=${h%%:*}
  h=${h%.}
  IN_ERR="not a valid hostname (example: gemini.google.com)"
  ((${#h} <= 253)) || return 1
  [[ $h =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || return 1
  IN_VALUE=$h IN_ERR=""
}

v_yesno() {
  case ${1,,} in
    y | yes) IN_VALUE=y ;;
    n | no) IN_VALUE=n ;;
    *) IN_ERR="answer yes or no"; return 1 ;;
  esac
}

v_file_readable() {
  IN_ERR="no readable file at that path"
  [[ -f $1 && -r $1 ]] || return 1
  IN_VALUE=$1 IN_ERR=""
}

v_choice() {  # v_choice value OPTION...   (by number or by name, case-insensitive)
  local v=$1 i=0 o
  shift
  IN_ERR="pick one of the listed options (a number or its name)"
  if [[ $v =~ ^[0-9]+$ ]] && ((10#$v >= 1 && 10#$v <= $#)); then
    IN_VALUE=${!v} IN_ERR=""
    return 0
  fi
  for o in "$@"; do
    i=$((i + 1))
    if [[ ${o,,} == "${v,,}" ]]; then IN_VALUE=$o IN_ERR=""; return 0; fi
  done
  return 1
}

v_b64_bytes() {  # v_b64_bytes value N  -> base64 of exactly N bytes
  local v=${1//[$'\r\n\t ']/} n=$2
  IN_ERR="not base64 of exactly $n bytes"
  [[ $(printf '%s' "$v" | base64 -d 2>/dev/null | wc -c) == "$n" ]] || return 1
  IN_VALUE=$v IN_ERR=""
}

v_url() {
  IN_ERR="expected a URL starting with http:// or https://"
  [[ $1 =~ ^https?://[^[:space:]]+$ ]] || return 1
  IN_VALUE=$1 IN_ERR=""
}

v_tg_token() {
  IN_ERR="a Telegram bot token looks like 123456789:AAE... (digits, colon, letters)"
  [[ $1 =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ ]] || return 1
  IN_VALUE=$1 IN_ERR=""
}

v_tg_chat() {
  IN_ERR="a chat id is a number like 123456789 or -1001234567890 (or @channelname)"
  [[ $1 =~ ^-?[0-9]{3,}$ || $1 =~ ^@[A-Za-z0-9_]{4,}$ ]] || return 1
  IN_VALUE=$1 IN_ERR=""
}

# ---- prompts ---------------------------------------------------------------------------------
# prompt_valid OUT "Label" "default" validator [validator-args...]
#   loops until the validator accepts; IN_ALLOW_EMPTY=1 lets an empty answer through as "".
prompt_valid() {
  local -n __o_pv=$1
  local __pv_label=$2 __pv_def=$3 __pv_fn=$4 __pv_line __pv_p __pv_rc
  shift 4
  in_hint_once
  while :; do
    in_prompt __pv_p "$__pv_label" "$__pv_def"
    in_read __pv_line "$__pv_p" && __pv_rc=0 || __pv_rc=$?
    if ((__pv_rc != 0)); then return 10; fi
    case ${__pv_line,,} in b | back | cancel) return 10 ;; esac
    if [[ -z $__pv_line ]]; then
      if [[ -n $__pv_def ]]; then
        __pv_line=$__pv_def
      elif [[ ${IN_ALLOW_EMPTY:-0} == 1 ]]; then
        __o_pv=""
        return 0
      else
        ui_err "a value is required (type b to cancel)"
        continue
      fi
    fi
    IN_VALUE=$__pv_line IN_ERR=""
    if "$__pv_fn" "$__pv_line" "$@"; then
      __o_pv=$IN_VALUE
      return 0
    fi
    ui_err "${IN_ERR:-invalid input}"
  done
}

prompt_text()     { prompt_valid "$1" "$2" "${3:-}" v_nonempty; }
prompt_ipv4()     { prompt_valid "$1" "$2" "${3:-}" v_ipv4; }
prompt_port()     { prompt_valid "$1" "$2" "${3:-}" v_port; }
prompt_hostname() { prompt_valid "$1" "$2" "${3:-}" v_hostname; }
prompt_int()      { prompt_valid "$1" "$2" "${5:-}" v_int_range "$3" "$4"; }   # OUT label MIN MAX [default]
prompt_file()     { prompt_valid "$1" "$2" "${3:-}" v_file_readable; }

prompt_choice() {  # prompt_choice OUT "Label" "default" option...
  local __pc_out=$1 __pc_label=$2 __pc_def=$3 __pc_i=0 __pc_o
  shift 3
  for __pc_o in "$@"; do
    __pc_i=$((__pc_i + 1))
    ui_say "  ${C_KEY}${__pc_i}${C_0}) $__pc_o"
  done
  prompt_valid "$__pc_out" "$__pc_label" "$__pc_def" v_choice "$@"
}

# confirm "Question"  ->  "Question [y/N]: "   0 yes | 1 no | 10 cancelled
#   y, Y, yes, YES = yes.  n, no, or just Enter = NO (the safe default).  Anything else is not guessed at:
#   it asks again, so a stray word never answers for you.  --yes (GM_YES=1) answers yes.
confirm() {
  local __c_q=$1 __c_l __c_p __c_rc
  if [[ $GM_YES == 1 ]]; then
    ui_note "auto-confirmed (--yes): $__c_q"
    return 0
  fi
  while :; do
    in_prompt __c_p "$__c_q ${R_DIM}[y/N]${R_0}" ""
    in_read __c_l "$__c_p" && __c_rc=0 || __c_rc=$?
    if ((__c_rc != 0)); then return 10; fi
    case ${__c_l,,} in
      y | yes) return 0 ;;
      "" | n | no) return 1 ;;
      b | back | cancel) return 10 ;;
      *) ui_err "please answer y or n (Enter = no)" ;;
    esac
  done
}
# the same, but --yes can NOT answer it (revealing a secret, discarding someone else's edits)
confirm_force() {
  local __save=$GM_YES __rc=0
  GM_YES=0
  confirm "$@" || __rc=$?
  GM_YES=$__save
  return "$__rc"
}

# confirm_typed "What will be destroyed" [word]
#   ONLY for destructive purges (uninstall, replacing a whole database). The word is matched
#   case-insensitively; Enter cancels; anything else asks again and says what to type.
_confirm_typed() {  # _confirm_typed honour_yes "message" word
  local __t_msg=$2 __t_word=${3:-yes} __t_l __t_p __t_rc
  if [[ $1 == 1 && $GM_YES == 1 ]]; then return 0; fi
  ui_warn "$__t_msg"
  while :; do
    in_prompt __t_p "Type ${R_WARN}${__t_word}${R_0}${R_TITLE} to confirm, or press Enter to cancel" ""
    in_read __t_l "$__t_p" && __t_rc=0 || __t_rc=$?
    if ((__t_rc != 0)); then return 10; fi
    case ${__t_l,,} in
      "$__t_word") return 0 ;;
      "" | b | back | cancel) return 10 ;;
      *) ui_err "not confirmed - type '$__t_word' to go ahead, or press Enter to cancel" ;;
    esac
  done
}
confirm_typed()       { _confirm_typed 1 "$@"; }     # --yes skips it
confirm_typed_force() { _confirm_typed 0 "$@"; }     # --yes can NOT skip it

# pick_many RESULT "Title" LABELS SELECTED
#   RESULT, LABELS and SELECTED are array names. SELECTED holds the initial 0/1 flags.
#   Returns 0 with RESULT = 0-based indexes of the ticked rows, or 10 when cancelled (the caller's
#   arrays are then left exactly as they were). Input is parsed without globbing and validated as
#   a whole: one bad token rejects the line and nothing is toggled.
pick_many() {
  local -n __pm_res=$1 __pm_labels=$3 __pm_init=$4
  local __pm_title=$2 __pm_n=${#__pm_labels[@]} __pm_i __pm_l __pm_p __pm_rc __pm_tok __pm_bad __pm_done
  local -a __pm_sel=() __pm_toks=()
  local __pm_a __pm_b __pm_t __pm_show
  for ((__pm_i = 0; __pm_i < __pm_n; __pm_i++)); do __pm_sel[__pm_i]=${__pm_init[__pm_i]:-0}; done
  in_hint_once
  while :; do
    ui_rule "$__pm_title"
    for ((__pm_i = 0; __pm_i < __pm_n; __pm_i++)); do
      ui_safe __pm_show "${__pm_labels[__pm_i]}" $((UI_W - 16))
      if ((__pm_sel[__pm_i] == 1)); then
        ui_say "${C_OK}[x]${C_0} ${C_KEY}$((__pm_i + 1))${C_0}  $__pm_show"
      else
        ui_say "${C_DIM}[ ]${C_0} ${C_KEY}$((__pm_i + 1))${C_0}  $__pm_show"
      fi
    done
    ui_note "numbers toggle (1 3 5-7)  a = all  n = none  d = done  b = cancel"
    while :; do
      in_prompt __pm_p "Toggle" ""
      in_read __pm_l "$__pm_p" && __pm_rc=0 || __pm_rc=$?
      if ((__pm_rc != 0)); then return 10; fi
      read -ra __pm_toks <<<"$__pm_l"                      # word-split without globbing
      if ((${#__pm_toks[@]} == 0)); then continue; fi
      __pm_bad=""
      for __pm_tok in "${__pm_toks[@]}"; do
        __pm_t=${__pm_tok,,}
        if [[ $__pm_t =~ ^[andb]$ ]]; then
          :
        elif [[ $__pm_t =~ ^[0-9]+$ ]]; then
          if ((10#$__pm_t < 1 || 10#$__pm_t > __pm_n)); then __pm_bad=$__pm_tok; fi
        elif [[ $__pm_t =~ ^([0-9]+)-([0-9]+)$ ]]; then
          __pm_a=${BASH_REMATCH[1]} __pm_b=${BASH_REMATCH[2]}
          if ((10#$__pm_a < 1 || 10#$__pm_b > __pm_n || 10#$__pm_a > 10#$__pm_b)); then __pm_bad=$__pm_tok; fi
        else
          __pm_bad=$__pm_tok
        fi
        if [[ -n $__pm_bad ]]; then break; fi
      done
      if [[ -n $__pm_bad ]]; then
        ui_safe __pm_bad "$__pm_bad" 20
        ui_err "\"$__pm_bad\" is not valid here - use numbers 1-$__pm_n (or 2-4), a, n, d or b. Nothing was changed."
        continue
      fi
      __pm_done=0
      for __pm_tok in "${__pm_toks[@]}"; do
        __pm_t=${__pm_tok,,}
        if [[ $__pm_t == a ]]; then
          for ((__pm_i = 0; __pm_i < __pm_n; __pm_i++)); do __pm_sel[__pm_i]=1; done
        elif [[ $__pm_t == n ]]; then
          for ((__pm_i = 0; __pm_i < __pm_n; __pm_i++)); do __pm_sel[__pm_i]=0; done
        elif [[ $__pm_t == d ]]; then
          __pm_done=1
          break
        elif [[ $__pm_t == b ]]; then
          return 10
        elif [[ $__pm_t =~ ^[0-9]+$ ]]; then
          __pm_i=$((10#$__pm_t - 1))
          __pm_sel[__pm_i]=$((1 - __pm_sel[__pm_i]))
        elif [[ $__pm_t =~ ^([0-9]+)-([0-9]+)$ ]]; then
          __pm_a=${BASH_REMATCH[1]} __pm_b=${BASH_REMATCH[2]}
          for ((__pm_i = 10#$__pm_a - 1; __pm_i < 10#$__pm_b; __pm_i++)); do __pm_sel[__pm_i]=$((1 - __pm_sel[__pm_i])); done
        fi
      done
      if ((__pm_done)); then
        __pm_res=()
        for ((__pm_i = 0; __pm_i < __pm_n; __pm_i++)); do
          if ((__pm_sel[__pm_i] == 1)); then __pm_res+=("$__pm_i"); fi
        done
        return 0
      fi
      break      # redraw the list with the new ticks
    done
  done
}
