#!/bin/ash
# Config
# Script checks current server load and updates config if the current load is higher than ApiNordvpnMaxLoad.
# This script can be added as a crontab job.
set -x

REC_SRV=$(curl -s "https://api.nordvpn.com/v1/servers/recommendations?&filters\[servers_technologies\]\[identifier\]=wireguard_udp&limit=1")
CUR_NORDVPN_ADDR=$(sed -n '/^config wireguard_wg0$/,/^$/p' /etc/config/network | grep 'option endpoint_host' | cut -d"'" -f 2)
CUR_NORDVPN_PUBKEY=$(sed -n '/^config wireguard_wg0$/,/^$/p' /etc/config/network | grep 'option public_key' | cut -d"'" -f 2)
REC_SRV_ADDR=$(echo $REC_SRV | jq -r '.[0].hostname')
REC_SRV_PUBKEY=$(echo $REC_SRV | jq -r '.[] | .technologies[] | select(.identifier == "wireguard_udp") | .metadata[] | select(.name == "public_key") | .value')

if [ "$CUR_NORDVPN_ADDR" != "$REC_SRV_ADDR" ]; then
    echo "Current server: $CUR_NORDVPN_ADDR"
    echo "Recommended server: $REC_SRV"
    sed -i "s/$CUR_NORDVPN_ADDR/$REC_SRV/g" /etc/config/network
    sed -i "s/$CUR_NORDVPN_PUBKEY/$REC_SRV_PUBKEY/g" /etc/config/network
    ubus call network.interface.wg0 down && ubus call network.interface.wg0 up
else
    echo "NordVPN: Nothing to do, current server is the recommended one."
fi
