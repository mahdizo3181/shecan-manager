# Phase 2: the Iran role on the new engine

`dist/gemini-menu.sh` (built from `src/entry/gemini-menu.sh` + `src/app/*.sh` + the Phase 1
libraries) is the new engine. It contains the complete Iran role. The foreign role is still the
foreign role was ported in Phase 3 (`docs/phase3-foreign.md`).

## Layout

| Module | Contents |
|---|---|
| `src/app/10-paths.sh` | constants, `GM_ROOT` sandbox prefix, persisted role, state store, `need_cmds` |
| `src/app/20-backup.sh` | backup dir, rollback manifest, `put_file`, **`iran_step` / `iran_step_done`** |
| `src/app/30-firewall.sh` | ufw / iptables / nft: one additive, tagged ACCEPT rule (ported unchanged) |
| `src/app/40-engine.sh` | Shecan registration, DNS hijack check, Xray config generation, unit writers |
| `src/app/50-iran-probes.sh` | the 8 dashboard checks (probes) and the status card |
| `src/app/60-iran-actions.sh` | every operation as an action + the `iran_reconcile_*` repairs |
| `src/app/70-iran-setup.sh` | the setup engine (8 steps) |
| `src/app/80-iran-screens.sh` | the menu as data |
| `src/app/90-iran-cli.sh` | `gemini-menu iran <command>` |
| `src/entry/gemini-menu.sh` | argument parsing, role resolution, dispatch |

## Command line

`gemini-menu [flags] iran <command>`; flags may come before or after the command.
`status` (exit 0 healthy / 1 warnings / 2 broken), `setup`, `repair [all|firewall|config|timer|register]`,
`register`, `info [reveal]`, `foreign-ip [IP]`, `domain list|add|remove|set`, `logs`, `access-on|off`,
`service start|stop|restart`, `timer on|off`, `telegram set|off`, `backups list|diff|restore|undo N`,
`rollback`, `uninstall`, `install-self`, `watch`. `gemini-menu iran help` lists them.

## Your four reminders, and where they are enforced

| Requirement | Implementation | Test |
|---|---|---|
| **Role persistence** (Finding 11) | `resolve_role`: `--role` / `$GM_ROLE`, else `/etc/gemini-shecan/role`, else "relay installed here" => iran, else ask **once** and write the file. Never guessed from other software (an Iran server often runs 3X-UI). `gemini-menu role iran\|foreign\|show` | `iran_test.sh` (role section), `pty_iran_test.py` (first run) |
| **Idempotent repairs** (Finding 6) | `iran_act_change_ip` with the same IP re-checks and re-adds the rule; `iran_reconcile_firewall / config / timer / register` do nothing when already correct; every probe hint names a repair that exists | "SAME foreign IP", "repair ... is idempotent" |
| **One installed copy** (Finding 12) | the units run `/usr/local/bin/gemini-menu --role iran watch`; the access-log auto-off runs the same file; `repair timer` migrates the old `/usr/local/sbin/gemini-shecan-watch` copy and deletes it; the probe flags the old layout as `OUTDATED` | "timer runs the INSTALLED tool", "legacy timer migration" |
| **Honest transactions** (Finding 8) | a failing step undoes only itself; finished steps are kept and printed as `[PARTIAL]` with the command that undoes the run; an open-proxy self-test failure undoes the whole run | "honest partial failure", "open-proxy self-test" |

## Other fixes made in the port

* **Finding 13 (new):** `setup --foreign-ip NEW` on an installed relay was silently ignored (the stored
  `watch.conf` overwrote the flag). Flags now win in setup; stored values only fill gaps.
* Finding 9: `timer` / `service` / `access-on` / `backups N` validate their argument. `timer ""` used
  to switch the timer **off**; `service <anything>` went straight to `systemctl`.
* `put_file` creates a missing parent directory (a minimal server may lack `/usr/local/sbin`).
* Telegram token / chat id, Shecan URL, hostnames, minutes: validated with re-ask loops.
* The domain list shows every host (it used to stop at 12 while "remove by number" still worked on the hidden ones).
* `ss -tlnp` dump is now behind `--verbose`; discovery prints a 2-line summary.

## Foreign role

Ported in Phase 3: see `docs/phase3-foreign.md`.

## Testing without a server

`tests/iran_test.sh` runs the real bundle with `GM_ROOT` pointing at a temp directory and
`tests/fixtures/bin` supplying stub `systemctl` (really starts the unit's ExecStart),
`iptables` (rules in a file), `curl`, `dig`, `useradd`, and an Xray that listens on its port.
`tests/pty_iran_test.py` drives the menu through a real terminal against the same rig.
`GM_ASSUME_ROOT=1` is the test hook that skips the root check.

**Not covered by the rig:** real systemd, real ufw / nftables, a real Xray download, real Shecan.
Do a first run on the real server with `--dry-run`.
