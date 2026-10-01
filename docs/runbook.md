# Rollout runbook (first real deployment)

Order matters: **Iran first** (the relay), then **foreign** (the panel patch). Everything below is run as root.
Prerequisites: SSH to both servers, the Shecan registration URL, the foreign server's IPv4.

Every step that changes something has a `--dry-run` twin that prints the plan and changes nothing. The sandbox
tests use stubs, so treat the first real run as the real test: read the dry-run output before the real run.

## 0. Both servers: get the tool

```bash
curl -fsSL https://raw.githubusercontent.com/mahdizo3181/shecan-manager/main/gemini-menu.sh -o gemini-menu.sh
chmod +x gemini-menu.sh
```

## 1. Foreign server: read the Xray version (read-only)

```bash
./gemini-menu.sh --role foreign status      # exit 2 is expected before setup; read "Xray  X.Y.Z" and make sure the Panel row is RUNNING
```

If the panel shows `NO DB`, pass `--db /path/to/x-ui.db` (or open the panel > Xray Configs and press Save once).

## 2. Iran server

```bash
export FOREIGN_IP=<foreign IPv4>
export SHECAN_REGISTER_URL='<registration URL>'          # secret; optional: export TG_BOT=... TG_CHAT=...

# a) dry run: nothing is changed
./gemini-menu.sh --role iran setup --dry-run --xray-version <X.Y.Z>
# b) real run (asks "Proceed?"; ends with the exact foreign commands)
./gemini-menu.sh --role iran setup --xray-version <X.Y.Z>
# c) verify
gemini-menu iran status ; echo "exit=$?"                 # want: exit=0, every row ok
systemctl list-timers | grep gemini                      # the health timer is scheduled
gemini-menu iran info                                    # prints the scp + foreign setup commands
```

If GitHub is unreachable from Iran, copy an Xray binary over and add `--xray-bin /path/xray` to (a) and (b).

**Iran: if something goes wrong**

| Symptom | Command |
|---|---|
| Setup stopped half-way (result says `[PARTIAL]`) | read what was kept; re-run the same setup command to continue, or `gemini-menu iran rollback` to undo the whole run |
| `status` shows NO RULE / OUTDATED / OPEN PROXY | `gemini-menu iran repair all` (or `repair firewall\|config\|timer\|register`) |
| DNS hijack INACTIVE | `gemini-menu iran register` (a stale or expired Shecan URL shows here) |
| Remove everything this tool created | `gemini-menu iran uninstall` (keeps the SS key file and the backups) |

## 3. Foreign server

```bash
scp root@<IRAN_IP>:/root/gemini-shecan/ss.key /root/gemini-ss.key && chmod 600 /root/gemini-ss.key

# a) dry run: validates the patched template with the panel's own Xray, writes nothing
./gemini-menu.sh --role foreign setup --dry-run --iran-ip <IRAN_IP> --key-file /root/gemini-ss.key
# b) real run: type `yes` at the prompt (the panel restarts, users reconnect within seconds)
./gemini-menu.sh --role foreign setup --iran-ip <IRAN_IP> --key-file /root/gemini-ss.key
# c) verify
gemini-menu foreign status ; echo "exit=$?"              # 0 healthy; 1 = warnings (see the hint lines)
gemini-menu foreign test                                  # foreign -> Iran -> Shecan -> Google, per host
gemini-menu foreign sniffing audit                        # inbounds whose sniffing would make domain rules miss
```

If the audit lists inbounds: `gemini-menu foreign sniffing fix all` (old values are saved in the backup).
Note the backup folder printed during (b): `/root/gemini-shecan-backup/<timestamp>/`.

**Foreign: if anything goes south** (cheapest first)

| Situation | Command |
|---|---|
| Gemini misbehaves, you want the old routing back *quickly*, keep the setup | `gemini-menu foreign routing off` (rules stay, match nothing) ... `routing on` to return |
| Undo the last change to the panel | `gemini-menu foreign rollback` (restores the saved template; asks first; if the template was edited in the panel afterwards it refuses unless you type `yes`) |
| Remove the Gemini outbound and rules entirely | `gemini-menu foreign revert` |
| The panel database itself is damaged | `gemini-menu foreign rollback --restore-full-db` (restores the DB COPY: later traffic counters and client changes are lost) |
| The panel's own Xray config page shows an error | restore from the panel's backup, or `foreign rollback`; the tool already restores automatically when the restart fails |

A failed restart or an unexpected generated config is rolled back automatically; if even that fails the result says `[PARTIAL]`
with the command to run.

## 4. After both ends are up

```bash
gemini-menu iran status          # Iran: Registered FRESH, Timer ACTIVE, Guard GUARDED
gemini-menu foreign test --all-domains
journalctl -u gemini-shecan-watch -n 20     # Iran: the 5-minute health timer's results
```

If you add or remove a host later, change it on the foreign side (`foreign domain add|remove|set`): it offers to push the
same list to the Iran relay over SSH, or prints the one-line command to run there. The two lists must match.
