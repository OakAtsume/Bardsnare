# wg-watchdog — WireGuard transport keep-alive (OpenWRT)

Restarts the WireGuard transport tunnel if it dies (the "random blackout" failure mode: tunnel drops, sensors can't reach Graylog). Checks interface presence + handshake freshness (optionally a ping through the tunnel), heals via netifd/UCI (`ifdown`/`ifup`), escalates to a full network reload after repeated failures.

## Deploy (on the OpenWRT VM)
```sh
# 1. copy files over (from your workstation)
scp ops/openwrt/wg-watchdog.sh   root@<openwrt-vm>:/usr/bin/wg-watchdog.sh
scp ops/openwrt/wg-watchdog.init root@<openwrt-vm>:/etc/init.d/wg-watchdog

# 2. on the VM: make executable
chmod +x /usr/bin/wg-watchdog.sh /etc/init.d/wg-watchdog

# 3. set your interface name (default wg0) — see UCI config below, or edit the script

# 4. enable at boot + start
/etc/init.d/wg-watchdog enable
/etc/init.d/wg-watchdog start

# 5. watch it
logread -e wg-watchdog -f
```

Prereq: `wireguard-tools` (`opkg install wireguard-tools`) — needed for `wg`.

## Configure (optional, via UCI) — `/etc/config/wg-watchdog`
```
config wg-watchdog 'main'
    option iface             'wg0'          # your WG interface in /etc/config/network
    option ping_host         '10.10.0.1'    # a peer IP INSIDE the tunnel (best health check)
    option handshake_max_age '200'          # seconds; used only if ping_host is empty
    option interval          '30'           # seconds between checks (daemon mode)
    option fail_escalate     '3'            # consecutive fails -> full network reload
```
Setting **`ping_host`** to the Graylog-side tunnel IP is strongly recommended — it's a true end-to-end "is traffic actually flowing" test, vs. just "the interface exists."

## Lightweight alternative (cron instead of a daemon)
If you'd rather not run a loop:
```
# crontab -e   (then: /etc/init.d/cron enable && /etc/init.d/cron start)
* * * * * /usr/bin/wg-watchdog.sh --once
```
Runs one check+heal per minute.

## Notes
- `ifdown`/`ifup` is the UCI-driven restart — netifd re-reads `/etc/config/network`, so it always applies your current WG config.
- This is a **mitigation**, not a root-cause fix. If it's healing often, check *why* the tunnel dies — VM host stability, `logread` around the drop, memory pressure on the OpenWRT VM, or the peer endpoint flapping.
- Test it: `wg set <iface> peer <pubkey> remove` or `ifdown <iface>` manually, then watch `logread -e wg-watchdog` bring it back.
