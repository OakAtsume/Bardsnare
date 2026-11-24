#!/bin/sh
# wg-watchdog — keep a WireGuard transport tunnel alive on OpenWRT.
#
# Checks (in order of strength):
#   1. the WG interface exists (`wg show <iface>`),
#   2. if PING_HOST is set, a peer IP *inside* the tunnel answers (best signal),
#   3. otherwise, the last handshake is fresh (WG rekeys ~every 120s).
# On failure it restarts the interface via netifd (`ifdown`/`ifup`), which
# re-reads the UCI config in /etc/config/network. After repeated failures it
# escalates to a full `/etc/init.d/network reload`.
#
# POSIX/ash (BusyBox) compatible. Logs to syslog:  logread -e wg-watchdog
# Config: edit the defaults below, or set them in UCI (/etc/config/wg-watchdog).
#
# Usage:  wg-watchdog.sh [--once | --daemon]
#   --once    run a single check+heal (good for cron)
#   --daemon  loop forever every INTERVAL seconds (used by the init.d service)

IFACE="${IFACE:-wg0}"                            # netifd/UCI interface name
PING_HOST="${PING_HOST:-}"                        # optional peer IP INSIDE the tunnel
HANDSHAKE_MAX_AGE="${HANDSHAKE_MAX_AGE:-200}"     # seconds; >~3min with no handshake = dead
INTERVAL="${INTERVAL:-30}"                        # daemon: seconds between checks
FAIL_ESCALATE="${FAIL_ESCALATE:-3}"              # consecutive failures before full net reload

TAG="wg-watchdog"
log() { logger -t "$TAG" "$1"; }

# Optional UCI overrides: /etc/config/wg-watchdog  ->  config wg-watchdog 'main'
if [ -f /etc/config/wg-watchdog ] && [ -f /lib/functions.sh ]; then
  . /lib/functions.sh
  config_load wg-watchdog 2>/dev/null && {
    config_get IFACE             main iface             "$IFACE"
    config_get PING_HOST         main ping_host         "$PING_HOST"
    config_get HANDSHAKE_MAX_AGE main handshake_max_age "$HANDSHAKE_MAX_AGE"
    config_get INTERVAL          main interval          "$INTERVAL"
    config_get FAIL_ESCALATE     main fail_escalate     "$FAIL_ESCALATE"
  }
fi

is_healthy() {
  # 1) interface present?
  wg show "$IFACE" >/dev/null 2>&1 || { log "unhealthy: interface '$IFACE' not present"; return 1; }

  # 2) active end-to-end ping through the tunnel (strongest check)
  if [ -n "$PING_HOST" ]; then
    ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1 && return 0
    log "unhealthy: no reply from $PING_HOST through $IFACE"
    return 1
  fi

  # 3) handshake freshness (fallback when no PING_HOST configured)
  latest=0
  for hs in $(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}'); do
    if [ "$hs" -gt "$latest" ] 2>/dev/null; then latest="$hs"; fi
  done
  now=$(date +%s)
  age=$(( now - latest ))
  if [ "$latest" -eq 0 ] || [ "$age" -gt "$HANDSHAKE_MAX_AGE" ]; then
    log "unhealthy: last handshake ${age}s ago (max ${HANDSHAKE_MAX_AGE}s)"
    return 1
  fi
  return 0
}

heal() {
  log "restarting '$IFACE' via netifd (ifdown/ifup, UCI config)"
  ifdown "$IFACE" 2>/dev/null
  sleep 3
  ifup "$IFACE" 2>/dev/null
  sleep 5
}

reload_network() {
  log "escalating: /etc/init.d/network reload"
  /etc/init.d/network reload 2>/dev/null
  sleep 8
}

# one check; heal + recheck if needed. 0 = healthy (or recovered), 1 = still down.
run_once() {
  is_healthy && return 0
  heal
  if is_healthy; then
    log "recovered: '$IFACE' healthy after restart"
    return 0
  fi
  return 1
}

command -v wg >/dev/null 2>&1 || { log "ERROR: wireguard-tools (wg) not installed"; exit 1; }

case "${1:---once}" in
  --once)
    run_once
    ;;
  --daemon)
    log "started (iface=$IFACE interval=${INTERVAL}s ping=${PING_HOST:-handshake-only})"
    fails=0
    while :; do
      if run_once; then
        fails=0
      else
        fails=$(( fails + 1 ))
        log "still unhealthy after restart (consecutive=$fails)"
        if [ "$fails" -ge "$FAIL_ESCALATE" ]; then
          reload_network
          fails=0
        fi
      fi
      sleep "$INTERVAL"
    done
    ;;
  *)
    echo "usage: $0 [--once|--daemon]" >&2
    exit 1
    ;;
esac
