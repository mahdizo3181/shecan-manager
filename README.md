# Gemini via Iran-side Shecan

## Install (menu)

On each server (as root):

```bash
curl -fsSL https://raw.githubusercontent.com/mahdizo3181/shecan-manager/main/gemini-menu.sh -o /usr/local/bin/gemini-menu && chmod +x /usr/local/bin/gemini-menu
gemini-menu
```

`setup-iran.sh` and `setup-foreign.sh` are thin wrappers around `gemini-menu.sh`; keep them in the same folder.

Routes 9 Gemini hostnames out of the foreign 3X-UI Xray through a small relay on the Iran server, so they leave from the Iran IP that is registered with Shecan. Everything else keeps using the existing routing.

```
user -> Iran tunnel -> foreign Xray -(9 domains)-> ir-gemini (SS-2022) -> Iran Xray -> Shecan DNS/SNI proxy -> Google
                                     -(rest)----> existing outbounds, unchanged
```

| Script | Runs on | What it does |
|---|---|---|
| `setup-iran.sh` | Iran server | Installs a separate Xray as service `xray-gemini`, opens its port to the foreign IP only, registers the IP with Shecan, verifies the DNS hijack, adds a 5-minute health timer |
| `setup-foreign.sh` | Foreign server | Patches the Xray **template** in the 3X-UI database: outbound `ir-gemini` + two routing rules. Also has `test`, `audit`, `--rollback` |

Neither script touches the tunnel, the panel's inbounds or users, or existing firewall rules. Needs root and `curl dnsutils openssl python3 iproute2 netcat-openbsd sqlite3` (all from apt).

## Common flags

`--dry-run` prints what would happen and changes nothing. `--rollback` undoes the last run that changed something (run it again to go one run further back). `--yes` skips confirmations. Both are idempotent. Backups go to `/root/gemini-shecan-backup/<timestamp>/`.

## 1. Iran server

```bash
export FOREIGN_IP=<foreign server IPv4>
export SHECAN_REGISTER_URL='<your Shecan registration URL>'      # secret, stored in /etc/gemini-shecan/shecan-url (600)
# optional: export TG_BOT=... TG_CHAT=...                         # Telegram alerts from the health timer

./setup-iran.sh --dry-run --xray-version <X.Y.Z>
./setup-iran.sh           --xray-version <X.Y.Z>
```

Get `<X.Y.Z>` from the foreign server (`setup-foreign.sh` prints it too): both Xray versions should match.
If GitHub is unreachable from Iran, copy a binary over and add `--xray-bin /path/to/xray`.

The SS key is taken from `SS_KEY` or `--key-file`, else an existing `/root/gemini-shecan/ss.key`, else generated with `openssl rand -base64 16` and saved there (mode 600). Options: `--ss-port` (default 20443), `--shecan-url-file FILE` instead of the env var.

At the end it prints the key file path and the exact arguments for the foreign script.

## 2. Foreign server

Copy the key file over (`scp root@<IRAN_IP>:/root/gemini-shecan/ss.key /root/gemini-ss.key`), then:

```bash
./setup-foreign.sh --dry-run --iran-ip <IRAN_IP> --key-file /root/gemini-ss.key
./setup-foreign.sh           --iran-ip <IRAN_IP> --key-file /root/gemini-ss.key
./setup-foreign.sh test
```

`apply` checks `nc -zv` to the relay first, finds the DB (`--db` to override) and the panel's Xray (`--xray-bin`), patches the template, validates it with the panel's own Xray (`-test`), and only then writes the DB and restarts `x-ui`. **The restart drops all user connections for a few seconds**; you are asked to confirm unless `--yes`. If the restart or the regenerated config does not check out, the template is put back automatically.

The patch removes the old `gemini-shecan` outbound, rules pointing to it, and gemini-related balancers/observatory selectors; adds `ir-gemini` (appended last, so the default outbound is unchanged); inserts two rules right after the `bittorrent -> blocked` rule (UDP/443 for the domains -> blocked, so QUIC falls back to TCP; the domains -> `ir-gemini`). Nothing else is changed.

`test` starts a temporary local Xray whose only outbound is `ir-gemini` and curls two Gemini hostnames through it (`--all-domains` for all nine). `PASS` = 2xx/3xx. On failure it says which hop is the likely culprit.

`audit` (also part of `apply`) lists inbounds whose sniffing would stop domain rules from working. It changes nothing unless you pass `--fix-sniffing`.

Rollback: `./setup-foreign.sh --rollback` restores the saved template (and sniffing values if `--fix-sniffing` was used) and restarts `x-ui`. It restores only those rows, so traffic counters and clients changed since the backup are kept. `--rollback --restore-full-db` restores the whole DB copy instead.

## By hand

- Enable sniffing (`http`, `tls`; `routeOnly` off) on any inbound the audit flags, or use `--fix-sniffing`. Without the destination domain, the connection to `ir-gemini` carries an IP and the Iran relay refuses it.
- If the phone client misbehaves (it resolves DNS itself and sends IPs), turn on FakeDNS in the client.
- Keep the Shecan registration alive: the Iran timer re-registers every 5 minutes (`journalctl -u gemini-shecan-watch`).

## Notes

- The Iran relay's last routing rule (block everything else) is what stops it being an open proxy. Xray 26.x rejects a rule with only `outboundTag`, so the script writes it with `"network": "tcp,udp"`. The script also self-tests this: it fetches `gemini.google.com` through the relay (must work) and `example.com` (must be refused).
- Secrets (Shecan URL, SS key, Telegram token) are never printed or logged; the Shecan URL and Telegram token are passed to curl via stdin config, not on the command line.
