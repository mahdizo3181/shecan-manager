# Phase 3: the foreign role (3X-UI) on the new engine

`gemini-menu --role foreign ...` (or `gemini-menu foreign ...`) is the previous foreign script, rebuilt on the
Phase 1 foundation. `dist/gemini-menu.sh` now contains both roles; the previous `gemini-menu.sh` at the repo
root is no longer needed by the shims.

| Module | Contents |
|---|---|
| `src/app/91-foreign-engine.sh` | panel discovery, template read, **compare-and-swap commit**, guarded restore, safe Iran-sync command; `py_tpl` (the template patch program) is unchanged |
| `src/app/92-foreign-probes.sh` | 7 dashboard checks + status card |
| `src/app/93-foreign-actions.sh` | test, routing, scope, domains, sync, sniffing, learn, backups, revert, rollback |
| `src/app/94-foreign-setup.sh` | the setup engine |
| `src/app/95-foreign-screens.sh`, `96-foreign-cli.sh` | the menu as data, `gemini-menu foreign <command>` |

## Your four focus areas

| Requirement | Implementation | Test (`tests/foreign_test.sh` unless noted) |
|---|---|---|
| **1. Compare-and-swap (Finding 7)** | An action reads the template once. `foreign_commit` writes with `UPDATE settings SET value=NEW WHERE key='xrayTemplateConfig' AND value=<exactly what was read>` inside ONE `BEGIN IMMEDIATE` transaction (sniffing changes ride in it; each also guarded). A refused write prints "changed by someone else ... NOTHING was written", leaves **no stray backup**, and the next run works. Rollback is guarded the same way: it restores only if the template is still the one this run wrote, otherwise it asks an explicit `[y/N]` (Enter = No) that `--yes` cannot answer (`confirm_force`). | "Finding 7" section (a panel edit during the confirmation window is preserved), "guarded rollback" |
| **2. Learn mode security (Findings 4, 10)** | The access log is client-written. `learn_capture` keeps only strict DNS names (<=253 chars, letters/digits/hyphen/dots); everything else is dropped and counted. Each kept host goes through the same `v_hostname` as typed input. The Iran sync command is built by `foreign_sync_cmd`: every host re-validated, every word `printf %q`-quoted, ssh called with `--` and a validated IPv4. Screen output goes through `ui_safe` (control characters dropped). | "learn mode: hostile log lines" (`$()`, `;`, ESC sequences never reach the screen, the template or a shell), "sync command builder" |
| **3. Multi-select (Findings 3, 4)** | Every picker is `pick_many`: Enter-confirmed, parsed without globbing, a bad token rejects the whole line, `b` returns 10 and leaves the caller's data alone. Learn, scope and sniffing-fix use it and call `act_cancel` on 10. | "learn: cancelling the picker", "interactive scope: b cancels", `pty_foreign_test.py` (`*`, `1a`, `b`) |
| **4. Rule placement + automatic rollback** | `py_tpl patch` inserts the udp/443 block rule and the domains -> `ir-gemini` rule right after the `bittorrent -> blocked` rule, appends the outbound last, and **refuses to guess** if that rule is missing. The patched template must pass the panel's own `xray -test` (in both outbound forms) before anything is written. After the write, a failed restart or a config that does not show the expected outbound triggers `foreign_auto_restore` (compare-and-swap restore + restart); if even that fails the result is `[PARTIAL]` with the command that fixes it. | "automatic restore", "validation refusals", "real setup" (rule order asserted) |

## Other changes in the port

* `wait_xray` warns when the panel did not rewrite `config.json` on restart (the old check could be satisfied by a stale file).
* `learn` restored the access log with the literal text `__unset__` when it had originally been unset; it now restores `none`.
* A test whose relay port is unreachable now fails even if some probe got an answer (the verdict was already printed, the exit code was not).
* Inbound lists use a non-whitespace separator: an empty remark used to shift columns.
* Back-to-back commits in one action (learn mode) each get their own backup folder; two runs in one second no longer share one.
* `ui_safe` shows non-ASCII as `?` in a non-UTF-8 locale instead of slicing multi-byte characters in half.
* `scope pick` exists on the command line; `sniffing fix` validates its id list.

## Command line

`gemini-menu foreign help`: `status`, `setup`, `test [--quick]`, `routing on|off|status`, `scope all|set|pick|list`,
`domain list|add|remove|set`, `sync-iran`, `learn`, `learn-restore`, `sniffing audit|fix`, `backups list|diff|restore N`,
`revert`, `rollback [--restore-full-db]`, `install-self`. Exit codes as on the Iran side (status: 0 / 1 warnings / 2 broken).

## Testing without a panel

`tests/foreign_test.sh` creates a real SQLite database (`settings`, `inbounds`), a fake `systemctl x-ui` that
regenerates `config.json` from the stored template and starts a process named like the panel's Xray (so `pgrep -x`
is exercised), and a switch that makes the next restart fail. `tests/pty_foreign_test.py` drives the menu through a real
terminal. **Not covered:** a real 3X-UI, a real Xray `-test`, a real restart of your panel. Do the first run with `--dry-run`,
and note the backup folder it prints when you run it for real.
