# 08 — Phase 3: Disable WiFi on the ISP modem

## Goal

Stop the ISP modem broadcasting WiFi, so the household has a single set of SSIDs (the router's) rather than two. This is a tidy-up phase, not strictly required for the migration, but it reduces support load (people picking the wrong SSID, devices auto-roaming back to the modem).

## Success criteria

- The modem's SSIDs no longer appear in WiFi scans
- All previously connected clients remain online via the router

## Pre-requisites

- Phase 2 complete (Phase 2 Option A or Option B, doesn't matter which here)
- All wireless clients verified to be on the router's WiFi

## Steps

### 1. Final inventory check

On the ISP modem admin UI, view connected wireless clients. The list should be empty (or near-empty; sometimes a stale entry persists for a few minutes after the device has reconnected to the router).

If there are clients still on the modem WiFi, identify them. Walk to the device (laptop, IoT, etc.) and migrate it now. Do not proceed until this list is clean.

### 2. Disable WiFi radios

Orange Livebox admin UI:

- WiFi → 2.4 GHz → "Activer" toggle → off → save
- WiFi → 5 GHz → "Activer" toggle → off → save

Some Livebox UIs additionally have a "WiFi master switch" or a "WiFi schedule" page. Disable both radios fully.

### 3. Verify SSIDs no longer broadcast

From a phone or laptop, scan available networks. The modem's SSIDs should not be visible.

The modem may still show the SSID strings in its UI (greyed out or with a "disabled" badge); that's fine, as long as they're not broadcasting.

### 4. Verify all devices remain online

Pinch every important device:

- Web access from a laptop on the router WiFi
- Mobile data confirms phone has internet
- IoT control via the relevant app
- Smart speakers respond
- IPTV decoder, if migrated, continues to work (Option B: it's still on modem WiFi; Option A: it works via router WiFi + the IGMP proxy you'll set up in Phase 7, or it doesn't tune channels yet)

## Risks

- **Forgotten device locked out.** Inevitably one obscure device (often a smart bulb in a guest room, or a doorbell, or a smart-meter dongle) was missed. It loses internet now. The fix is the obvious one: log into the device console somehow (often by holding a button to factory-reset to AP mode), reconfigure to the router WiFi.

## Rollback

Trivially reversible from the modem admin UI: re-enable the WiFi radios. The SSIDs and passwords are preserved by the modem when you toggle radios off.

## Notes

You can also use this as an opportunity to clean up the modem admin password (rotate to something stronger) and confirm the modem WAN-facing services (UPnP, remote admin) are disabled — since the modem will, before long, no longer be terminating the fibre.

## Why this phase is optional

Some households are happy to leave the modem WiFi running as a "guest network" — clients picking it get NATed twice but the experience is fine for casual use. The downside is the broadcasted SSID adds confusion (which one do I pick?) and consumes airtime. We disable it because the router has a proper guest SSID and the modem WiFi is purely vestigial at this point.

If you keep the modem WiFi running, skip this phase. The rest of the migration is unaffected.
