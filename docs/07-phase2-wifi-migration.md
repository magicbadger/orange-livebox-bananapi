---
title: "Phase 2: WiFi client migration"
nav_order: 8
---

# 07 — Phase 2: Migrate clients (including IPTV decoder) to the router's WiFi

## Goal

Move all wireless clients from the ISP modem's WiFi to the OpenWrt router's WiFi. The IPTV decoder is the trickiest case and the one most often deferred.

## Success criteria

- Every wireless client appears on the router's DHCP leases page
- The ISP modem's WiFi has no associated clients
- Live TV continues to work (with caveats; see ordering decision below)

## Pre-requisites

- Phase 1 complete (router is the LAN gateway, modem is just modem)
- Router WiFi configured (SSIDs created, passwords set, channels chosen)
- Optional: a separate SSID for IoT/IPTV devices

## Ordering decision: when to migrate the TV decoder

There are two acceptable orderings:

**Option A: Migrate decoder now (Phase 2)** — simpler, but TV may be unavailable between now and Phase 7. The decoder will be on the router's LAN, but multicast doesn't yet flow from the ISP modem's IPTV VLAN through the router. Without the IGMP proxy, live channels won't load.

**Option B: Defer decoder migration to after Phase 7** — TV continues to work via the modem until Phase 7 sets up IGMP proxy on VLAN 840. Migrate the decoder once multicast on the router is verified. This is the recommended order for households who actually watch live TV.

This document covers Option B. If you've chosen Option A, also do step 5 (decoder migration) now and accept that channels won't tune until Phase 7.

## Steps

### 1. Inventory the current WiFi clients

On the ISP modem admin UI, list connected wireless clients. Note MAC, hostname, what each device is. You'll want to confirm each device makes it across.

### 2. Migrate "easy" devices first

Phones, laptops, tablets, smart speakers. Tell the device to forget the modem SSID, then join the router SSID. Reauth via WPA2 / WPA3 password, done.

If you've named the router SSID the same as the modem SSID (not recommended; it confuses roaming), devices may auto-pick whichever has a stronger signal; you'd then have to disable WiFi on the modem before the migration completes. Easier if router and modem SSIDs are distinct.

### 3. Migrate "fiddly" devices

IoT plugs, climate devices, IP cameras, smart bulbs. Each has its own dance:

- WPS-capable devices: press WPS on router (`hostapd_cli -i wlan0 wps_pbc` or the LuCI button) and on the device.
- Manual-only devices: factory reset, walk through the vendor app's onboarding.
- Devices on a fixed IP: ensure the corresponding static lease exists on the router DHCP before migrating.

A common pattern is a dedicated SSID for IoT devices (call it `Home-IoT` or similar) with WPS enabled. WPS on an IoT SSID was a substantial yak-shave in our experience: the default `wpad-basic-mbedtls` package silently fails when WPS is enabled; the fix is to install `wpad-openssl` instead. If you hit this, `radio0` will appear UP in UCI but no SSID will broadcast; `logread | grep hostapd` shows the silent failure.

### 4. Verify each device

After migration, check:

- The device appears on the router's DHCP leases (`cat /tmp/dhcp.leases`)
- The device gets the IP you expect (static lease if it had one before)
- The device works: IoT app sees it, smart speaker responds to commands, etc.

### 5. (Option B path) Migrate the IPTV decoder — DEFER to after Phase 7

If you're following Option B, skip this step for now. Come back to it once Phase 7 (IGMP proxy on VLAN 840) is up and you've verified multicast flows.

When you do migrate:

#### 5a. Identify the decoder's MAC

From the ISP modem's connected-devices list. Note the MAC for the static lease.

#### 5b. Add a static DHCP lease on the router

```
uci add dhcp host
uci set dhcp.@host[-1].mac='DECODER_MAC'
uci set dhcp.@host[-1].ip='192.168.1.12'
uci set dhcp.@host[-1].name='tv-decoder'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

`192.168.1.12` is convention; pick what suits you. The static IP matters because Phase 9 port forwards will target it.

#### 5c. Join the decoder to the router's SSID

Method depends on the decoder:

- **WPS**: press WPS on router, then on decoder. Some older Orange decoders do not support modern WPS; they may say "WPS" on the box but use a non-standard variant. If WPS fails, try the manual method.
- **Manual**: on the decoder, go to network settings, scan, pick the router SSID, enter the password.

The decoder MAY require a reboot before it picks up the new network properly.

#### 5d. Test channel tuning

Power-cycle the decoder. Wait ~60 s for boot. Try a live channel. If channels load and the picture is stable, decoder migration succeeded.

If channels don't load, troubleshoot:

- The decoder reaches the internet (Orange auto-provisioning) over the data network: verify with the decoder's network-diagnostic menu.
- IGMP proxy is forwarding multicast: `ip mroute`, `cat /proc/net/igmp`.
- Firewall isn't blocking multicast: see [`13-phase7-iptv.md`](13-phase7-iptv.md).

## Risks

- **Locked-out device.** A device that doesn't make it across stays on the modem WiFi; after Phase 3 (modem WiFi disabled), it loses connectivity. Take inventory before disabling.
- **Decoder loses TV until Phase 7.** Expected if you migrate it now; document expectation with household.
- **Re-pairing fiddly IoT.** Some devices (early-model smart plugs) only do 2.4 GHz and will mysteriously fail to join a 5 GHz SSID; ensure your IoT SSID is 2.4 GHz-capable.
- **WPS silent failure on `wpad-basic-mbedtls`.** Symptom: WPS button does nothing visible, radio appears UP. Fix: `opkg install wpad-openssl` (replacing `wpad-basic-mbedtls`).

## Rollback

- Re-join the device to the modem WiFi. Fully reversible.
- If the modem WiFi has been disabled (Phase 3), re-enable it from the admin UI and re-join.

## Notes

This phase is largely procedural and varies wildly by household. The key insight is: don't disable the modem WiFi (Phase 3) until you're sure every important client has migrated. If you're unsure, leave both WiFi networks running for a week and watch the router DHCP leases page.
