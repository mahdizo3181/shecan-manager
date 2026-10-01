# Interaction rules (enforced by tests/run.sh, "house rules")

1. **Confirmations are `Question [y/N]: `.** `y`, `Y`, `yes`, `YES` = yes; `n`, `no` or just Enter = **No**.
   Anything else ("continue", "ok") is not guessed at: it asks again with a plain hint. `--yes` answers these.
   A word is typed only for destructive purges (uninstall, replacing a whole database): `Type yes to confirm, or press
   Enter to cancel`, case-insensitive, Enter cancels.
2. **Everything typed is visible and editable** (readline: backspace, arrows, paste). There is no hidden input
   anywhere (`read -s` is banned): the Shecan URL, Telegram token, IPs, ports and hostnames are all echoed.
   (Output still never prints the URL, the SS key or the token back; they are not written to logs.)
3. **English only.** No Persian / Arabic-script text anywhere (terminal bidi corrupts it).
4. **One numbered list per screen**, `1)` ... `9)`, no letter shortcuts for features (Setup is item 1).
   Every screen ends with `r) Refresh` and `0) Exit` (`0) Back` on sub-screens). Unknown input prints one inline
   error and does not redraw. No "press any key" pauses.
5. **Prompts are `Label [default]: `.** Enter accepts the default, `b` cancels, Ctrl-C stops the operation (never the menu).
6. **Screen management (real terminals only).** Each menu is drawn from the top of a cleared screen (scrollback is not
   erased). An action runs on its own clean screen; when it ends its output stays until you press Enter
   ("Press Enter to return to the menu"), then the screen clears and the dashboard returns with a "Last action" line.
   `GM_PAUSE=0` skips the Enter. Pipes, logs and `--help` never receive escape codes. On a terminal shorter than 34 lines the
   status card collapses passing checks into one row (`GM_FULL_STATUS=1` forces the full card).
7. **`gemini` is a link, never a clobber.** `/usr/local/bin/gemini` -> `gemini-menu`; an existing `gemini` that is not this
   tool is left alone (`GM_FORCE_LINK=1` overrides the PATH-shadow check).
