#!/bin/ash
# Config
# Script checks current server load and updates config if current load is higher than ApiNordvpnMaxLoad.
# can be added as crontab
set -x

CURRENT_NORDVPN_ADDRESS=$(sed -n '/^config wireguard_wg0$/,/^$/p' /etc/config/network  | grep 'option endpoint_host' | cut -d"'" -f 2)
RECOMMENDED_SERVER=$(curl -s https://api.nordvpn.com/v1/servers/recommendations?limit=1 | jq -r '.[0].hostname')

if [ "$CURRENT_NORDVPN_ADDRESS" != "$RECOMMENDED_SERVER" ]; then
    echo "current server: $CURRENT_NORDVPN_ADDRESS"
    echo "recommended server: $RECOMMENDED_SERVER"
    sed -i "s/$CURRENT_NORDVPN_ADDRESS/$RECOMMENDED_SERVER/g" /etc/config/network
    ubus call network.interface.wg0 down &&  ubus call network.interface.wg0 up
fi
else
    echo "NordVPN: Nothing to do, current server is the recommended one"
fi
