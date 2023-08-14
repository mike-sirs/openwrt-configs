#!/bin/ash
# Config
# Script checks current server load and updates config if current load is higher than ApiNordvpnMaxLoad.
# can be added as crontab
set -x

ApiNordvpnCountry=228 #USA
ApiNordvpnGroup=15 #P2P
ApiNordvpnMaxLoad=13

# Script
if [ -n "$ApiNordvpnCountry" ] && [ -n "$ApiNordvpnGroup" ] && { [ -n "$ApiNordvpnMaxLoad" ] || [ "$ApiNordvpnMaxLoad" -eq 0 ]; }; then
    CurrentNordvpnAddress=$(sed -n '/^config wireguard_wg0$/,/^$/p' /etc/config/network  | grep 'option endpoint_host' | cut -d"'" -f 2)
    CurrentNordvpnLoad=$(curl -s "https://api.nordvpn.com/server/stats/$CurrentNordvpnAddress" | grep -o '"percent":[0-9]*' | cut -d':' -f2)
    if [ "$CurrentNordvpnLoad" -gt "$ApiNordvpnMaxLoad" ]; then
        NewNordvpnAddress=$(curl -s "https://api.nordvpn.com/v1/servers/recommendations?filters\[servers_groups\]=15&filters\[country_id\]=228&filters\[servers_technologies\]\[identifier\]=wireguard_udp&limit=1" | grep -o '"hostname":"[^"]*' | cut -d'"' -f4)
        if [ -z "$NewNordvpnAddress" ]; then
            echo "NordVPN: server not found for the current configuration"
        else
            NewNordvpnLoad=$(curl -s "https://api.nordvpn.com/server/stats/$NewNordvpnAddress" | grep -o '"percent":[0-9]*' | cut -d':' -f2)
            if [ "$CurrentNordvpnAddress" != "$NewNordvpnAddress" ] && [ "$CurrentNordvpnLoad" -gt "$NewNordvpnLoad" ]; then
                echo "current load of $CurrentNordvpnAddress is $CurrentNordvpnLoad, switching to $NewNordvpnAddress"
                sed "s/$CurrentNordvpnAddress/$NewNordvpnAddress/g" -i /etc/config/network
                ubus call network.interface.wg0 down &&  ubus call network.interface.wg0 up
            fi
        fi
    fi
else
    echo "NordVPN: error! variables must be numbers!"
fi
