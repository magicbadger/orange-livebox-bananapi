---
title: Rooting the MA5671A
nav_order: 5
---

# 04a — Rooting the MA5671A (preflight for Phase 4)

A pointer document, not a procedure. The canonical rooting walkthrough lives at hack-gpon.org and is maintained there; duplicating it here would mean two places to keep in sync. This file covers:

- What rooting is and isn't, in the context of this guide
- Which external procedure to follow
- What hardware you need
- What "done" looks like (so you know when to move on to Phase 0)
- Failure modes the reference build actually hit

## What "rooting" means here

The MA5671A ships from Huawei with a sealed firmware: no SSH, no shell, no UCI, no way to change OMCI identity. "Rooting" is the procedure that replaces (or modifies) that firmware so you get:

- SSH access on the management interface (default `192.168.1.10`)
- Read/write UCI for `gpon.onu.*` keys
- Shell access to `omcid`, `omci_pipe`, `config_onu`, `onu`, `sfp_i2c`
- A persistent OpenWrt 14.07-based userland

Without this, none of the rest of the guide applies. Phase 4 (`docs/09-phase4-ma5671a-omci-clone.md`) assumes you can SSH in already.

## Why this isn't a numbered phase

Rooting is a one-off, pre-migration activity. It doesn't touch your existing internet, doesn't risk family service, and doesn't interact with the BPI-R3 at all. It can be done weeks or months before Phase 0. So it sits before the phase sequence rather than inside it.

## Canonical references

Do not follow this file's bullets in place of the actual procedure. Use these:

- **<https://hack-gpon.org/ont-huawei-ma5671a-root-web/>** — primary walkthrough for the web-flash root procedure. English. Authoritative.
- **<https://hack-gpon.org/ont-huawei-ma5671a/>** — hardware overview, firmware-variant matrix, capability summary. Read before starting; tells you what your stick should look like before and after.
- **<https://lafibre.info/materiel-informatique/adaptateur-sfp-to-ttl-v1-1-pour-flasher-vos-modules-gpon-fibre/>** — French companion. Photos of the SFP-to-TTL adapter, UART pinout, hands-on troubleshooting from community members.

## Hardware you need

- An unrooted Huawei MA5671A. The reference build bought one from AliExpress; pricing varies (€30-60 was typical at time of writing). Make sure the listing says MA5671A, not MA5671 (older / different stick).
- An **SFP-to-TTL adapter**. The reference build used the one from <https://tvi.al/sfp-to-ttl-adapter/>. Purpose-built: drops the SFP into a USB-bus-powered cradle and exposes the UART pins on a header. Avoids soldering. Roughly €15-25.
- A **USB-to-UART converter** with 3.3V signalling. FTDI FT232RL-based is reliable; CH340-based clones sometimes drop bytes. The DSD TECH SH-U09C5 (FT232RL) used elsewhere in this guide works.
- A computer with USB and a modern web browser. Most of the procedure runs in the browser.
- A short ethernet cable, for the management interface after rooting completes.

## High-level flow (read the canonical guide for actual steps)

The hack-gpon web-root procedure roughly proceeds:

1. **Hardware setup**: drop the MA5671A into the SFP-to-TTL adapter, wire UART (TX→RX, RX→TX, GND), connect USB to your computer. The stick is powered through the adapter.
2. **Serial console session**: open a serial terminal at 115200 baud. The stick boots; you see U-Boot output and the stock firmware coming up.
3. **Web interface**: connect ethernet from the SFP-to-TTL adapter to your computer (or via a switch). The stick exposes a web admin UI at its default IP. Log in with stock credentials.
4. **In-browser exploit**: the hack-gpon procedure uploads a crafted payload through the web UI that gives a root shell.
5. **Firmware modification**: a script writes the modified firmware to internal flash. Reboot.
6. **Verify**: after reboot, SSH to `192.168.1.10` as `root` — **no password** on this variant. You're in.

Each step has gotchas the canonical guide describes. Don't deviate.

## What "done" looks like

You can SSH into the stick from your computer:

```
ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 \
    -oHostKeyAlgorithms=+ssh-dss \
    root@192.168.1.10
```

It accepts root with no password. You land in `/root/`. `uci show gpon` returns a populated config. `ps w` shows `omcid` running.

If this works, the rest of the guide is now applicable. Move on to Phase 0 (`docs/05-phase0-inventory.md`).

## Failure modes encountered in the reference build

Each cost real time; documenting so you can recognise them.

### Loose UART wire (TX or RX)

The single biggest time-sink. If the TX wire from the adapter to the stick is loose, the serial console shows boot messages (because the stick's TX is still working) but does not respond to anything you type. To Claude / a logger watching, this looks like the stick is "in a reboot cycle" when it's actually fine and waiting for input that's never arriving.

**Diagnostic**: every time you type a character into the serial console, the stick should echo it back (assuming the boot stage has echo on). If you see boot output but no echo, suspect the TX wire from the adapter to the stick.

**Fix**: reseat both UART wires. On the tvi.al adapter, the pins are spring contacts; a slight angle stops one of them making contact. Push the SFP module fully into the adapter and verify the pins are seated against the SFP edge connector.

### "Stuck in reboot loop" mistaken for "needs another minute"

Related to the above. If the stick is genuinely stuck (failed firmware write, bad TX wire, etc.), waiting longer doesn't help. Bound your patience: if you've waited five minutes for a stage that should take under one minute, something is wrong. Check wiring before continuing.

### Web UI not reachable

The stick's stock web UI is on a default IP. If your computer is on a different subnet, you can't reach it. Either:

- Bring up a temporary IP alias on your computer (`sudo ifconfig en0 alias 192.168.1.50/24` on macOS) on the same subnet as the stick, or
- Use a small switch and a separate computer that's not on your normal LAN.

The hack-gpon walkthrough has the exact default IP and credentials.

### Browser blocking the exploit payload

Some modern browsers block the file-upload step of the in-browser exploit on grounds of "looks like an attack". Try a different browser (Firefox tends to be more permissive than Chrome for this kind of upload). Disable any browser extensions that intercept uploads.

## After rooting: what to set immediately

Once SSH works:

1. Set a password (optional but recommended if the stick is going to live on a routed segment):
   ```
   passwd
   ```
2. Confirm the version of the rooted firmware via the canonical-guide instructions. The variant matters for OMCI work later.
3. **Don't yet** touch `gpon.onu.*` UCI keys. That's Phase 4. First do Phase 0 inventory.

## Rollback / recovery

If rooting fails partway and the stick won't boot, you're not stuck — the UART connection lets you intervene at U-Boot. The hack-gpon guide has the recovery procedure: interrupt U-Boot, re-flash from a known-good image over UART or TFTP. Slow but reliable.

If you have a second rooted stick, you can clone its flash image to the broken one over UART. The reference build did not need this fallback.

## Where the rest of this guide picks up

With a rooted, SSH-able stick:

- [`docs/05-phase0-inventory.md`](05-phase0-inventory.md) — capture both the new stick's stock identity and the Livebox's identity, so Phase 4 has the values to clone.
- [`docs/03-ma5671a-specifics.md`](03-ma5671a-specifics.md) — orientation to the firmware, UCI keys, init scripts, and the binaries you'll use.
- [`docs/09-phase4-ma5671a-omci-clone.md`](09-phase4-ma5671a-omci-clone.md) — the OMCI cloning procedure proper.
