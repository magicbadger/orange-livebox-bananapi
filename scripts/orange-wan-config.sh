#!/bin/sh
# Stage OpenWrt UCI for direct GPON WAN via SFP1.
# Run while still terminating fibre on the original ISP modem. Does NOT restart the network.
#
# Source of truth: this file is mirrored in README.md and docs/10-phase5-wan-staging.md.
# If you change one, update the others.
#
# Replace placeholders before running:
#   LIVEBOX_MAC     - WAN MAC of original modem (cloned)
#   HOSTNAME        - hostname the modem reports (often "livebox")
#   WAN_VLAN        - VLAN tag for data (Orange: 832)
#   VENDOR_CLASS    - Option 60 string (Orange: arcadyan)
#   USER_CLASS_HEX  - Option 77 with length prefix
#   AUTH_INITIAL    - Option 90 placeholder, refreshed by orange-gen-auth.sh

set -e

LIVEBOX_MAC="64:75:DA:XX:XX:XX"
HOSTNAME="livebox"
WAN_VLAN="832"
VENDOR_CLASS_HEX="617263616479616e"   # ASCII "arcadyan"
USER_CLASS_HEX="3246535644534c5f6c697665626f782e496e7465726e65742e736f66746174686f6d652e4c697665626f784e617574696c7573"
AUTH_INITIAL="00000000000000000000001a09000005580103410100000000000000000000000000000000000000000000000000000000000000000000000000000000"
CLIENTID_HEX="01$(echo $LIVEBOX_MAC | tr -d ':' | tr A-F a-f)"

BACKUP="/etc/config/network.bak.$(date +%Y%m%d_%H%M%S)"
cp /etc/config/network "$BACKUP"
echo "Backed up current network config to $BACKUP"

# Remove any prior wan/wan6 device entries and the SFP1 VLAN device
for s in wan wan6 iptv sfp1_${WAN_VLAN}; do
    uci -q delete network.$s 2>/dev/null || true
done

# Define the tagged VLAN device on sfp1
uci set network.sfp1_${WAN_VLAN}=device
uci set network.sfp1_${WAN_VLAN}.name="sfp1.${WAN_VLAN}"
uci set network.sfp1_${WAN_VLAN}.type='8021q'
uci set network.sfp1_${WAN_VLAN}.ifname='sfp1'
uci set network.sfp1_${WAN_VLAN}.vid="${WAN_VLAN}"
uci set network.sfp1_${WAN_VLAN}.egress_qos_mapping='0:6 1:6 2:6 3:6 4:6 5:6 6:6 7:6'

# WAN (IPv4 DHCP)
uci set network.wan=interface
uci set network.wan.proto='dhcp'
uci set network.wan.device="sfp1.${WAN_VLAN}"
uci set network.wan.hostname="${HOSTNAME}"
uci set network.wan.broadcast='1'
uci set network.wan.macaddr="${LIVEBOX_MAC}"
uci set network.wan.reqopts='1 3 6 15 28 51 58 59 90 119 120 125'
uci set network.wan.clientid="${CLIENTID_HEX}"
uci add_list network.wan.sendopts="60:${VENDOR_CLASS_HEX}"
uci add_list network.wan.sendopts="77:${USER_CLASS_HEX}"
uci add_list network.wan.sendopts="90:${AUTH_INITIAL}"

# WAN6 (IPv6 DHCPv6)
uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device="sfp1.${WAN_VLAN}"
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='56'
uci set network.wan6.clientid="000300${CLIENTID_HEX:2}"
uci set network.wan6.noclientfqdn='1'
uci set network.wan6.noacceptreconfig='1'
# Equivalent DHCPv6 sendopts (user-class option 15, vendor-class 16, vendor-opts 17, auth 11)
uci add_list network.wan6.sendopts="15:00${USER_CLASS_HEX}"
uci add_list network.wan6.sendopts="16:0000040e0008${VENDOR_CLASS_HEX}"
uci add_list network.wan6.sendopts="17:000005580006000e495056365f524551554553544544"
uci add_list network.wan6.sendopts="11:${AUTH_INITIAL}"

uci commit network

echo "Config staged. Network NOT restarted."
echo "Next: run orange-gen-auth.sh to refresh Option 90, then physical fibre swap, then /etc/init.d/network restart"
echo "Rollback: cp $BACKUP /etc/config/network && /etc/init.d/network restart"
