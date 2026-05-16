# 19 — Troubleshooting and verification

A catalogue of common failure modes for a direct-GPON setup on OpenWrt, with the diagnostic that distinguishes each. Organised by symptom; cross-references the phase that introduced the relevant configuration.

## Diagnostic vocabulary

Before troubleshooting, know what each piece of evidence actually proves:

| Evidence | Means | Does NOT mean |
|----------|-------|---------------|
| `ip link show sfp1` reports `<UP,LOWER_UP>` | SFP is electrically present, host SerDes link up | GPON authenticated |
| `ethtool -m sfp1` reports valid optical Rx power | Fibre signal is present | GPON authenticated |
| `onu ploamsg` reports `curr_state=5` | GPON link is operational at the PLOAM layer; OMCI session active | Internet works |
| `ifstatus wan` reports `up: true` with public IP | DHCPv4 succeeded | Application traffic works |
| `ping 9.9.9.9` succeeds | IPv4 routing and basic connectivity work | DNS works, IPv6 works, throughput is acceptable |
| `ping openwrt.org` succeeds | DNS works too | Application traffic works at scale |

Internalise the distinctions. Most stalled-Phase-6 sessions involve mistaking SFP link up for GPON authenticated.

## Failure: SFP not detected

### Symptom

```
ip link show sfp1
# device not found, or device reports DOWN
```

### Likely causes

- SFP module not fully seated. Reseat firmly until the latch clicks.
- SFP cage hardware issue. Try the other cage (move to `sfp2`, see if it shows up).
- Wrong netdev name. Recent OpenWrt builds for the BPI-R3 use `sfp1` and `sfp2`; older builds may use different names. Check `ls /sys/class/net/`.
- SFP module not supported by the host. Some routers blacklist non-MSA-compliant SFP modules; check `dmesg | grep -i sfp` for rejection messages.

### Fix

Reseat the SFP. If still not detected, swap cages. If still not, the SFP itself may be dead — test on another router if you have one.

## Failure: SFP detected but no GPON light

### Symptom

```
ip link show sfp1
# UP, LOWER_UP
ethtool -m sfp1 | grep -i 'optical power'
# Receive power: < -30 dBm (effectively no signal)
```

### Likely causes

- Fibre not seated in the SFP. Reseat the SC/APC connector; push until you feel the click.
- Fibre connector dirty. Clean with a lint-free wipe or a fibre-cleaning pen.
- Fibre damaged between OLT and your premises. The fibre operator (Orange or its sub-contractor) needs to investigate.
- The OLT side has the PON disabled for your subscriber. Rare unless your service was suspended; call ISP support.

### Fix

Mechanical fixes first (reseat, clean). If Rx power stays too low, the issue is upstream of the SFP and needs ISP attention.

## Failure: GPON light but PLOAM stuck at O1/O2/O3

### Symptom

```
onu ploamsg
# curr_state = 1, 2, or 3 (not progressing to 5)
```

### `curr_state=1` (O1)

No downstream signal. See "Failure: SFP detected but no GPON light" above.

### `curr_state=2` (O2)

Downstream signal seen, OLT not yet broadcasting a serial-number-assignment request to this stick. Either:

- The OLT does not have your ONT provisioned. Call ISP support; verify the line is active and the ONT serial expected by their system matches what you cloned.
- The OLT is broadcasting requests but rejecting this stick's response. Check ME 256 Serial Number is correct:
  ```
  /opt/lantiq/bin/omci_pipe meg 256 0 | head -10
  ```
  Attribute 3 Serial Number should be your cloned GPON SN, formatted as 4 ASCII bytes + 4 binary bytes.

### `curr_state=3` (O3)

Stick has identified itself in PLOAM ranging but OLT did not accept. Almost always wrong gSerial. Re-check, re-set, reboot.

### `curr_state=4` (O4)

Ranging in progress. Should advance to 5 within seconds. If stuck at 4 for more than a minute:

- Distance to OLT may be at the edge of GPON spec (max 20 km), causing ranging timeout
- Signal level marginal
- Fibre length differs from what's provisioned (rare, fibre-operator-side issue)

Mostly a signal-level issue; check Rx power and call ISP.

### Fix

For O2/O3 specifically: re-verify `gpon.onu.nSerial` and ME 256 Serial Number match what your ISP modem reported. The fix is in [`09-phase4-ma5671a-omci-clone.md`](09-phase4-ma5671a-omci-clone.md). For O4: signal level / ISP.

## Failure: PLOAM at O5 but no DHCP

### Symptom

