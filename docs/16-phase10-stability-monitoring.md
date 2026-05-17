---
title: "Phase 10: Stability monitoring"
nav_order: 17
---

# 16 — Phase 10: Stability monitoring

> **Status: work in progress (ongoing operational phase).** This is a 1-2 week observation period rather than a one-shot task. Once the migration is verified stable, the original ISP modem can be retired (Phase 11).

## Goal

Confirm the direct-GPON setup is stable for normal household use before declaring the migration complete and putting the ISP modem away. The goal is to surface intermittent issues that only show up under specific load patterns or over time: thermal failures, DHCP lease renewal problems, IPTV stutters under load, SQM regressions.

## Success criteria

- 7 to 14 consecutive days of stable uptime on the router
- No complaints from household about internet, TV, or remote-access services
- No unexpected reboots or daemon crashes in `logread`
- DDNS staying current
- WireGuard / remote access reliable

## Pre-requisites

- Phase 6 complete (at minimum)
- Other phases complete or knowingly deferred
- The ISP modem available as a rollback fallback (do not retire it yet)

## What to monitor

### 1. Router uptime

```
ssh root@<router-ip> 'uptime'
```

Check daily. Anything that looks like an unexpected reboot (uptime resetting unexpectedly) is a flag.

If you have a network monitoring system (Home Assistant, Grafana, etc.) hook into the router via SNMP or SSH and graph uptime.

### 2. Public IP stability

```
curl -s -4 https://ifconfig.io
```

Orange France delivers semi-static IPs that change rarely (months between changes in our experience). Track the IP daily; if it changes more than once a fortnight, your DDNS automation is being exercised more than expected, which is worth knowing.

### 3. DDNS

```
nslookup <your.ddns.hostname> 8.8.8.8
```

Should match the current public IP. If it diverges, the DDNS update isn't running or isn't being accepted.

Also check the ddns-scripts log:

```
cat /var/log/ddns/<section>.log | tail -50
```

### 4. WAN lease

```
ssh root@<router-ip> 'ifstatus wan | jq .data'
```

(Or read the JSON directly without `jq`.) Check the lease timer; Orange France leases are typically 86400 s (24h). The router should renew automatically before expiry. If you see lease expiry events in `logread`, the renewal is bouncing the interface; investigate.

### 5. GPON / OMCI on the rooted ONT

Drop into the MA5671A occasionally:

```
ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 -oHostKeyAlgorithms=+ssh-dss root@192.168.1.10
onu ploamsg
```

`curr_state=5` should be steady. If it ever drops (transient O5 → O1 → O5), the GPON link is flapping — usually a thermal issue on the stick or a fibre signal issue. Check Rx power:

```
ethtool -m sfp1 | grep -A4 -i 'optical power'
```

Significant drops in Rx power suggest a connector problem or fibre damage between the OLT and your premises.

### 6. IPTV (if Phase 7 done)

Observation only — note any:

- Channel-switching delays beyond ~2 s
- Picture stutters / pixelation
- Audio dropouts
- Channels failing to load
- Decoder rebooting / showing service errors

Most issues show up during peak-load times (evenings). A week of normal TV use is a fair test.

### 7. VoIP (if Phase 8 done, hybrid mode)

Observation only — note any:

- Missed incoming calls
- Failed outgoing calls
- Echo or quality degradation
- Voicemail issues

### 8. Remote access

Test WireGuard from outside the LAN at least once a week. Connect, ping a LAN host, transfer a small file. Confirm latency is reasonable.

### 9. Bufferbloat / latency

Run a bufferbloat test periodically (Waveform's, dslreports.com, or `speedtest-cli` plus latency probes). Capture results to compare against the pre-migration baseline.

Recommended: <https://www.waveform.com/tools/bufferbloat>.

### 10. Thermal observation

The MA5671A runs hot. Touch test (carefully) the SFP cage region of the router after a day of running. If it's painfully hot, consider:

- Adding a fan to blow across the SFP cages
- Repositioning the router for better airflow
- Adding a beefier heatsink to the stick

Sustained GPON drops correlate with thermal issues in our experience.

## Daily / weekly checklist

A reasonable rhythm:

**Daily (90 seconds):**

```
ssh root@<router-ip> 'uptime; curl -s -4 https://ifconfig.io'
```

**Weekly (~10 min):**

- DDNS resolution from external DNS
- WireGuard from outside
- Read `logread | grep -iE 'error|fail|crash' | tail -50` for anything noteworthy
- Touch test the router

**End-of-week:**

- Bufferbloat test
- Note any household-reported issues

Keep a brief log. Even one-line entries help spot patterns: "Day 5: TV pixellated during football, evening 21:00. Restored after channel change. Repeat?"

## Risks

- **Issues only appearing under specific loads** — the whole point of a multi-week observation period. Don't shortcut this.
- **Slow IP address change going unnoticed** — DDNS automation should catch it, but verify weekly that the DDNS hostname resolves to the current IP.
- **Storage filling up with logs** — `logread` is in-memory, but if you've configured persistent logging, watch storage. `df -h` periodically.

## Decision at end of monitoring period

After 7-14 days of stable operation:

- All household services working → proceed to Phase 11 (retire the ISP modem)
- Intermittent issues identified → diagnose and fix, then restart the monitoring clock
- Unfixable issue → consider whether to roll back to the ISP modem long-term

## Notes

This is the least exciting phase but arguably the most important. Most setups work end-to-end in lab conditions; it's the long-tail issues that bite. Patience here saves embarrassment later.

If you're tempted to skip and go straight to Phase 11, at least give the setup a long weekend of normal use first. A week is better.
