# Phase 1 foundation: UI engine, menu engine, action runner, input layer

Source lives in `src/lib/*.sh` (numeric prefix = load order). `./build.sh` bundles the libraries
plus one `src/entry/NAME.sh` into a single file `dist/NAME.sh` that runs as `bash dist/NAME.sh`,
as `curl -fsSL URL | bash`, or installed under `/usr/local/bin`. `tests/run.sh` runs 130+ logic
tests and `tests/pty_test.py` drives the real program through a pseudo-terminal.
`src/entry/demo.sh` is a working example of everything below.

| File | Provides |
|---|---|
| `00-base.sh` | globals (`GM_DRY`, `GM_YES`), temp dir, traps, `gm_fatal` (start-up errors only) |
| `10-term.sh` | colour / Unicode detection with ASCII fallback, palette, glyphs, width helpers, `ui_safe` |
| `20-render.sh` | frames (`ui_box_*`), badges, messages (`ui_ok/err/warn/info/note/step/rule`), spinner (`ui_task`) |
| `30-input.sh` | buffered input, validators `v_*`, prompts `prompt_*`, `confirm*`, `pick_many` |
| `40-action.sh` | `act_run` and the helpers used inside actions |
| `50-probe.sh` | parallel, cached, time-limited status probes for the dashboard |
| `60-menu.sh` | data-driven screens, navigation stack, Enter-confirmed dispatch |

## How the pieces hook in

```bash
# 1. a probe prints:  LEVEL <TAB> BADGE <TAB> detail [<TAB> what to do]      (fields non-empty)
probe_relay() { systemctl is-active -q xray-gemini \
  && printf 'ok\tACTIVE\tlistening on :%s\n' "$port" \
  || printf 'fail\tSTOPPED\tnot running\tService > Start\n'; }
probe_register relay probe_relay "Relay service"

# 2. the dashboard header is a function that draws a card from the probe cache
status() { probe_refresh; ui_box_top "GEMINI"; ui_box_kv "Role" "IRAN"; ui_box_probe "Relay" relay; ui_box_bottom; }

# 3. an action is a plain function: prompts re-ask on typos, `b` cancels, failures end it
change_ip() {
  local ip
  prompt_ipv4 ip "New foreign IPv4" || act_cancel
  confirm "Allow $ip to reach the relay?" y || act_cancel
  act_step "Updating the firewall"
  act_on_fail fw_remove "$ip"            # undone automatically if a later step fails
  act_do "allow $ip" fw_allow "$ip"      # dry-run aware; must-semantics (a failure ends the action)
  act_commit
}

# 4. screens are data
menu_screen main "Iran relay" status
menu_item   main 1 "Change foreign IP" "firewall only" action:change_ip
menu_item   main 2 "Domains"           ""              screen:domains
menu_run main        # as its own statement, never `menu_run main || ...`
```

## Contracts (each one is covered by a test)

* **Input is a line + Enter.** Nothing fires on a single keypress; Backspace/arrows edit the line.
  Unknown input prints one inline error and does not redraw. Empty Enter is ignored.
* **Prompts never `die`.** `prompt_*` / `confirm*` return 0 (ok), 1 (`confirm`: no) or 10 (cancelled:
  `b`, `back`, `cancel`, Ctrl-D or no terminal). Invalid values re-ask. In an action write
  `prompt_x var "Label" || act_cancel`.
* **Actions really have errexit.** bash silently disables `set -e` inside anything called from
  `cmd || true`, `if cmd`, `cmd && ...`. `act_run` therefore refuses to start from such a context
  (returns 70 with an explanation). Call it as its own statement. Inside an action, `must`,
  `act_fail`, `act_cancel` and `act_do` end the action even if errexit were suppressed.
* **Ctrl-C ends the operation, never the menu.** Inside an action: rollbacks and deferred
  cleanups run, the result line says `[INTERRUPTED]`. At a prompt: a hint is printed.
* **Honest results.** `[ OK ]`, `[DRY-RUN]` (nothing changed), `[CANCELLED]`, `[INTERRUPTED]`,
  `[FAILED]`, and `[PARTIAL]` when the action called `act_partial "what stays applied"`.
* **Actions run in a subshell**, so they cannot change the menu's variables. Keep state on disk (as the
  real tool already does) or print it. Read-only displays that must update in-process use
  `call:fn`.
* **Status never freezes the screen.** Probes run in parallel behind a spinner, each bounded by
  `GM_PROBE_TIMEOUT` (12 s); results are cached for `GM_STATUS_TTL` (30 s); `r` forces a refresh and
  any non-cancelled action invalidates the cache.
* **No full-screen clears.** Every screen is appended, so the output of the last action stays in
  the scrollback.
* **Untrusted text** (hostnames from a log, inbound remarks) goes through `ui_safe` before it is
  drawn: control characters, including ESC sequences, are dropped.
* **Piped installs work.** When stdin is not a terminal, input is read from `/dev/tty`.

## Phase 2 mapping (what plugs in where)

| Existing code in `gemini-menu.sh` | Becomes |
|---|---|
| `iran_checks`, `foreign_checks` (+ `CHK_*` globals) | probes: one function per check, hint included |
| `iran_menu`, `foreign_menu` and the 12 sub-loops | `menu_screen` / `menu_item` tables |
| `do_action ... \|\| true`, `cancel`, `die` inside actions | `act_run`, `act_cancel`, `act_fail` |
| `ask_line`, `ask_yn`, `ask_typed`, `read_secret`, `ui_multiselect` | `prompt_*`, `confirm`, `confirm_typed`, `prompt_secret`, `pick_many` |
| `iran_setup_main` steps, `begin_step` / manifest | `act_step` + `act_on_fail` / `act_partial`, manifest kept |
