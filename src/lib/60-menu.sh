# shellcheck shell=bash
# 60-menu.sh - data-driven menu engine. Screens are DATA, not hand-written loops.
#
#   menu_screen NAME "Title" [status_fn] [build_fn]
#   menu_item   NAME KEY "Label" "hint" HANDLER [enable_fn]
#   menu_run    ROOT_SCREEN                      (call it as its own statement, not after || / if)
#
# HANDLER kinds
#   screen:NAME     push another screen (b goes back)
#   action:fn args  run fn through act_run: errexit, Ctrl-C handling, one RESULT line
#   view:fn args    like action, but prints nothing on success (read-only displays)
#   call:fn args    run fn in this shell, no isolation (for menu-state tweaks only)
#   back | quit
#
# status_fn  draws the status card above the menu (use ui_box_* and probe_refresh).
# build_fn   runs before every render; it may call menu_reset NAME + menu_item to (re)build
#            dynamic items (a domain list, a backup list).
# enable_fn  returns non-zero to grey an item out; it can set MENU_WHY to say why.
#
# Standard keys, always available on every screen (so items may not use them):
#   b back   q quit   r refresh status   d toggle dry-run   ? help
# Input is a line: type the key, edit with backspace/arrows, press Enter. Nothing fires on a
# single keypress. Unknown input prints one inline error; the screen is NOT redrawn.

declare -A M_TITLE=() M_ITEMS=() M_STATUS=() M_BUILD=()
MENU_STACK=()
MENU_QUIT=0 MENU_REDRAW=0 MENU_WHY=""
MENU_US=$'\x1f'
MENU_RESERVED=" b q r d h ? back quit exit refresh help "

menu_screen() {  # menu_screen NAME "Title" [status_fn] [build_fn]
  [[ $1 =~ ^[a-z0-9_]+$ ]] || gm_fatal "screen name must be [a-z0-9_]+: $1"
  M_TITLE[$1]=$2
  M_STATUS[$1]=${3:-}
  M_BUILD[$1]=${4:-}
  M_ITEMS[$1]=""
}

menu_reset() { M_ITEMS[$1]=""; }

menu_item() {  # menu_item NAME KEY "Label" "hint" HANDLER [enable_fn]
  local name=$1 key=${2,,} label=$3 hint=${4:-} handler=$5 enable=${6:-}
  [[ -n ${M_TITLE[$name]:-} ]] || gm_fatal "menu_item: screen '$name' is not defined"
  [[ $key =~ ^[a-z0-9]{1,3}$ ]] || gm_fatal "menu key must be 1-3 letters/digits: '$2'"
  [[ $MENU_RESERVED != *" $key "* ]] || gm_fatal "menu key '$key' is reserved (screen $name)"
  [[ $handler =~ ^(screen:[a-z0-9_]+|action:.+|view:.+|call:.+|back|quit)$ ]] \
    || gm_fatal "menu item '$key' on '$name': bad handler '$handler'"
  if [[ ${M_ITEMS[$name]} == "$key$MENU_US"* || ${M_ITEMS[$name]} == *$'\n'"$key$MENU_US"* ]]; then
    gm_fatal "menu key '$key' is used twice on screen '$name'"
  fi
  M_ITEMS[$name]+="$key$MENU_US$label$MENU_US$hint$MENU_US$handler$MENU_US$enable"$'\n'
}

menu_crumbs() {  # menu_crumbs OUT  -> "Main > Domains"
  local -n __o_cr=$1
  local s out=""
  for s in "${MENU_STACK[@]}"; do
    if [[ -n $out ]]; then out+=" $G_SEP "; fi
    out+=${M_TITLE[$s]}
  done
  __o_cr=$out
}

