#!/bin/ash
#
# This script intelligently manages your NordVPN WireGuard connection on OpenWrt.
#
# It periodically checks the load of the current NordVPN server. If the load
# exceeds the configured maximum, or if the server is decommissioned, it
# automatically fetches the best recommended server from the NordVPN API
# and updates the OpenWrt network configuration.
#
# Crontab setup to run every 30 minutes:
# */30 * * * * /path/to/this/nordvpn_updater.sh
#

# --- Script Configuration ---
set -o pipefail # The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -o nounset  # Treat unset variables as an error.
set -o errexit  # Exit immediately if a command exits with a non-zero status.

# --- User Configuration ---
readonly WG_INTERFACE="wg0" # The name of your WireGuard interface in OpenWrt.
readonly MAX_SERVER_LOAD=20 # The maximum desired server load percentage.
readonly NORDVPN_API_BASE_URL="https://api.nordvpn.com/v1"

# --- Helper Functions ---

# Finds the uci configuration section for the WireGuard peer.
# On OpenWrt, this is typically the first section of type "wireguard_{interface_name}".
get_peer_section() {
    local peer_type="wireguard_${WG_INTERFACE}"
    local peer_section

    # Find the section name (e.g., network.@wireguard_wg0[0]) for the peer.
    peer_section=$(uci show network | grep "=${peer_type}" | head -n 1 | cut -d'=' -f1)

    if [ -z "${peer_section}" ]; then
        echo "Error: Could not find a WireGuard peer section of type '${peer_type}'." >&2
        echo "Please check your '/etc/config/network' file and the WG_INTERFACE variable." >&2
        return 1
    fi

    echo "${peer_section}"
}

# Fetches the best recommended server and updates the configuration.
update_server() {
    local wg_peer
    wg_peer=$(get_peer_section) || return 1

    # Get the single best recommended WireGuard server from the API.
    local rec_srv_json
    rec_srv_json=$(curl -s -G --data-urlencode "filters[servers_technologies][identifier]=wireguard_udp" --data-urlencode "limit=1" "${NORDVPN_API_BASE_URL}/servers/recommendations")

    # Exit if the API response is empty or not a valid JSON array.
    if ! echo "${rec_srv_json}" | jq -e '.[0]' > /dev/null; then
        echo "Error: Failed to get a valid recommendation from NordVPN API." >&2
        return 1
    fi

    # Parse the JSON to get the new server's hostname and public key.
    local rec_srv_addr
    rec_srv_addr=$(echo "${rec_srv_json}" | jq -r '.[0].hostname')

    local rec_srv_pubkey
    rec_srv_pubkey=$(echo "${rec_srv_json}" | jq -r '.[0].technologies[] | select(.identifier == "wireguard_udp") | .metadata[] | select(.name == "public_key") | .value')

    local current_host
    current_host=$(uci get "${wg_peer}.endpoint_host")

    if [ "${current_host}" != "${rec_srv_addr}" ]; then
        echo "New recommended server: ${rec_srv_addr}. Updating configuration."

        # Use 'uci' to safely update the peer configuration.
        uci set "${wg_peer}.endpoint_host=${rec_srv_addr}"
        uci set "${wg_peer}.public_key=${rec_srv_pubkey}"
        uci commit network

        echo "Restarting WireGuard interface (${WG_INTERFACE})..."
        # Restart the interface to apply the new settings.
        ifdown "${WG_INTERFACE}" && ifup "${WG_INTERFACE}"

        echo "Update complete."
    else
        echo "Recommended server is the same as the current one. No action taken."
    fi
}

# --- Main Logic ---
main() {
    local wg_peer
    wg_peer=$(get_peer_section) || exit 1

    local current_host
    current_host=$(uci get "${wg_peer}.endpoint_host")

    # Fetch details for the current server using the robust --data-urlencode method.
    local server_details
    server_details=$(curl -s -G --data-urlencode "filters[hostname]=${current_host}" "${NORDVPN_API_BASE_URL}/servers")

    # The API returns an empty array '[]' for unknown or decommissioned servers.
    if [ "${server_details}" = "[]" ]; then
        echo "Warning: Current server ${current_host} not found in API. It might be decommissioned."
        # Set a high load to force an update to a new server.
        local current_load=101
    else
        local current_load
        current_load=$(echo "${server_details}" | jq -r '.[0].load')
    fi

    echo "Current server: ${current_host} | Current load: ${current_load}% | Max load: ${MAX_SERVER_LOAD}%"

    # Use '-gt' for numeric "greater than" comparison.
    if [ "${current_load}" -gt "${MAX_SERVER_LOAD}" ]; then
        echo "Server load is too high or server is offline. Finding a better server..."
        update_server
    else
        echo "Server load is acceptable. Nothing to do."
    fi
}

# --- Script Entrypoint ---
main
