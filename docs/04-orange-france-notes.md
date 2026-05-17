---
title: Orange France notes
nav_order: 4
---

# 04 — Orange France notes

Everything in this document is Orange France-specific. If you're on another ISP, the principles transfer (capture options from a working modem, replicate them on your router) but the specific values will not.

The notes here were validated against Orange France residential FTTH service in 2026 with a Livebox S (Sagemcom hardware, Arcadyan firmware lineage) as the source modem. Orange's BNG configuration is broadly consistent across France but provider-side equipment can differ between regions; capture from your own modem rather than copying values verbatim.

## VLAN map

| Service | VLAN ID | PCP | Notes |
|---------|--------:|----:|-------|
| Internet / data | 832 | 6 | DHCPv4 + DHCPv6, authenticated. Used for VOD and VoIP too. |
| Live TV | 840 | 4 | Multicast. Decoder-only. |
| Voice (SIP) | 832 | 6 | Same as data on Orange France, simpler than older ISPs. |

PCP=6 (802.1p "Network Control" class) egress marking is required on VLAN 832 or DHCP packets are silently dropped by the BNG. The README's "Critical insights" item 7 covers this.

Configure the egress QoS mapping on the OpenWrt VLAN device:

```
uci set network.sfp1_832.egress_qos_mapping='0:6 1:6 2:6 3:6 4:6 5:6 6:6 7:6'
```

Verify on the wire:

```
tcpdump -i sfp1 -nn -e vlan 832 -c 5
# Each frame should print: vlan 832, p 6, ...
```

## DHCPv4 options

Orange's BNG checks several DHCP options against an expected pattern for the ONT type it has provisioned on your line. Mismatches result in DHCP DISCOVER going out, no OFFER coming back.

### Option 60 — Vendor Class Identifier

Send the ASCII string `arcadyan`, even if your modem's MAC OUI is Sagemcom (`64:75:DA`). The Livebox S firmware identifies as `arcadyan` because of the Sagemcom-acquired-Arcadyan firmware lineage. The BNG checks this string, not the OUI.

Hex: `617263616479616e`

```
uci add_list network.wan.sendopts='60:617263616479616e'
```

If you send `sagemcom`, the BNG rejects the request. This is a common firmware-overrides-OEM pattern across multiple ISPs.

### Option 61 — Client Identifier

The Livebox sends `01` (htype = ethernet) followed by its WAN MAC address. So if the cloned MAC is `64:75:DA:XX:XX:XX`:

Hex: `016475daXXXXXX`

**Critical**: do **not** set this via `sendopts '61:...'`. OpenWrt's `netifd` silently generates a DUID-UUID and overrides the sendopts value. Use the dedicated UCI key:

```
uci set network.wan.clientid='016475daXXXXXX'
```

This is README "Critical insights" item 6.

### Option 77 — User Class

The Livebox sends a single class data instance, length-prefixed (RFC 3004):

```
0x32  (length, 50 decimal)
"FSVDSL_livebox.Internet.softathome.LiveboxNautilus"
```

In hex:

```
3246535644534c5f6c697665626f782e496e7465726e65742e736f66746174686f6d652e4c697665626f784e617574696c7573
```

The leading `0x32` length prefix is **part of the option value, not the option length header**. Omitting it causes BNG rejection.

```
uci add_list network.wan.sendopts='77:3246535644534c5f6c697665626f782e496e7465726e65742e736f66746174686f6d652e4c697665626f784e617574696c7573'
```

The string `LiveboxNautilus` reflects the Livebox S model lineage. Older models send `LiveboxN` (no Nautilus) or model-specific names. Capture from your modem.

### Option 90 — Authentication (RFC 3118)

Orange uses Protocol 3, "delayed authentication". The Option 90 payload is a structure containing:

