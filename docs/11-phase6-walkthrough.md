---
title: "Phase 6: Direct GPON termination"
nav_order: 12
---

# 11 — Phase 6: The fibre swap (direct GPON termination)

## Goal

Move the fibre from the ISP modem to the rooted ONT stick in the OpenWrt router's SFP1 cage. Bring up the new WAN configuration staged in Phase 5. End state: the router is the direct GPON termination device, the ISP modem is unplugged from the fibre, internet flows fibre → MA5671A → BPI-R3.

This is the headline phase. It carries a small but real risk of multi-hour outage, so prepare carefully, memorise the rollback, and pick a time when the household can tolerate a 30-60 minute service interruption.

## Success criteria

- `ip addr show sfp1.832` shows a public IPv4 from the ISP's pool
- `ifstatus wan` shows `up: true` with a default route
- `onu ploamsg` on the MA5671A shows `curr_state=5` (PLOAM operational)
- `ping 9.9.9.9` and `ping openwrt.org` both succeed from the router
- LAN clients can reach the internet

## Pre-requisites

- Phases 0-5 complete
- Time window when family can tolerate 30-60 minutes of internet downtime
- Rollback procedure memorised (see below)
- Phone with mobile data hotspot, ready as fallback if you need to look up commands

## Rollback (memorise before starting)

Before you start, internalise this. You will be tense if Phase 6 doesn't work first try, and you do not want to be reading documentation while the family is offline.

1. **Power off the BPI-R3.**
2. **Pull the fibre from the MA5671A in SFP1.** Squeeze the SC/APC connector tabs, pull straight out. Dust cap on if you have one.
3. **Plug the fibre back into the ISP modem.** Push until it clicks.
4. **Power on the ISP modem.** Wait 90-120 s for it to authenticate and bring up service.
5. **Power on the BPI-R3.** SSH in.
6. **Restore the Phase 1 network config.** `cp /etc/config/network.bak.<timestamp> /etc/config/network && /etc/init.d/network restart`.

End state after rollback: family internet restored via ISP modem, BPI-R3 back behind it on `192.168.10.x` (or whatever Phase 1 subnet you chose).

Time to complete: 2-3 minutes once you start. Practise the physical motion (especially the fibre connector swap) once before doing it for real.

## Steps

### 1. Refresh Option 90

The Option 90 salt may have aged since Phase 5. Regenerate immediately before the swap:

```
ssh root@<router-ip>
/root/orange-gen-auth.sh
```

Confirm the new Option 90 is written into UCI:

```
uci -q get network.wan.sendopts | tr ' ' '\n' | grep '^90:'
```

Note: do **not** run `/etc/init.d/network restart` yet. The router is still on the Phase 1 config; restarting now would lose internet while you're trying to do the fibre swap.

### 2. Final sanity check: ISP modem is reachable

You're about to disconnect it. Confirm one last time it's working:

```
ping -c 3 9.9.9.9
ping -c 3 openwrt.org
```

### 3. Power off everything

Order:

1. BPI-R3 (the router)
2. ISP modem
3. TV decoder (if powered)

Wait 5-10 seconds for capacitors to discharge.

### 4. Move the rooted ONT to SFP1

If the ONT was in SFP2 for staging:

1. Press the SFP latch to release.
2. Pull the SFP module straight out by the bail (the metal handle on the front). Don't yank.
3. Insert into SFP1. Push until you feel the latch click. Lock the bail down.

Confirm the cage is fully seated by tugging gently on the bail; it should not move.

### 5. Move the fibre to the rooted ONT

1. Disconnect the fibre from the ISP modem. Squeeze SC/APC tabs, pull straight out. Apply a dust cap to the unused ISP modem fibre receptacle.
2. (Optional) Visually inspect the fibre tip — wipe with a lint-free wipe if it looks dusty. Avoid touching the polished end with skin.
3. Plug the fibre into the rooted ONT. Push until it clicks.

### 6. Power on the BPI-R3 (only)

Leave the ISP modem **off**. You want only one device claiming the GPON serial on the OLT side.

```
power button on BPI-R3
```

Wait 90 s for OpenWrt to fully boot.

### 7. Verify the SFP is detected

SSH in:

```
ssh root@<router-ip>
ip link show sfp1
ip link show sfp1.832
ethtool -m sfp1                       # SFP MSA fields, light level
```

