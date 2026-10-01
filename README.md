# Gemini via Iran-side Shecan

Routes 9 Gemini hostnames out of the foreign 3X-UI Xray through a small relay on the Iran server, so they leave from the Iran IP that is registered with Shecan. Everything else keeps using the existing routing.

```
user -> Iran tunnel -> foreign Xray -(9 domains)-> ir-gemini (SS-2022) -> Iran Xray -> Shecan DNS/SNI proxy -> Google
                                     -(rest)----> existing outbounds, unchanged
```

One tool, `gemini-menu`, runs on both servers. It never touches the tunnel, the panel's inbounds or users, or existing firewall rules.

## Install

On each server, as root (needs `curl dnsutils openssl python3 iproute2 netcat-openbsd sqlite3`, all from apt; the tool offers to install what is missing):

```bash
curl -fsSL https://raw.githubusercontent.com/mahdizo3181/shecan-manager/main/gemini-menu.sh -o gemini-menu.sh
chmod +x gemini-menu.sh
./gemini-menu.sh            # interactive menu; asks once which server this is, then remembers it
```

The first interactive run offers to install the file as `/usr/local/bin/gemini-menu`; `setup` on the Iran server does it too, because the health timer runs that installed file. The role is remembered in `/etc/gemini-shecan/role` (`gemini-menu role iran|foreign|show`).

## Using it

```
gemini-menu                          menu: numbered list, type a number + Enter (r = refresh, 0 = back / exit)
gemini-menu iran help                every Iran command
gemini-menu foreign help             every foreign command
gemini-menu [flags] iran|foreign <command>
```

| | Iran server | Foreign server |
|---|---|---|
| Install / repair | `iran setup` | `foreign setup` |
| Health | `iran status` | `foreign status` |
| Repairs | `iran repair [all\|firewall\|config\|timer\|register]` | `foreign routing on\|off`, `foreign sniffing fix` |
| Day-2 | `register`, `foreign-ip`, `domain`, `logs`, `access-on`, `service`, `telegram`, `backups` | `test`, `scope`, `domain`, `learn`, `sync-iran`, `backups` |
| Undo | `iran rollback`, `iran uninstall` | `foreign rollback`, `foreign revert` |

`status` exits 0 (healthy), 1 (warnings) or 2 (broken). **Common flags:** `--dry-run` prints what would happen and changes nothing, `--yes` answers the plain `[y/N]` confirmations (Enter always means No), `--ascii`, `--no-color`. Backups go to `/root/gemini-shecan-backup/<timestamp>/`. Secrets (Shecan URL, SS key, Telegram token) are never printed or logged.

`setup-iran.sh` and `setup-foreign.sh` are thin shims kept for the old command lines (`./setup-iran.sh --dry-run`, `./setup-foreign.sh test`); they call `gemini-menu`.

### 1. Iran server

```bash
export FOREIGN_IP=<foreign server IPv4>
export SHECAN_REGISTER_URL='<your Shecan registration URL>'      # secret, stored in /etc/gemini-shecan/shecan-url (600)
# optional: export TG_BOT=... TG_CHAT=...                         # Telegram alerts from the health timer

./gemini-menu.sh --role iran setup --dry-run --xray-version <X.Y.Z>
./gemini-menu.sh --role iran setup           --xray-version <X.Y.Z>
```

Both Xray versions should match (`gemini-menu foreign status` shows the panel's). If GitHub is unreachable from Iran, copy a binary over and add `--xray-bin /path/to/xray`. The SS key comes from `SS_KEY` or `--key-file`, else an existing `/root/gemini-shecan/ss.key`, else it is generated (`openssl rand -base64 16`, mode 600). Options: `--ss-port` (default 20443), `--shecan-url-file FILE`. At the end it prints the key file path and the exact commands for the foreign server.

The relay is a separate Xray service `xray-gemini`; its port is opened to the foreign IP only; the Shecan IP is re-registered and the DNS hijack verified every 5 minutes by `gemini-shecan-watch.timer`. The relay's last routing rule (block everything else) is what stops it being an open proxy; setup proves it by fetching `gemini.google.com` through the relay (must work) and `example.com` (must be refused).

### 2. Foreign server

```bash
scp root@<IRAN_IP>:/root/gemini-shecan/ss.key /root/gemini-ss.key && chmod 600 /root/gemini-ss.key
./gemini-menu.sh --role foreign setup --dry-run --iran-ip <IRAN_IP> --key-file /root/gemini-ss.key
./gemini-menu.sh --role foreign setup           --iran-ip <IRAN_IP> --key-file /root/gemini-ss.key
gemini-menu foreign test
```

`setup` checks the relay port first, finds the panel database and Xray, patches the Xray **template** (outbound `ir-gemini` appended last; two rules inserted right after `bittorrent -> blocked`: UDP/443 for the domains -> blocked so QUIC falls back to TCP, and the domains -> `ir-gemini`), validates it with the panel's own Xray, and only then writes it. **The restart drops all user connections for a few seconds**, so it asks `Proceed? [y/N]` first. The write is compare-and-swap: if someone saved in the panel in the meantime, nothing is written. If the restart or the regenerated config does not check out, the previous template is restored automatically.

Domain rules need sniffing (tls/http, `routeOnly` off) on the client inbounds; `foreign sniffing audit` lists the ones that would miss, `--fix-sniffing` (or `sniffing fix`) corrects them and keeps the old values in the backup. If the phone client resolves DNS itself and sends IPs, turn on FakeDNS in the client.

Step-by-step rollout with the "if something goes wrong" commands: [docs/runbook.md](docs/runbook.md).

## How the repository is organised

```
src/lib/    foundation: terminal renderer, Enter-confirmed menu engine, action runner, input validation
src/app/    the tool: Iran modules (10-90) and foreign modules (91-96)
src/entry/  entry points (gemini-menu = the real tool, demo = a small example of the foundation)
build.sh    bundles lib + app + entry into ONE file
dist/       the bundles (committed, so they can be fetched from raw GitHub)
gemini-menu.sh   a copy of dist/gemini-menu.sh: the canonical install URL (build.sh keeps it in sync)
tests/      ./tests/run.sh: logic, sandboxed Iran and foreign runs, real-terminal (pty) runs
docs/       foundation, Iran, foreign, and the rollout runbook
```

Edit `src/`, run `./build.sh`, run `./tests/run.sh`; never edit `dist/` or the root `gemini-menu.sh` by hand. Details: `docs/phase1-foundation.md`, `docs/phase2-iran.md`, `docs/phase3-foreign.md`.