- 12 leading bytes of zeros (or modem identifying data; the Livebox sends zeros)
- A protocol marker (`0x1a` = realm + auth, `0x09` = length)
- Sagemcom enterprise number 1368 (hex `0x558`)
- Authentication marker bytes (`0x01 0x03 0x41` is the common prefix)
- Username (length-prefixed)
- A 16-character hex salt (server-influenced nonce)
- An MD5 hash computed over: `salt || 4 NUL bytes || 0x01 0x01 0x03 || password`

The salt should be regenerated periodically. Stale salts produce auth failures. The `scripts/orange-gen-auth.sh` script computes and applies a fresh value.

#### Credentials

- Username: `fti/<id>`, where `<id>` is alphanumeric. Provided by Orange.
- Password: 7 characters in our case, provided on paper documentation when the line was activated. Orange may also expose it in the Orange mobile app under contract details; for newer customers, this has been less reliable.
- **Important**: Orange has stopped providing the `fti/...` password to some new fibre customers (community-reported on Orange France forums). If you're a new customer and you don't have it, you may need to call Orange 3900 and ask, or attempt Phase 6 without Option 90 first (some lines authenticate without it, depending on BNG configuration). Capture and decode the Option 90 from your own Livebox if you have it.

#### Reverse engineering the Option 90

If you don't trust the format we use, capture a known-working Option 90 from a Livebox via:

- GO-BOX (Orange Livebox diagnostic tool), or
- Wireshark on a span/tap port between the Livebox WAN and the BNG.

Compare against `scripts/orange-gen-auth.sh`'s output. The Sagemcom enterprise number and the magic `0x01 0x03 0x41` prefix have been stable for years; the variable parts are username, salt, and hash.

## DHCPv6 options

Mirror the DHCPv4 options into DHCPv6 equivalents:

| DHCPv4 | DHCPv6 equivalent |
|--------|-------------------|
| Option 60 (Vendor Class) | Option 16 (Vendor Class), with Sagemcom enterprise number prefix |
| Option 61 (Client ID) | Option 1 (DUID); use DUID-LL (type 3) with the cloned MAC |
| Option 77 (User Class) | Option 15 (User Class) |
| Option 90 (Authentication) | Option 11 (Authentication) with the same payload |

The DUID format on Orange is DUID-LL (type 3) with hardware type 1 (ethernet) and the cloned MAC. In hex:

```
000300<MAC_NO_COLONS_LOWER>
```

```
uci set network.wan6.clientid='0003006475daXXXXXX'
```

If you use type 1 (DUID-LLT, with timestamp) the BNG may still authenticate but some Orange BNG firmware revisions have been observed to reject it. DUID-LL is the safer choice.

IPv6 prefix delegation: Orange allocates a `/56`. Request explicitly:

```
uci set network.wan6.reqprefix='56'
```

## IPv6 prefix sample

Example assigned prefix shape: `2a01:cb15:XXXX:XXXX::/56`. Yours will be different and Orange-assigned.

## DNS

Orange-provided DNS resolvers:

- IPv4: `80.10.246.134`, `81.253.149.5`
- IPv6: `2a01:cfc4:2180:4001::4`, `2a01:cfc4:2000:f::4`

These work, but in our setup we run AdGuard Home on the router, listening on `127.0.0.1:5353`, and have `dnsmasq` forward to it. LAN clients use the router as their DNS server. Orange's resolvers are used only as upstream fallbacks for AdGuard.

If you do this, ensure `peerdns 0` on the WAN interface so the Orange DNS doesn't get pushed into `/etc/resolv.conf` and override AdGuard.

## IPTV (VLAN 840)

The Orange TV decoder talks IGMP and MLD over VLAN 840 to subscribe to multicast streams. The BPI-R3 needs to:

1. Have a VLAN 840 device on `sfp1` with DHCP (the decoder needs an IP delivered from the IPTV side, not the data side).
2. Run `igmpproxy` to forward multicast from VLAN 840 (upstream) to the LAN bridge (downstream).
3. Have firewall rules allowing IGMP and the multicast address range (224.0.0.0/4) from the WAN zone.

