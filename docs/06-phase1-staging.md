# 06 — Phase 1: Router behind the ISP modem

## Goal

Put the OpenWrt router downstream of the ISP modem. The router becomes the gateway for all wired and wireless clients. Internet still flows ISP modem → router → clients (double-NAT, temporarily) but every other service migrates to the router: DHCP, DNS, WiFi, firewall, port forwards.

This establishes a stable baseline. Phase 6 then swaps **only** the WAN side without affecting LAN clients.

## Success criteria

- All previously connected wired and wireless clients reach the internet via the router
- The router's WAN interface has a private IP from the ISP modem's LAN (e.g. `192.168.10.x`)
- Router LAN remains on its own subnet (e.g. `192.168.1.0/24`) without colliding with the ISP modem's LAN
- Remote-access services (VPN, DDNS) work via the modem's port forwarding pointing at the router

## Pre-requisites

- Phase 0 complete (backups taken, credentials available)
- OpenWrt installed on the router
- Admin access to the ISP modem
- The ISP modem and router default to the same subnet (`192.168.1.0/24`); we resolve this first

## Steps

### 1. Change the ISP modem's LAN subnet

Both devices default to `192.168.1.0/24`. The simplest fix is to move the ISP modem to a different range while leaving the router on the standard `192.168.1.0/24` so existing static configs and bookmarks continue to work.

On the ISP modem (Orange Livebox admin UI, "DHCP" or "LAN" section):

- Change LAN IP from `192.168.1.1` to e.g. `192.168.10.1`
- Change DHCP range to `192.168.10.10 - 192.168.10.150`
- Save and let the modem reboot (60-120 s)
- Reconnect to the modem's WiFi (clients will get new DHCP)

Pick a subnet that doesn't clash with anything else in your environment. If `192.168.10.x` is in use (e.g. a relative's home network you VPN to), use `192.168.2.x` or `192.168.3.x` instead. Just avoid `192.168.1.x`.

### 2. Configure the router's WAN as a DHCP client

The router's WAN port will plug into one of the ISP modem's LAN ports. The WAN interface speaks plain DHCP to the modem (no VLAN tag, no Option 90, none of the Phase 5 complexity).

```
ssh root@<router-ip>

# Clean off any previous-ISP-specific WAN config (PPPoE, VLAN tags, etc.)
uci set network.wan.proto='dhcp'
uci set network.wan.device='wan'
uci -q delete network.wan.username
uci -q delete network.wan.password
uci -q delete network.wan.ipv6
uci -q delete network.wan6

uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device='wan'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'

uci commit network
```

This puts the router back to vanilla DHCP on the bare `wan` netdev. Even though we'll later replace this with a tagged interface on `sfp1`, having a clean baseline is useful.

### 3. Physically connect the router WAN to the ISP modem LAN

Ethernet cable from the router's WAN port to any LAN port on the ISP modem. Power on both if not already on.

### 4. Restart networking on the router

```
/etc/init.d/network restart
```

### 5. Verify the router got an IP

```
ip addr show wan
ifstatus wan
```

You should see an IPv4 address in the ISP modem's LAN range (`192.168.10.x` in this example) and a default route pointing at the modem.

### 6. Test internet from a router client

From a device on the router's LAN (wired or via the router's WiFi):

```
ping -c 3 9.9.9.9
ping -c 3 openwrt.org
```

### 7. Confirm DDNS still resolves to the right address

If you run DDNS for inbound services, it should now reflect the ISP modem's public IP. Check after a few minutes for propagation:

```
nslookup vpn.example.org <your-dns-server>
```

The IP should match the ISP's public IP, not the modem's LAN IP. If not, see the DDNS provider's logs to confirm the update went through, and verify your DDNS update script is running on the router (`logread | grep ddns`).

### 8. (If you use inbound remote access) port-forward through the modem

In double-NAT mode, the ISP modem terminates the public IP. Any inbound port (e.g. WireGuard 51820/UDP) needs forwarding **through the modem to the router**, then **through the router to the final destination** (which is usually the router itself).

On the ISP modem admin UI (Orange Livebox: NAT/PAT section):

- Forward UDP 51820 (or whatever your VPN port is) to the router's WAN-side IP (`192.168.10.x` from step 5)
- Save

The router's existing firewall rule (already accepting VPN on `wan`) needs no change.

### 9. Test VPN from outside

Phone tethered to mobile data, VPN client → DDNS hostname → connect. If you reach the router LAN, double-NAT remote access is working.

## Risks

- **WAN config wrong → no internet.** The router needs to get a DHCP lease from the modem. If the device line is wrong (`uci set network.wan.device='wan'` referring to the bare WAN netdev, not the modem's LAN netdev) or if there's a VLAN tag mismatch, this fails silently.
- **LuCI / SSH lockout if LAN IP gets changed accidentally.** The script above doesn't touch LAN; double-check before running and don't paste extra UCI commands by mistake.
- **Forgotten device locked out.** Anything still configured to point at the modem's old `192.168.1.1` will lose its way. Update or factory-reset stragglers.
- **Double-NAT complications.** WireGuard works fine through double-NAT (UDP, well-behaved). Some inbound protocols (FTP active mode, SIP, IPSec NAT-T) misbehave. Plan around this; in particular, expect VoIP not to work through the modem during Phase 1.

## Rollback

If the router is misconfigured:

- Restore `/etc/config/network` from the Phase 0 backup via LuCI Backup/Restore (use direct ethernet to a LAN port on the router).
- Worst case: connect a client directly to the ISP modem and reconfigure the router via SSH from there.

If the modem's LAN IP change broke things:

- Most modems retain admin access on a fallback IP (often the new IP you set, or via a reset hole). If not, factory reset the modem and reconfigure. Painful but recoverable.

## Notes

This phase doesn't migrate WiFi clients yet. Both the modem and the router will be broadcasting WiFi for a while. Move clients across at your own pace in Phase 2 (and disable the modem's WiFi in Phase 3). For now, both networks coexisting is fine; just confirm anything important is reachable through the router rather than via the modem.

The IPTV decoder typically stays on the ISP modem's WiFi during Phase 1, so live TV continues to work via the modem-as-IPTV-router. We move the decoder later (Phase 2 or after Phase 7, depending on order).