menu_render() {  # menu_render NAME
  local name=$1 crumbs key label hint handler enable why i n=0 kw=0 lw=0 rem kc lc hc foot dm
  local -a K=() L=() H=() W=() X=()
  ui_width
  if [[ -n ${M_BUILD[$name]:-} ]]; then "${M_BUILD[$name]}"; fi
  ui_blank
  if [[ -n ${M_STATUS[$name]:-} ]]; then
    "${M_STATUS[$name]}"
    ui_blank
  fi
  while IFS=$MENU_US read -r key label hint handler enable; do
    [[ -n $key ]] || continue
    why=""
    MENU_WHY=""
    if [[ -n $enable ]] && ! "$enable"; then why=${MENU_WHY:-unavailable}; fi
    K+=("$key") L+=("$label") H+=("$hint") W+=("$why")
    if ((${#key} + 2 > kw)); then kw=$((${#key} + 2)); fi
    if ((${#label} > lw)); then lw=${#label}; fi
    n=$((n + 1))
  done <<<"${M_ITEMS[$name]}"
  ((lw > 34)) && lw=34

  menu_crumbs crumbs
  ui_box_top "$crumbs"
  if is_dry; then ui_box_row "${C_WARN}DRY-RUN is ON: actions only describe what they would do${C_0}"; fi
  if ((n == 0)); then ui_box_row "${C_DIM}(nothing here yet)${C_0}"; fi
  for ((i = 0; i < n; i++)); do
    if [[ -n ${W[i]} ]]; then
      kc="${C_DIM}[${K[i]}]${C_0}"
      ui_clip lc "${L[i]}" "$lw"
      hc="(${W[i]})"
      ui_pad kc "$kc" "$kw"
      ui_pad lc "${C_DIM}${lc}${C_0}" "$lw"
      ui_box_row " $kc  $lc  ${C_DIM}${hc}${C_0}"
    else
      kc="${C_KEY}[${K[i]}]${C_0}"
      ui_clip lc "${L[i]}" "$lw"
      ui_pad kc "$kc" "$kw"
      ui_pad lc "$lc" "$lw"
      rem=$((UI_W - 4 - 1 - kw - 2 - lw - 2))
      hc=""
      if ((rem > 3 && ${#H[i]} > 0)); then
        ui_clip hc "${H[i]}" "$rem"
        hc="${C_DIM}${hc}${C_0}"
      fi
      ui_box_row " $kc  $lc  $hc"
    fi
  done
  ui_box_sep
  if is_dry; then dm="ON"; else dm="off"; fi
  foot=""
  if ((${#MENU_STACK[@]} > 1)); then foot+="${C_KEY}[b]${C_0} Back  "; fi
  foot+="${C_KEY}[q]${C_0} Quit  ${C_KEY}[r]${C_0} Refresh  ${C_KEY}[d]${C_0} Dry-run ${dm}  ${C_KEY}[?]${C_0} Help"
  ui_box_row " $foot"
  ui_box_bottom
}

menu_help() {
  ui_blank
  ui_rule "How this menu works"
  ui_say "Type the key of an item (for example ${C_KEY}1${C_0}) and press ${C_B}Enter${C_0}."
  ui_say "Nothing runs until you press Enter, so you can correct a typo with Backspace."
  ui_say "${C_KEY}b${C_0} back   ${C_KEY}q${C_0} quit   ${C_KEY}r${C_0} refresh the status   ${C_KEY}d${C_0} toggle dry-run"
  ui_say "Ctrl-C stops the operation that is running; it never closes the menu."
  ui_say "Inside an operation, type ${C_KEY}b${C_0} at any prompt to cancel it."
  ui_blank
}

menu_pop() {
  if ((${#MENU_STACK[@]} > 1)); then
    unset 'MENU_STACK[-1]'
    MENU_REDRAW=1
  else
    ui_note "You are at the top level. Type q to quit."
  fi
}

menu_invoke() {  # menu_invoke "label" handler
  local label=$1 handler=$2 kind arg
  local -a argv=()
  kind=${handler%%:*}
  arg=${handler#*:}
  case $kind in
    screen)
      if [[ -z ${M_TITLE[$arg]:-} ]]; then ui_err "screen '$arg' is not defined"; return 0; fi
      MENU_STACK+=("$arg")
      MENU_REDRAW=1
      ;;
    action)
      read -r -a argv <<<"$arg"
      act_run "$label" "${argv[@]}"
      if ((ACT_RC != 10)); then probe_invalidate; fi      # a cancelled action changed nothing
      MENU_REDRAW=1
      ;;
    view)
      read -r -a argv <<<"$arg"
      ACT_QUIET_OK=1 act_run "$label" "${argv[@]}"
      MENU_REDRAW=1
      ;;
    call)
      read -r -a argv <<<"$arg"
      "${argv[@]}" || ui_err "'${argv[0]}' returned an error"
      MENU_REDRAW=1
      ;;
    back) menu_pop ;;
    quit) MENU_QUIT=1 ;;
  esac
}

menu_dispatch() {  # menu_dispatch SCREEN "typed text"
  local name=$1 typed=$2 in key label hint handler enable why shown found=0
  in=${typed,,}
  MENU_REDRAW=0
  case $in in
    "") return 0 ;;
    q | quit | exit) MENU_QUIT=1; return 0 ;;
    b | back) menu_pop; return 0 ;;
    r | refresh) probe_invalidate; MENU_REDRAW=1; return 0 ;;
    d)
      if is_dry; then GM_DRY=0; ui_ok "Dry-run is OFF: actions will change things"; else GM_DRY=1; ui_warn "Dry-run is ON: actions will only describe what they would do"; fi
      MENU_REDRAW=1
      return 0
      ;;
    "?" | h | help) menu_help; return 0 ;;
  esac
  # Find the item first, run it AFTER the loop: inside `while read <<<...` stdin is the item list,
  # and an action that prompts would read its answers from there instead of the keyboard.
  while IFS=$MENU_US read -r key label hint handler enable; do
    if [[ $key == "$in" ]]; then found=1; break; fi
  done <<<"${M_ITEMS[$name]}"
  if ((!found)); then
    ui_safe shown "$typed" 24
    ui_err "\"$shown\" is not an option here - type a key from the list (for example ${C_KEY}1${C_0}), or ? for help"
    return 0
  fi
  why=""
  MENU_WHY=""
  if [[ -n $enable ]] && ! "$enable"; then why=${MENU_WHY:-unavailable}; fi
  if [[ -n $why ]]; then
    ui_warn "\"$label\" is not available right now: $why"
    return 0
  fi
  menu_invoke "$label" "$handler"
  return 0
}

menu_run() {  # menu_run ROOT
  local cur line rc crumbs prompt redraw=1
  if [[ -z ${M_TITLE[$1]:-} ]]; then gm_fatal "menu_run: screen '$1' is not defined"; fi
  MENU_STACK=("$1")
  MENU_QUIT=0
  if ((!IN_OK)); then
    ui_err "the menu needs a terminal for input"
    return 1
  fi
  while ((!MENU_QUIT && ${#MENU_STACK[@]} > 0)); do
    cur=${MENU_STACK[-1]}
    if ((redraw)); then
      menu_render "$cur"
      redraw=0
    fi
    menu_crumbs crumbs
    in_prompt prompt "$crumbs" ""
    in_read line "$prompt" && rc=0 || rc=$?
    case $rc in
      0) ;;
      130)
        ui_note "Ctrl-C only cancels a running operation. Type q to quit, b to go back."
        continue
        ;;
      *)
        MENU_QUIT=1
        continue
        ;;
    esac
    menu_dispatch "$cur" "$line"
    redraw=$MENU_REDRAW
  done
  return 0
}