```
onu ploamsg
# curr_state = 5  (good)

ifstatus wan
# up: false, or up: true with no ipv4-address

tcpdump -i sfp1.832 -nn port 67 or port 68 -c 20
# DHCP DISCOVER going out, no OFFER coming back
```

### Likely causes (in rough order of probability for Orange France)

1. **Option 90 stale, wrong, or missing**. Refresh:
   ```
   /root/orange-gen-auth.sh
   /etc/init.d/network restart
   ```
   If you don't have the `fti/` password, see [`04-orange-france-notes.md`](04-orange-france-notes.md) discussion.

2. **Option 60 wrong**. Should be ASCII `arcadyan` (hex `617263616479616e`), not `sagemcom`. Even if your modem is a Sagemcom-OEM Livebox, Option 60 says `arcadyan` — firmware lineage thing.
   ```
   uci -q get network.wan.sendopts | tr ' ' '\n' | grep '^60:'
   # should be: 60:617263616479616e
   ```

3. **Option 61 wrong, or `sendopts '61:...'` instead of `option clientid`**. netifd silently overrides `sendopts '61:...'` with a DUID. Use `option clientid` instead. README "Critical insights" item 6.
   ```
   uci -q get network.wan.clientid
   # should be: 01<your_cloned_mac_no_colons_lower>
   ```

4. **Option 77 missing length prefix**. The Option 77 value must start with the length byte (`0x32` for the Livebox Nautilus string), not just the ASCII payload. README "Critical insights" item 9.
   ```
   uci -q get network.wan.sendopts | tr ' ' '\n' | grep '^77:'
   # should start with 32 (e.g. 77:3246...)
   ```

5. **PCP=6 marking missing**. The BNG silently drops DHCP that arrives without 802.1p priority 6 on VLAN 832.
   ```
   uci -q get network.sfp1_832.egress_qos_mapping
   # should be: 0:6 1:6 2:6 3:6 4:6 5:6 6:6 7:6
   ```
   Verify on the wire:
   ```
   tcpdump -i sfp1 -nn -e vlan 832 -c 5
   # frames should print: vlan 832, p 6, ...
   ```

6. **MAC clone wrong**. The router's WAN-side MAC must match the original modem.
   ```
   uci -q get network.wan.macaddr
   ip link show sfp1.832
   ```

7. **Hostname wrong**. The Livebox sends a hostname (`livebox` typically). Some BNG configurations check it.

8. **VLAN tag wrong**. VLAN 832 for Orange France; a different VLAN won't reach the BNG at all.
   ```
   uci -q get network.sfp1_832.vid
   # should be: 832
   ```

### Fix

Re-check each option above in sequence. Re-run `orange-gen-auth.sh` and `/etc/init.d/network restart` between fixes. Capture the DHCP DISCOVER with tcpdump and compare against a known-good Livebox capture if you have one (Phase 0 GO-BOX or tcpdump on a SPAN port).

If DHCP succeeds but only after multiple retries, that's often a stale Option 90 salt that the BNG eventually accepts after some delay. Re-running `orange-gen-auth.sh` immediately before each retry helps.

## Failure: DHCPv4 works, DHCPv6 doesn't

### Symptom

```
ifstatus wan
# up: true, ipv4-address populated, default route via BNG

ifstatus wan6
# up: true, but ipv6-address and ipv6-prefix empty
```

### Likely causes

- **DUID format mismatch**. Orange expects DUID-LL (type 3) on the wire. The staging script sets `network.wan6.clientid='0003...'` which is DUID-LL; double-check.
- **Vendor-class enterprise number wrong**. DHCPv6 Option 16's enterprise number must be 1368 (Sagemcom) — hex `0000040e`.
  ```
  uci -q get network.wan6.sendopts | tr ' ' '\n' | grep '^16:'
  # should start with 16:0000040e
  ```
- **IA_PD hint missing**. Make sure `reqprefix='56'` is set.
- **Authentication blob (Option 11) stale**. Same Option 90 payload should be in Option 11; rerun `orange-gen-auth.sh`.

### Fix

```
odhcp6c -v ... &     # run odhcp6c manually with -v for verbose
```

Read the verbose output for what's accepted and what isn't.

## Failure: Internet via router works, but a specific service doesn't

This usually isn't a Phase 6 issue; it's downstream configuration. A few common ones:

### WireGuard / VPN clients can't reach the LAN

- DDNS hasn't propagated yet; clients are using the old public IP. See [`12-phase6.5-ddns-verify.md`](12-phase6.5-ddns-verify.md).
- Firewall rule for the VPN port may need updating if you reorganised zones during the migration.

### IPTV decoder shows "service activation error"