Egress PCP on VLAN 840 is **4** (Video class), not 6:

```
uci set network.sfp1_840.egress_qos_mapping='0:4 1:4 2:4 3:4 4:4 5:4 6:4 7:4'
```

The decoder gets its config from Orange's auto-provisioning system via the data VLAN; it needs to reach Orange's STB management servers on the internet, in addition to receiving multicast on VLAN 840. So the decoder should be on the data-LAN and the multicast should be routed to it by the OpenWrt `igmpproxy`.

Static lease the decoder on the LAN side so the port-forwards in Phase 9 have a stable destination:

```
uci add dhcp host
uci set dhcp.@host[-1].mac='<DECODER_MAC>'
uci set dhcp.@host[-1].ip='192.168.1.12'
uci set dhcp.@host[-1].name='tv-decoder'
```

Details in [`13-phase7-iptv.md`](13-phase7-iptv.md).

## VoIP

Orange France delivers SIP over the same VLAN 832 as data. The Livebox handles SIP internally and exposes only a POTS phone port (RJ-11) to the user.

The challenge for direct GPON termination is that **Orange does not expose SIP credentials to the customer**. They are provisioned by Orange's auto-provisioning system into the Livebox at activation, and the Livebox does not display them in its admin UI.

Options for replicating VoIP on the BPI-R3:

1. **Extract credentials from a `tcpdump` capture of the Livebox's SIP traffic.** Possible in theory; SIP REGISTER includes a digest authentication header. The digest is computed from credentials + a server nonce, so the credentials are not directly recoverable from a single REGISTER capture. Multiple captures over time + careful analysis may yield enough to brute-force; significant time investment.
2. **TR-069 spoofing.** Pretend to be a Livebox to Orange's auto-provisioning server and ask it to send you SIP credentials. Very advanced; possibly violates terms of service; not attempted in this project.
3. **Hybrid: keep the Livebox alive for phone only.** Put the Livebox behind the BPI-R3 on a dedicated LAN port. Configure it as a router-with-no-WAN-internet so it can still register SIP via a tunnel back through the BPI-R3, or accept that the phone port doesn't work post-migration.
4. **Skip VoIP entirely.** Use a mobile phone or VoIP-over-internet provider (OVH, etc.) for landline-style service.

This guide treats VoIP as a stretch goal and does not provide a working procedure. See [`14-phase8-voip.md`](14-phase8-voip.md) for the parked state.

## Advanced TV features (port forwards)

The Livebox port-forwards a small set of inbound ports to the TV decoder for features like remote PVR, TR-069 management, and VHD notifications. If you want these to keep working, replicate the rules on the BPI-R3 firewall. Details in [`15-phase9-port-forwards.md`](15-phase9-port-forwards.md). They're optional.

## Public IP and DDNS

Orange France delivers a (semi-)dynamic IPv4 to the BNG-facing interface and an IPv6 /56 prefix. The IPv4 has historically been very stable in our experience (months between changes), but it is not contractually static. If you run inbound services (WireGuard endpoint, etc.) use DDNS.

Sample DDNS verification flow is in [`12-phase6.5-ddns-verify.md`](12-phase6.5-ddns-verify.md).

## Known Orange-side quirks

- **The BNG sometimes takes 30-60 seconds** after PLOAM ranging completes to start responding to DHCP. Don't panic if the first attempt times out; wait two minutes and retry.
- **Stale lease tracking.** If you replaced the Livebox shortly before a fibre swap, the BNG may have a stale lease for the original modem's MAC. Cloning the MAC sidesteps this, but if you choose to use a different MAC, expect a transient DHCP failure until the previous lease expires (up to 24h).
- **Orange 3900 support is uneven.** Call centre staff have variable knowledge of GPON specifics. Asking "what's my Option 90 password?" works some of the time. Asking about ONT identity values gets you transferred to engineering, often with a long wait. Capture what you can from the Livebox before you call.
