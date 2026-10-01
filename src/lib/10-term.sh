# shellcheck shell=bash
# 10-term.sh - terminal capabilities, palette, glyph sets and width helpers.
#
# Text that is shown inside boxes is measured with ui_vlen, which ignores colour escapes.
# Wide (East-Asian / emoji) characters are NOT measured: keep user data out of boxes or pass it
# through ui_safe first. The UI itself only uses narrow glyphs.

UI_TTY=0 UI_COLOR=0 UI_UNICODE=0 UI_W=78

ui_detect() {
  if [[ -t 1 ]]; then UI_TTY=1; else UI_TTY=0; fi

  UI_COLOR=0
  if ((UI_TTY)) && [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then UI_COLOR=1; fi
  if [[ ${GM_COLOR:-} == 1 ]]; then UI_COLOR=1; fi      # force on (tests)
  if [[ ${GM_COLOR:-} == 0 ]]; then UI_COLOR=0; fi      # force off (--no-color)

  # Box-drawing needs a UTF-8 locale: that is also what makes ${#var} count characters, not bytes.
  UI_UNICODE=0
  case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UI_UNICODE=1 ;; esac
  if [[ ${GM_ASCII:-} == 1 ]]; then UI_UNICODE=0; fi
  if [[ ${TERM:-} == dumb ]]; then UI_UNICODE=0; fi

  ui_palette
  ui_glyphs
  ui_width
}

ui_palette() {
  C_0="" C_B="" C_DIM="" C_GRAY="" C_TITLE="" C_KEY="" C_OK="" C_ERR="" C_WARN="" C_INFO=""
  # readline-safe twins (escape sequences wrapped in \001 \002 so the cursor maths stay right)
  R_0="" R_TITLE="" R_DIM="" R_ERR="" R_OK="" R_WARN=""
  if ((UI_COLOR)); then
    C_0=$'\e[0m' C_B=$'\e[1m' C_DIM=$'\e[2m' C_GRAY=$'\e[90m'
    C_TITLE=$'\e[1;36m' C_KEY=$'\e[1;36m'
    C_OK=$'\e[1;32m' C_ERR=$'\e[1;31m' C_WARN=$'\e[1;33m' C_INFO=$'\e[1;34m'
    R_0=$'\001\e[0m\002' R_TITLE=$'\001\e[1;36m\002' R_DIM=$'\001\e[2m\002'
    R_ERR=$'\001\e[1;31m\002' R_OK=$'\001\e[1;32m\002' R_WARN=$'\001\e[1;33m\002'
  fi
}

ui_glyphs() {
  if ((UI_UNICODE)); then
    G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯' G_H='─' G_V='│' G_LT='├' G_RT='┤'
    G_DOT='·' G_SEP='›' G_PROMPT='❯' G_OK='✔' G_ERR='✖' G_WARN='▲' G_INFO='●' G_STEP='▸' G_ELL='…'
    UI_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  else
    G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|' G_LT='+' G_RT='+'
    G_DOT='.' G_SEP='>' G_PROMPT='>' G_OK='+' G_ERR='x' G_WARN='!' G_INFO='*' G_STEP='>' G_ELL='~'
    UI_SPIN=('|' '/' '-' '\')
  fi
}

# Outer width of every frame: the terminal width, clamped to 60..100 (re-read on each screen,
# so a resized window is picked up).
ui_width() {
  local c=${GM_COLUMNS:-}
  if [[ -z $c ]] && ((UI_TTY)); then c=$(tput cols 2>/dev/null || true); fi
  [[ $c =~ ^[0-9]+$ ]] || c=80
  ((c < 60)) && c=60
  ((c > 100)) && c=100
  UI_W=$c
}

# ---- string helpers (results go into the variable named by the first argument) ----------------
ui_vlen() {  # ui_vlen OUT "text"  -> visible length (colour escapes ignored)
  local -n __o_vlen=$1
  local __s=$2
  __s=${__s//$'\e'\[*([0-9;])m/}
  __o_vlen=${#__s}
}

ui_repeat() {  # ui_repeat OUT "char" N
  local -n __o_rep=$1
  local __n=$3 __t
  ((__n < 0)) && __n=0
  printf -v __t '%*s' "$__n" ''
  __o_rep=${__t// /$2}
}

ui_strip() {  # ui_strip OUT "text"  -> text without colour escapes
  local -n __o_strip=$1
  local __s=$2
  __o_strip=${__s//$'\e'\[*([0-9;])m/}
}

ui_clip() {  # ui_clip OUT "text" MAXWIDTH  -> text, or plain text cut with an ellipsis
  local -n __o_clip=$1
  local __s=$2 __max=$3 __len
  ui_vlen __len "$__s"
  if ((__len <= __max)); then
    __o_clip=$__s
  else
    ui_strip __s "$__s"
    ((__max < 2)) && __max=2
    __o_clip=${__s:0:__max-1}$G_ELL
  fi
}

ui_pad() {  # ui_pad OUT "text" WIDTH  -> text padded with spaces to WIDTH visible columns
  local -n __o_pad=$1
  local __s=$2 __w=$3 __len __sp
  ui_vlen __len "$__s"
  ui_repeat __sp ' ' $((__w - __len))
  __o_pad=$__s$__sp
}

# Untrusted text (hostnames from a log, inbound remarks, ...) must never reach the terminal raw:
# an embedded ESC sequence could rewrite the screen. ui_safe drops every control character.
ui_safe() {  # ui_safe OUT "text" [MAXLEN]
  local -n __o_safe=$1
  local __s=$2 __max=${3:-0}
  __s=${__s//[[:cntrl:]]/}
  if ((!UI_UNICODE)); then __s=${__s//[^ -~]/?}; fi      # byte-wise slicing in a non-UTF-8 locale would split characters
  if ((__max > 0 && ${#__s} > __max)); then __s=${__s:0:__max-1}$G_ELL; fi
  __o_safe=$__s
}