- VLAN 840 not configured. See [`13-phase7-iptv.md`](13-phase7-iptv.md).
- IGMP proxy not running.
- Firewall blocking multicast.

### VoIP / phone not working

- Expected on Orange France post-migration unless Phase 8 was tackled. See [`14-phase8-voip.md`](14-phase8-voip.md).

### Orange TV app can't reach decoder for remote PVR

- Port forwards from Phase 9 not in place. See [`15-phase9-port-forwards.md`](15-phase9-port-forwards.md).

## Failure: throughput lower than expected

### Symptom

- Speedtest shows half (or less) of your subscribed plan
- High latency variation under load

### Likely causes

- **SQM bandwidth set too low**. Recheck `uci show sqm` after Phase 6; the interface name probably needs updating from `wan` to `sfp1.832`, and the bandwidth needs to match your actual plan (Orange France typical plans: 500 Mbit, 2 Gbit).
- **Hardware offload (HWNAT) not enabled**. Confirm `flow_offloading 1` in `/etc/config/firewall`.
- **Egress shaping causing buffering**. If you have SQM `cake` on, but bandwidth is set too high, you can hurt latency without limiting throughput. Tune to ~95% of plan.
- **Optical signal degradation**. Rx power degradation in the fibre path can reduce throughput. `ethtool -m sfp1`; expect roughly -10 to -25 dBm range.
- **CPU bound**. Check `top` during a speedtest. If CPU is saturated, HWNAT is off or SQM is doing too much work.

### Fix

Tune SQM bandwidth values and verify HWNAT. Run a wired speedtest to isolate WiFi as a variable.

## Failure: intermittent GPON drops

### Symptom

- `onu ploamsg` sometimes shows `curr_state=5`, sometimes drops to 1/2/3, then recovers
- `logread` on the MA5671A shows OMCI disconnect/reconnect events
- Internet "stutters" — drops for 30-60 s, then recovers

### Likely causes

- **Thermal issues on the MA5671A**. Most common cause in practice. Add a fan, improve airflow, or relocate the router.
- **Fibre signal level marginal**. Verify Rx power; if it's near the lower threshold (typically around -27 dBm for class B+/C+ optics) you have headroom issues.
- **OLT-side issues**. Rare and out of your control; if Rx is fine and the stick stays cool, call ISP support.

### Fix

Thermal first (cheapest to test). If thermal is fine, capture `ethtool -m sfp1` periodically and graph Rx power over time; correlate with the drops.

## Useful diagnostic command bundle

Run all on the router (BPI-R3) when something is wrong:

```sh
echo "=== Network status ==="
ifstatus wan
ifstatus wan6
ifstatus iptv 2>/dev/null

echo
echo "=== Routing ==="
ip route
ip -6 route

echo
echo "=== Interfaces ==="
ip addr show sfp1
ip addr show sfp1.832
ip addr show sfp1.840 2>/dev/null

echo
echo "=== SFP module ==="
ethtool -m sfp1 | head -40

echo
echo "=== Recent log ==="
logread | grep -iE 'error|fail|deny|drop|reject' | tail -30
logread | grep -iE 'udhcpc|odhcp6c|netifd' | tail -20

echo
echo "=== Firewall ==="
fw3 print 2>/dev/null | head -60

echo
echo "=== UCI WAN ==="
uci show network.wan
uci show network.wan6
uci show network.sfp1_832
```

And on the MA5671A:

```sh
sh < scripts/ma5671a-diagnostic.sh    # or run it inline; see 03-ma5671a-specifics.md
```

## When to give up and roll back

If you've been at it for more than two hours and you're not converging on a fix:

- Roll back to the ISP modem (procedure in [`11-phase6-walkthrough.md`](11-phase6-walkthrough.md))
- Capture full state on both router and MA5671A
- Investigate offline with a coffee
- Try again with a fresh head

The migration is not so urgent that it justifies stress. The ISP modem works; use it while you regroup.

## When to escalate to the ISP

There's a small set of issues only the ISP can fix:

- PON not enabled for your subscriber on the OLT
- GPON serial expected by the OLT differs from what your ISP modem reports (rare, but possible after some Orange-side provisioning event)
- Severe Rx signal degradation in the fibre path
- BNG-side issues (very rare, customer-facing)

Orange 3900 is the support number; quality of help is variable. Frame the conversation as "my line isn't working" — don't lead with "I replaced the Livebox with another device", as that may confuse or scare them. If they want to send a technician, agree; the technician will check signal levels at the ODF, which is genuinely useful diagnostic, and they'll plug a Livebox into your fibre to verify the line is alive (which it is). Then they leave; you put the rooted ONT back.
