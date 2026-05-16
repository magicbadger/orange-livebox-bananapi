#!/bin/sh
# Generate fresh DHCP Option 90 (RFC 3118) for Orange France authenticated DHCP.
# Reads credentials from /etc/orange-auth (format: USERNAME:PASSWORD, chmod 600).
# Updates UCI for both network.wan (Option 90) and network.wan6 (Option 11).
#
# Source of truth: this file is mirrored in README.md and docs/10-phase5-wan-staging.md.
#
# Pure POSIX shell; works on busybox ash. No external tools required beyond md5sum.

set -e

AUTH_FILE="/etc/orange-auth"
if [ ! -r "$AUTH_FILE" ]; then
    echo "ERROR: $AUTH_FILE not found or unreadable" >&2
    echo "Create it with: echo 'fti/abc1234:yourpassword' > $AUTH_FILE && chmod 600 $AUTH_FILE" >&2
    exit 1
fi

CREDS=$(cat "$AUTH_FILE")
USER="${CREDS%:*}"
PASS="${CREDS#*:}"
USER_LEN=$(printf '%s' "$USER" | wc -c)

# Generate a fresh 16-char random salt (8 bytes hex)
SALT=$(head -c 8 /dev/urandom | hexdump -e '"%02x"')

# Compute the MD5 hash over: salt + 4 NUL bytes + 0x01 + 0x01 + 0x03 + password
HASH=$(
    {
        printf '%s' "$SALT"
        printf '\x00\x00\x00\x00\x01\x01\x03'
        printf '%s' "$PASS"
    } | md5sum | cut -d' ' -f1
)

# Convert ASCII USER to hex
USER_HEX=$(printf '%s' "$USER" | hexdump -e '"%02x"')

# Build the full Option 90 payload
USER_LEN_HEX=$(printf '%02x' "$USER_LEN")
SALT_LEN_HEX="3c"
PAYLOAD="00000000000000000000001a0900000558010341${USER_LEN_HEX}${USER_HEX}${SALT_LEN_HEX}12${SALT}0313${HASH}"

echo "Generated Option 90 ($(printf '%s' "$PAYLOAD" | wc -c) hex chars):"
echo "$PAYLOAD"

NEW_SENDOPT_WAN="90:${PAYLOAD}"
NEW_SENDOPT_WAN6="11:${PAYLOAD}"

OLD_WAN=$(uci -q get network.wan.sendopts | tr ' ' '\n' | grep -v '^90:' | tr '\n' ' ')
uci -q delete network.wan.sendopts
for opt in $OLD_WAN; do uci add_list network.wan.sendopts="$opt"; done
uci add_list network.wan.sendopts="$NEW_SENDOPT_WAN"

OLD_WAN6=$(uci -q get network.wan6.sendopts | tr ' ' '\n' | grep -v '^11:' | tr '\n' ' ')
uci -q delete network.wan6.sendopts
for opt in $OLD_WAN6; do uci add_list network.wan6.sendopts="$opt"; done
uci add_list network.wan6.sendopts="$NEW_SENDOPT_WAN6"

uci commit network

echo "UCI updated. To apply:"
echo "  /etc/init.d/network restart"
