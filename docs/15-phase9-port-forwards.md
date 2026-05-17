---
title: "Phase 9: Port forwards"
nav_order: 16
---

# 15 — Phase 9: Replicate advanced TV / management port forwards

> **Status: work in progress.** Optional. These rules are needed only if you want specific Orange TV decoder features (remote PVR, in-app remote control) and Orange remote management (TR-069) to keep working. The reference build hasn't yet validated each rule end-to-end against the live Orange services; we know what to forward, less so whether each Orange service still exercises the path.

## Goal

Replicate the inbound port forwards the ISP modem used to do, on the OpenWrt router's firewall, so advanced features keep working:

- **STB Remote PVR**: lets the Orange TV app on a phone outside the network reach the decoder to manage recordings
- **STB TR-069**: Orange's CPE-management protocol talking to the decoder
- **VHD notifications**: Voice High Definition notification service (incoming-call notifications to the decoder)

If you don't use these features, skip this phase. The household keeps working without it.

## Success criteria

- The rules are present in `/etc/config/firewall` and active
- Connections from outside reach the TV decoder on the intended ports
- Where feasible, the corresponding Orange service is verified working end-to-end (remote PVR via the Orange TV app on mobile data, for instance)

## Pre-requisites

- Phase 6 complete (router has public IPv4)
- Phase 7 complete or TV decoder otherwise on the LAN with the static lease `192.168.1.12`
- The set of rules captured from the ISP modem in Phase 0

## Rules captured from the reference Livebox S

| Service | Source restriction | External port | Internal IP | Internal port | Protocol |
|---------|--------------------|--------------:|-------------|--------------:|----------|
| STB Remote PVR (rule 1) | (any) | 11187 | 192.168.1.12 | 8443 | TCP |
| STB Remote PVR (rule 2) | source IP 81.253.218.26 | 35437 | 192.168.1.12 | 8443 | TCP |
| STB TR-069 | (any) | 50995 | 192.168.1.12 | 50995 | TCP |
| VHD Notific | (any) | 60432 | 192.168.1.12 | 8444 | TCP |

These specific external ports and source IP (`81.253.218.26`) reflect what the Livebox was using in 2026. Orange's service-side IP allocations and port assignments may change. If you capture different rules from your own Livebox in Phase 0, use those.

## Steps

### 1. Add the port-forward rules

```
ssh root@<router-ip>

# STB Remote PVR rule 1
uci add firewall redirect
uci set firewall.@redirect[-1].name='STB-Remote-PVR-1'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_dport='11187'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].dest_ip='192.168.1.12'
uci set firewall.@redirect[-1].dest_port='8443'
uci set firewall.@redirect[-1].proto='tcp'

# STB Remote PVR rule 2 (source-restricted)
uci add firewall redirect
uci set firewall.@redirect[-1].name='STB-Remote-PVR-2'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_ip='81.253.218.26'
uci set firewall.@redirect[-1].src_dport='35437'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].dest_ip='192.168.1.12'
uci set firewall.@redirect[-1].dest_port='8443'
uci set firewall.@redirect[-1].proto='tcp'

# STB TR-069
uci add firewall redirect
uci set firewall.@redirect[-1].name='STB-TR069'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_dport='50995'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].dest_ip='192.168.1.12'
uci set firewall.@redirect[-1].dest_port='50995'
uci set firewall.@redirect[-1].proto='tcp'

# VHD notifications
uci add firewall redirect
uci set firewall.@redirect[-1].name='VHD-Notific'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_dport='60432'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].dest_ip='192.168.1.12'
uci set firewall.@redirect[-1].dest_port='8444'
uci set firewall.@redirect[-1].proto='tcp'

uci commit firewall
/etc/init.d/firewall restart
```

### 2. Verify the rules are loaded

```
uci show firewall | grep -i 'STB\|VHD'
```

Each rule should be present with the values from the table.

```
fw3 print | head -80
```

This shows the active nftables / iptables rules that fw3 has generated. Look for `iptables -t nat -A zone_wan_prerouting` entries (or `nftables` equivalents) matching the destination ports.

### 3. Test reachability

For the rules with no source restriction, you can test from an external host:

```
# from outside the LAN, with the DDNS hostname:
nc -zv <ddns.hostname> 11187     # STB Remote PVR
nc -zv <ddns.hostname> 50995     # TR-069
nc -zv <ddns.hostname> 60432     # VHD
```

`Connected` means the TCP handshake reaches the decoder; it doesn't necessarily mean the service is responding correctly, but it does mean the forward is working.

For rule 2 (source-restricted to `81.253.218.26`): you cannot test from a generic external host, since the source IP filter will drop it. This rule only fires when Orange's specific server connects. If you want to verify, tcpdump on `wan` or on `br-lan` and wait for a connection from `81.253.218.26`:

```
tcpdump -i any -nn host 81.253.218.26 -c 5
```

### 4. Test the actual Orange features

- **STB Remote PVR**: open the Orange TV app on a phone with mobile data (not on home WiFi). Confirm you can browse recordings and schedule new ones. If this was working through the Livebox before, it should work through the router now.
- **TR-069**: less directly testable from the user side. Orange uses it for remote configuration and diagnostics. If you don't see Orange-side notifications about the decoder being out of contact, it's working.
- **VHD notifications**: when an incoming call comes in (if you have a phone line and SIP-via-Livebox is still working as Phase 8 Option 3), the decoder should pop up a caller ID notification. Tests one-off.

## Risks

- **Rules pointing at wrong IP** — if the decoder is at a different IP than `192.168.1.12`, traffic goes nowhere. Confirm the static lease.
- **Decoder firewall blocking ports** — most Orange decoders accept inbound on their service ports unconditionally on the LAN side. If something has changed, you may need to debug at the decoder level (rarely possible).
- **Source IP for rule 2 changed** — Orange may allocate the remote PVR service to a different IP. If rule 2 stops working, capture the source IP from a live connection (tcpdump above) and update.
- **Privacy of TR-069** — Orange remote management means Orange can read your decoder config, push updates, and gather diagnostics. If you'd rather block this for privacy reasons, simply omit the TR-069 rule. Decoder still works, you just won't get firmware updates pushed by Orange (the decoder may eventually start nagging about being out of date).

## Rollback

Remove individual redirects:

```
uci show firewall | grep '@redirect' | grep -E 'STB|VHD'
# note the indices, e.g. firewall.@redirect[7]

uci delete firewall.@redirect[X]      # for each
uci commit firewall
/etc/init.d/firewall restart
```

Or restore the entire firewall config from before:

```
cp /etc/config/firewall.bak.<timestamp> /etc/config/firewall
/etc/init.d/firewall restart
```

(Take such a backup first; the staging script for Phase 5 only backs up `network`, not `firewall`.)

## Notes

This phase is genuinely optional. The reference household decided in advance that:

- Remote PVR is occasionally useful but not critical
- TR-069 is more a Orange-side benefit than a household benefit
- VHD notifications are nice-to-have

If none of those resonate, skip Phase 9 entirely.

If you want the privacy-blocking option (decoder can't be remotely managed), just don't add the TR-069 rule. The decoder will still work for live TV; Orange will be slightly more annoyed.