You should see `sfp1` and `sfp1.832` both `<UP,LOWER_UP>`. The `ethtool -m` output should show the vendor string of the rooted ONT and a non-zero receive optical power (typically -10 to -25 dBm; verify against your fibre operator's expected range).

**Warning**: `<UP,LOWER_UP>` does NOT mean GPON authenticated. It only means the SFP module is electrically present and the SerDes link is up. The next steps verify the actual GPON state.

### 8. Check PLOAM state on the rooted ONT

The MA5671A management interface is still at `192.168.1.10` on the SFP module. With the stick in SFP1 and the OpenWrt router as the WAN side, the management interface is reachable from the LAN if you've configured a route, or you can SSH from the router itself.

```
ssh root@<router-ip>
ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 \
    -oHostKeyAlgorithms=+ssh-dss \
    root@192.168.1.10
```

(No password on the web-flashed variant; `admin123` on some others. See [`03-ma5671a-specifics.md`](03-ma5671a-specifics.md).)

Then on the stick:

```
onu ploamsg
```

The interesting field is `curr_state`. Expected progression over the first 60-90 s after power-on:

- `curr_state=1` (O1, initial) — no downstream signal
- `curr_state=2` (O2, standby) — signal seen, waiting for serial number assignment
- `curr_state=3` (O3, serial number ranging) — OLT requested ranging, stick is identifying itself
- `curr_state=4` (O4, ranging in progress) — distance ranging
- `curr_state=5` (O5, operation) — fully authenticated, OMCI session active

You want `curr_state=5`. If it sits at 1-4 for more than 2 minutes, GPON authentication is failing. Diagnose:

- **Stuck at 1**: no downstream signal. Fibre is not seated, the OLT has no PON enabled for this stick, or the rooted ONT is dead. Inspect `ethtool -m sfp1` Rx power.
- **Stuck at 2-3**: downstream seen but OLT not accepting the serial number. **This is the gSerial check failing.** Re-verify `omci_pipe meg 256 0` shows the correct GPON SN. Re-check the value against what the original modem reported.
- **Stuck at 4**: ranging started but didn't complete. Rare. Often a fibre signal-level problem; check Rx power on the SFP MSA.

### 9. Bring up the WAN

Back on the router:

```
exit       # leave the MA5671A shell
ssh root@<router-ip>
```

If you're using cron-driven Option 90 refresh, run it once more for good measure:

```
/root/orange-gen-auth.sh
```

Then restart the network to bring up the staged config:

```
/etc/init.d/network restart
sleep 30
```

### 10. Confirm DHCP success

```
ifstatus wan
ip addr show sfp1.832
ip route
```

Expected:

- `ifstatus wan` shows `up: true`, `ipv4-address` populated with a public IP (Orange France: typically `86.x.x.x` or similar), `route` to `0.0.0.0/0` via the BNG-side gateway
- `ip addr show sfp1.832` shows the same IPv4 on the interface
- `ip route` shows a default route via `sfp1.832`

### 11. Test

```
ping -c 3 9.9.9.9
ping -c 3 openwrt.org
curl -s -4 https://ifconfig.io
```

LAN clients should also work — try a phone on the router WiFi.

### 12. Save a known-good config

```
cp /etc/config/network /etc/config/network.orange-direct.$(date +%Y%m%d)
```

This is your "Phase 6 worked" baseline. Keep it; you'll want it as a reference point if Phase 7 or later breaks something.

## What if DHCP doesn't succeed

If `ifstatus wan` shows `up: false` or `ipv4-address` empty after 60 s:

### 12a. Confirm GPON is up

Re-check `onu ploamsg` on the MA5671A: it must show `curr_state=5`. If not, fix GPON first (step 8 troubleshooting).

### 12b. Capture DHCP traffic

```
tcpdump -i sfp1 -nn -e -c 30 vlan 832
```

This shows the raw upstream and downstream traffic on the data VLAN.

- **No DHCP DISCOVER going out**: udhcpc isn't running, or the VLAN device isn't up. Check `ifstatus wan` and `logread | grep -i udhcpc`.
- **DHCP DISCOVER going out but no OFFER coming back**: the BNG sees us but rejects. Causes:
  - **Option 60 wrong** (`sagemcom` instead of `arcadyan`, see [`04-orange-france-notes.md`](04-orange-france-notes.md))
  - **Option 61 wrong** — netifd overriding sendopts; double-check that `option clientid` is set on the interface, not just `sendopts '61:...'`
  - **Option 77 missing length prefix** — first byte must be the length (`0x32`)
  - **Option 90 stale or wrong** — re-run `orange-gen-auth.sh`
  - **PCP marking missing** — confirm `egress_qos_mapping` on `sfp1.832` and verify frames carry `p 6` with `tcpdump -e`
  - **MAC clone wrong** — verify `network.wan.macaddr` matches the original modem
- **DHCP OFFER coming back but `ifstatus wan` still `down`**: udhcpc rejecting the offer. Look at `logread | grep -i udhcpc` for the rejection reason.

### 12c. Capture for offline analysis

```
tcpdump -i sfp1 -w /tmp/dhcp-debug.pcap vlan 832 and port 67 or port 68
# in another shell:
/etc/init.d/network restart
# wait 30 s
# ctrl-C the tcpdump
```

scp the pcap to your workstation and open in Wireshark. Compare DHCP DISCOVER content option-by-option against a known-good Livebox capture (if you took one in Phase 0 with GO-BOX or tcpdump on a SPAN).

### 12d. If DHCPv4 works but DHCPv6 doesn't

You'll have IPv4 internet but no IPv6 prefix delegation. `ifstatus wan6` shows `up: true` but `ipv6-prefix` is empty. Likely causes:

- DUID format mismatch (you sent DUID-LL type 3, ISP may expect type 1)
- Vendor-class option 16 enterprise number wrong
- IA_PD hint missing

Dig deeper with `odhcp6c -v` debug mode and the OpenWrt `odhcp6c` man page.

### 12e. Decide: iterate or roll back

If you have an obvious fix (e.g. a typo in Option 77), make it and retry. Each retry is `/root/orange-gen-auth.sh && /etc/init.d/network restart && sleep 30 && ifstatus wan`.

If you don't have an obvious fix and the family is unhappy, **roll back to the ISP modem** (the procedure in the "Rollback" section above). Internet returns in 2-3 minutes; you can investigate at leisure with the rooted ONT back in SFP2.

## Risks

- **GPON authentication failure** — ME 256 Serial Number wrong; physically swap fibre back to the ISP modem.
- **DHCP Option mismatch** — diagnose with tcpdump; common culprits in step 12b.
- **Wrong VLAN tag** — DHCP DISCOVER never reaches BNG; verify `network.sfp1_832.vid='832'`.
- **DDNS lagging** — your inbound services (VPN) will be unreachable until DDNS catches up; expected behaviour, see [`12-phase6.5-ddns-verify.md`](12-phase6.5-ddns-verify.md).
- **IPTV broken** — expected until Phase 7 sets up the IGMP proxy. If the household watches live TV, prepare for it being unavailable.
- **Optical signal levels** — fibre handling can degrade signal slightly. If Rx power has dropped significantly (more than 3 dB) from what the ISP modem saw, you may have introduced a connector issue. Reseat and re-inspect.

## Confirmation: Phase 6 has been validated on this stack

For this project, Phase 6 succeeded with the OMCI configuration described in [`09-phase4-ma5671a-omci-clone.md`](09-phase4-ma5671a-omci-clone.md) and the WAN staging from [`10-phase5-wan-staging.md`](10-phase5-wan-staging.md). Specifically:

- gSerial (ME 256 Serial Number) correctly cloned to the captured value (e.g. `ARLT12345678`)
- ME 256 Version visibly mangled (`ARLTLBN1000000` instead of `ARLTLBN100` + 4 NULs)
- ME 257 Equipment ID visibly wrong (overwritten with `nSerial` value)

The OLT authenticated and issued a DHCP lease. This is the basis for the "Critical insights" claim in the README that gSerial is the only OMCI field Orange France actually enforces.

If your line behaves differently, the troubleshooting steps above will identify which option/identity is failing.

## Notes

The two minutes between "fibre off the Livebox" and "ping 9.9.9.9 works" are nerve-wracking but generally uneventful. The OMCI ranging and DHCP handshake happens automatically. If it works at all, it works in under 90 s.

If you have iterations to do, **don't run them on the live fibre back-to-back without thinking**. Each `/etc/init.d/network restart` is ~30 s of definite downtime. Cluster fixes (don't change only Option 77 then retry, then change only Option 90 then retry — change everything you've found wrong, retry once).

Phase 7 (IPTV multicast) comes next. SQM, DDNS, and other polish go in Phase 10. The hard part is over.
