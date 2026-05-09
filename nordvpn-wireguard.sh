#!/bin/sh
# NordVPN WireGuard endpoint updater for OpenWrt.
# Logs via syslog (read with `logread -e nordvpn-updater`).

set -u

readonly WG_INTERFACE="${WG_INTERFACE:-wg0}"
readonly MAX_SERVER_LOAD="${MAX_SERVER_LOAD:-20}"
readonly COUNTRY_ID="${COUNTRY_ID:-}"   # e.g. 202 for Switzerland; empty = any
readonly API="https://api.nordvpn.com/v1"
readonly LOCK="/var/lock/nordvpn-updater.lock"
readonly TAG="nordvpn-updater"

log()  { logger -s -t "$TAG" -- "$*"; }
die()  { log "ERROR: $*"; exit 1; }

# Single-instance lock.
exec 9>"$LOCK" || die "cannot open lock file"
flock -n 9 || { log "another instance is running; exit"; exit 0; }

api_get() {
    curl -fsS --max-time 15 --retry 2 --retry-delay 3 \
         -A "openwrt-$TAG/1.1" -G "$@"
}

get_peer_section() {
    uci -q show network \
        | grep -E "=wireguard_${WG_INTERFACE}\$" \
        | head -n1 | cut -d= -f1
}

fetch_recommendation() {
    set -- --data-urlencode "filters[servers_technologies][identifier]=wireguard_udp" \
           --data-urlencode "limit=1"
    [ -n "$COUNTRY_ID" ] && set -- "$@" --data-urlencode "filters[country_id]=$COUNTRY_ID"
    api_get "$@" "$API/servers/recommendations"
}

main() {
    local wg_peer cur_host srv_json load needs_update=0
    local new_host new_pubkey

    wg_peer=$(get_peer_section)
    [ -n "$wg_peer" ] || die "no WireGuard peer section for ${WG_INTERFACE}"

    cur_host=$(uci -q get "${wg_peer}.endpoint_host") \
        || die "endpoint_host not set on ${wg_peer}"

    srv_json=$(api_get --data-urlencode "filters[hostname]=${cur_host}" "$API/servers") \
        || { log "API unreachable; skip this run"; exit 0; }

    if [ "$srv_json" = "[]" ]; then
        log "current server ${cur_host} not in API (decommissioned?)"
        needs_update=1
    else
        load=$(printf '%s' "$srv_json" | jq -r '.[0].load // 101')
        log "current ${cur_host} load=${load}% max=${MAX_SERVER_LOAD}%"
        [ "$load" -gt "$MAX_SERVER_LOAD" ] && needs_update=1
    fi

    [ "$needs_update" -eq 1 ] || { log "load OK, no action"; exit 0; }

    rec_json=$(fetch_recommendation) || die "recommendation API failed"
    # Parse hostname + public key in one jq pass.
    parsed=$(printf '%s' "$rec_json" | jq -r '
        .[0] | [
          .hostname,
          (.technologies[]
             | select(.identifier=="wireguard_udp")
             | .metadata[]
             | select(.name=="public_key")
             | .value)
        ] | @tsv') || die "jq parse error"
    new_host=$(printf '%s' "$parsed" | cut -f1)
    new_pubkey=$(printf '%s' "$parsed" | cut -f2)

    [ -n "$new_host" ] && [ -n "$new_pubkey" ] || die "empty hostname/pubkey"

    if [ "$cur_host" = "$new_host" ]; then
        log "recommended server unchanged ($cur_host); skip"
        exit 0
    fi

    log "switching ${cur_host} -> ${new_host}"
    if ! { uci set "${wg_peer}.endpoint_host=${new_host}" \
        && uci set "${wg_peer}.public_key=${new_pubkey}" \
        && uci commit network; }
    then
        uci -q revert network
        die "uci update failed; reverted"
    fi

    ifup "$WG_INTERFACE" || log "ifup returned non-zero (continuing)"
    log "done"
}

main "$@"
