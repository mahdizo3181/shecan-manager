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
