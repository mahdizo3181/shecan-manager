# shellcheck shell=bash
# 30-firewall.sh - one additive ACCEPT rule for FOREIGN_IP -> SS_PORT/tcp (ufw, iptables or nft).
# Existing rules are never flushed, edited or reordered; our rule carries a comment tag so it can
# be found and removed again. (Ported unchanged from the original script.)

nft_py() {  # nft_py targets|ours   (reads `nft -j list ruleset` from stdin)
  python3 -c '
import json, sys
mode, tag = sys.argv[1], sys.argv[2]
want_ip = sys.argv[3] if len(sys.argv) > 3 else ""
items = json.load(sys.stdin).get("nftables", [])
chains = {}
for it in items:
    if "chain" in it:
        c = it["chain"]; chains[(c["family"], c["table"], c["name"])] = {"c": c, "rules": []}
for it in items:
    if "rule" in it:
        r = it["rule"]; k = (r["family"], r["table"], r["chain"])
        if k in chains: chains[k]["rules"].append(r)
for (fam, tab, name), d in chains.items():
    c, rules = d["c"], d["rules"]
    if mode == "ours":
        for r in rules:
            if r.get("comment") == tag and (not want_ip or ("\"" + want_ip + "\"") in json.dumps(r.get("expr"))):
                print(fam, tab, name, r["handle"])
        continue
    if fam not in ("inet", "ip") or c.get("hook") != "input" or c.get("type") != "filter": continue
    if tab.startswith("f2b"): continue          # fail2ban table, leave alone
    drops = c.get("policy") == "drop"
    if rules:                                   # unconditional final drop/reject
        ex = rules[-1].get("expr", [])
        if not any("match" in e for e in ex) and any(("drop" in e) or ("reject" in e) for e in ex): drops = True
    if drops: print(fam, tab, name)
' "$1" "$FW_COMMENT" "${2:-}"
}

fw_detect() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw; return; fi
  if command -v nft >/dev/null 2>&1; then
    local rs; rs=$(nft list ruleset 2>/dev/null || true)
    if grep -q '^table inet' <<<"$rs" && grep -q 'hook input' <<<"$rs"; then echo nft; return; fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    local n pol
    n=$(iptables -S INPUT 2>/dev/null | wc -l || true)
    pol=$(iptables -S INPUT 2>/dev/null | awk '$1=="-P"{print $3}' || true)
    if [[ $n -gt 1 || $pol == DROP ]]; then echo iptables; return; fi
  fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then echo nft; return; fi
  echo none
}

# fw_ensure KIND IP PORT -> prints "added" or "present" or "n/a"
fw_ensure() {
  local kind=$1 ip=$2 port=$3
  case $kind in
    ufw)
      if ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+ALLOW[[:space:]]+${ip//./\\.}([[:space:]]|\$)"; then echo present; return; fi
      ufw allow proto tcp from "$ip" to any port "$port" comment "$FW_COMMENT" >/dev/null
      echo added ;;
    iptables)
      local spec=(-s "$ip" -p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT)
      if iptables -C INPUT "${spec[@]}" 2>/dev/null; then echo present; return; fi
      iptables -I INPUT 1 "${spec[@]}"
      echo added ;;
    nft)
      local out t fam tab chain any_added=0 any=0
      out=$(nft -j list ruleset | nft_py targets)
      while read -r fam tab chain; do
        [[ -n ${fam:-} ]] || continue
        any=1
        if nft -j list chain "$fam" "$tab" "$chain" | nft_py ours "$ip" | grep -q .; then continue; fi
        printf 'insert rule %s %s %s ip saddr %s tcp dport %s counter accept comment "%s"\n' \
          "$fam" "$tab" "$chain" "$ip" "$port" "$FW_COMMENT" | nft -f -
        any_added=1
      done <<<"$out"
      if [[ $any == 0 ]]; then echo n/a; elif [[ $any_added == 1 ]]; then echo added; else echo present; fi ;;
    *) echo n/a ;;
  esac
}

fw_remove() {
  local kind=$1 ip=$2 port=$3
  case $kind in
    ufw)      ufw --force delete allow proto tcp from "$ip" to any port "$port" >/dev/null 2>&1 || true ;;
    iptables) while iptables -D INPUT -s "$ip" -p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; do :; done ;;
    nft)
      local fam tab chain h
      nft -j list ruleset | nft_py ours "$ip" | while read -r fam tab chain h; do
        nft delete rule "$fam" "$tab" "$chain" handle "$h" || true
      done ;;
  esac
}
