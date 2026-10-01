#!/usr/bin/env python3
"""Create a fake 3X-UI database: mkpanel.py DBFILE"""
import json, sqlite3, sys
tpl = {
  "log": {"access": "none", "loglevel": "warning"},
  "api": {"tag": "api", "services": ["HandlerService", "StatsService"]},
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "blocked"}],
  "routing": {"domainStrategy": "AsIs", "rules": [
    {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
    {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
    {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]}]}}
con = sqlite3.connect(sys.argv[1])
con.execute("create table settings (id integer primary key, key text, value text)")
con.execute("create table inbounds (id integer primary key, remark text, port integer, protocol text, enable integer, sniffing text, tag text)")
con.execute("insert into settings (key, value) values ('xrayTemplateConfig', ?)", (json.dumps(tpl, indent=2),))
good = json.dumps({"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False})
con.executemany("insert into inbounds (remark, port, protocol, enable, sniffing, tag) values (?,?,?,?,?,?)", [
  ("Phone", 8443, "vless", 1, good, "in-8443"), ("Laptop", 2053, "trojan", 1, good, "in-2053"),
  ("", 443, "vless", 1, good, "in-443"), ("api", 62789, "tunnel", 1, "", "api")])
con.commit()
