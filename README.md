---
title: Home
nav_order: 0
layout: home
---

# Direct GPON Termination on OpenWrt

A practical, field-tested guide to replacing an ISP-provided GPON router (e.g. Orange France Livebox) with a generic Linux router running OpenWrt, using a rooted GPON SFP stick. Written from hands-on experience with a Banana Pi BPI-R3 and a Huawei MA5671A on Orange France fibre, but generalisable to any OpenWrt-capable router with an SFP cage and a supported ONT stick.

This guide focuses heavily on the things that public research did not surface, particularly around OMCI provisioning quirks on the rooted Huawei firmware. The goal is to save someone else a multi-evening reverse-engineering session.

## Table of Contents

1. [What this is and what it isn't](#what-this-is-and-what-it-isnt)
2. [Reference setup](#reference-setup)
3. [Prerequisites](#prerequisites)
4. [Risks and mitigations](#risks-and-mitigations)
5. [Repository layout](#repository-layout)
6. [Phased approach](#phased-approach)
7. [Critical insights not in the public docs](#critical-insights-not-in-the-public-docs)
8. [Scripts](#scripts)
9. [References and credits](#references-and-credits)
10. [Licence and disclaimer](#licence-and-disclaimer)

## What this is and what it isn't

**This is**: a guide to terminating GPON directly on an OpenWrt router, cloning your ISP's ONT identity to a rooted SFP stick, configuring the ISP's required DHCP options, and verifying authentication on the OLT.

**This is not**: a guide to obtaining a rooted GPON SFP, modifying GPON firmware, or extracting credentials from your ISP's modem. Those steps are covered elsewhere (see [References](#references-and-credits)) and have their own legal and technical considerations in your jurisdiction.

**Difficulty**: intermediate to advanced. You should be comfortable with OpenWrt UCI, shell scripting, network packet captures, and prepared to read kernel logs and ISP-specific protocol details. Plan for downtime; budget multiple evenings the first time.

**Compatibility risks**: the procedure described here works on a specific firmware variant of the MA5671A. Other rooted firmwares (FS-modded, Carlito's, SourcePhotonics) expose different command sets and may need different procedures.

## Reference setup

The setup this guide was developed against:

- **Router**: Banana Pi BPI-R3 running OpenWrt 25.12.2 on eMMC. Two SFP cages (`sfp1` and `sfp2`), one copper WAN port (`wan`), and four LAN ports.
- **ONT stick**: Huawei MA5671A GPON SFP, with rooted firmware giving SSH and full Linux access.
- **ISP**: Orange France fibre (FTTH), VLAN 832 for data, VLAN 840 for IPTV.
- **Pre-rooted from**: original Livebox S (Sagemcom). MAC, GPON serial, equipment ID, and PPP/DHCP credentials captured before swap.
- **Optional but recommended**: a USB-to-UART adapter (e.g., DSD TECH SH-U09C5 with FT232RL chipset) for serial console access to the BPI-R3 in case SSH dies.

Generalising:

- Any OpenWrt-capable router with at least one SFP cage and a supported SFP-via-mdio path will do. The BPI-R3 is convenient because its SFP cages map cleanly to dedicated netdevs (`sfp1`, `sfp2`).
- The MA5671A is the most common rooted ONT stick. Alternatives (FS-modded, Carlito, SourcePhotonics) work with different procedures.
- ISP specifics vary widely. Orange France is documented here in detail. Adapt the DHCP options and VLAN IDs to your ISP. The OMCI identity cloning steps are generic.

## Prerequisites

### Hardware

- An OpenWrt-capable router with an SFP cage. A second SFP cage is very helpful for staging without taking down the live ONT.
- A rooted GPON SFP stick compatible with your ISP's OLT vendor (Huawei, Nokia, etc).
- A working fibre patch and the ability to swap fibre between your existing ONT/router and the new stick.
- (Strongly recommended) USB-to-UART adapter for the router's serial console, in case you lock yourself out via SSH.

### Software

- OpenWrt 22.03 or later on the router (this guide tested with 25.12).
- `udhcpc` (busybox, in default OpenWrt) or `dhcpcd` for the DHCP client.
- `tcpdump` (install via `opkg install tcpdump-mini` if not present).
- Access to a Linux/macOS workstation for SSH and packet analysis.

### Information you must collect before starting

From your existing ISP-provided modem (e.g. Livebox), capture:

- The WAN-side MAC address.
- The GPON Serial Number (vendor ID + 8 hex chars, e.g. `ARLT12345678`).
- The OMCI Equipment ID (often a model code like `PRV33AX346B0000`).
- The OMCI Vendor ID (4 ASCII chars, e.g. `ARLT`).
- The OMCI Hardware Version / ONT Version (up to 14 bytes, e.g. `ARLTLBN100`).
- (Sometimes) OMCI Software Image versions, if you want strict identity match.
- ISP DHCP options the modem sends: Option 60 (vendor class identifier), Option 61 (client ID format), Option 77 (user class), Option 90 (authentication, RFC 3118). Capture these via packet sniffing on the modem's WAN port if possible.
- VLAN ID for data (e.g. 832 for Orange France).
- VLAN ID for IPTV (e.g. 840 for Orange France) if you have a TV decoder.
- PPP/DHCP credentials if your ISP uses authenticated DHCP (Orange uses an `fti/...` user/password pair).

The cleanest way to capture these on Orange France is the GO-BOX tool, which extracts most fields directly from a Livebox via its diagnostic interface. See [References](#references-and-credits).

### Skills

- Comfortable editing UCI and writing shell scripts.
- Reading and interpreting tcpdump output.
- Basic understanding of DHCP option encoding (hex), VLAN tagging, and the GPON activation flow (PLOAM states O1 through O5, OMCI provisioning).
- Willingness to read source code and `strings` output from binaries when documentation is missing.

### Time and downtime budget

- First time: budget 2-4 evenings of 2-3 hours each. The OMCI identity work alone consumed ~90 minutes of focused investigation in one session.
- Each fibre swap and network restart causes ~2 minutes of downtime per attempt. Plan attempts when family/users tolerate it.
- Keep the original modem in place and powered for rollback.

## Risks and mitigations

**Loss of internet service** is the primary risk. The original modem must be reachable in seconds for rollback. Mitigations:

- Stage all configuration changes while the original modem is still terminating the fibre. Apply changes via UCI but do not restart networking until the fibre is physically swapped.
- Always create a timestamped backup of `/etc/config/network` before staging changes. Rollback is `cp` + `/etc/init.d/network restart`.
- Keep the original modem powered. Reconnecting the fibre to it is the universal restore path.
- If using a router with two SFP cages, keep the rooted ONT in SFP2 while still on the original modem. This lets you SSH into the ONT for OMCI work without disrupting service.

**Loss of router management access** if you misconfigure LAN. Mitigation: use the serial UART console as a fallback.

**ISP-side blacklisting** is theoretically possible but rare. ISPs typically detect identical GPON serials operating simultaneously, not clones operating after the original ONT goes offline. Power down the original ONT before activating the clone.

**IPTV/VoIP service breakage** is highly likely without explicit configuration of the IPTV VLAN and IGMP proxy. Plan for this if your household relies on the ISP TV service. The Phase 7 investigation in this repo characterises the Orange-PKI architecture that gates decoder activation — see [`docs/13-phase7-iptv.md`](docs/13-phase7-iptv.md) for the conclusion that a hybrid (Livebox-on-LAN as TV+VoIP appliance) is the realistic end state.

**Legal**: cloning your own ISP-provided modem's identity to a different device, for use on your own line, is generally not illegal in EU jurisdictions, but check your ISP's terms of service. This guide does not cover bypassing payment or accessing service you have not contracted for.

## Repository layout

```
.
├── README.md                              (this file — overview + critical insights)
├── LICENSE                                (CC BY 4.0)
├── docs/
│   ├── 01-prerequisites.md                (detailed hardware/software)
│   ├── 02-bpi-r3-specifics.md             (BPI-R3 quirks, SFP cage mapping)
│   ├── 03-ma5671a-specifics.md            (the rooted firmware in detail)
│   ├── 04-orange-france-notes.md          (ISP-specific DHCP, VLANs, auth)
│   ├── 04a-rooting-the-ma5671a.md         (pointer to the hack-gpon web-root procedure)
│   ├── 05-phase0-inventory.md             (Phase 0: inventory and backup)
│   ├── 06-phase1-staging.md               (Phase 1: router behind ISP modem)
│   ├── 07-phase2-wifi-migration.md        (Phase 2: migrate WiFi clients)
│   ├── 08-phase3-disable-livebox-wifi.md  (Phase 3: disable ISP modem WiFi)
│   ├── 09-phase4-ma5671a-omci-clone.md    (Phase 4: clone OMCI identity onto MA5671A)
│   ├── 10-phase5-wan-staging.md           (Phase 5: stage WAN UCI)
│   ├── 11-phase6-walkthrough.md           (Phase 6: the fibre swap — headline procedure)
│   ├── 12-phase6.5-ddns-verify.md         (Phase 6.5: DDNS verification)
│   ├── 13-phase7-iptv.md                  (Phase 7: IPTV — investigated, hybrid path identified)
│   ├── 14-phase8-voip.md                  (Phase 8: VoIP — folds into Phase 7 hybrid)
│   ├── 15-phase9-port-forwards.md         (Phase 9: TV/management port forwards — WIP)
│   ├── 16-phase10-stability-monitoring.md (Phase 10: stability monitoring — WIP)
│   ├── 17-phase11-retirement.md           (Phase 11: ISP modem disposition — WIP)
│   ├── 18-omci-architecture.md            (the OMCI identity dance, deep dive)
│   ├── 19-troubleshooting.md              (common failure modes and diagnostics)
│   └── 20-references.md                   (tools, links, credits)
├── scripts/
│   ├── orange-wan-config.sh               (stages UCI for direct GPON WAN)
│   ├── orange-gen-auth.sh                 (generates RFC 3118 Option 90)
│   └── ma5671a-diagnostic.sh              (snapshot of ONT state for resume)
└── etc/
    └── orange-auth.example                (credential file template)
```

This README is the executive summary plus the cross-cutting insights. The `docs/` directory contains the procedural detail — one walkthrough per phase, plus reference material. The `scripts/` directory holds the standalone shell scripts referenced from the phase walkthroughs.

## Phased approach

Splitting this into discrete phases is critical. Each phase has a clear success criterion and a clear rollback handle. The reference build through Phase 6 is complete and validated; Phase 7 has been investigated in depth and the realistic end state is the hybrid; Phases 8-11 fold into that or remain WIP.

- **Phase 0**: Inventory and capture. Identify your modem's WAN MAC, GPON SN, OMCI values, DHCP options, VLAN tags. Make backups. See [`docs/05-phase0-inventory.md`](docs/05-phase0-inventory.md).
- **Phase 1**: Router behind ISP modem. Put your OpenWrt router downstream of the ISP modem in double-NAT mode. Verify all LAN clients work through it. See [`docs/06-phase1-staging.md`](docs/06-phase1-staging.md).
- **Phase 2** (optional): Migrate WiFi clients (including TV decoder) from ISP modem to OpenWrt router. See [`docs/07-phase2-wifi-migration.md`](docs/07-phase2-wifi-migration.md).
- **Phase 3** (optional): Disable WiFi on the ISP modem to avoid confusion. See [`docs/08-phase3-disable-livebox-wifi.md`](docs/08-phase3-disable-livebox-wifi.md).
- **Phase 4**: Clone the OMCI identity onto the rooted ONT stick. (ONT rooting itself is a pre-step; pointers in [`docs/04a-rooting-the-ma5671a.md`](docs/04a-rooting-the-ma5671a.md). This phase assumes you have a rooted stick.) See [`docs/09-phase4-ma5671a-omci-clone.md`](docs/09-phase4-ma5671a-omci-clone.md) and the deep dive in [`docs/18-omci-architecture.md`](docs/18-omci-architecture.md).
- **Phase 5**: Stage Phase 6 configuration. Apply UCI changes on the router while still on the original modem. Do not restart networking. See [`docs/10-phase5-wan-staging.md`](docs/10-phase5-wan-staging.md).
- **Phase 6**: Direct GPON termination. Physically swap the fibre. This is the headline event and the main subject of this guide. See [`docs/11-phase6-walkthrough.md`](docs/11-phase6-walkthrough.md).
- **Phase 6.5**: DDNS verification after the public IP changes. See [`docs/12-phase6.5-ddns-verify.md`](docs/12-phase6.5-ddns-verify.md).
- **Phase 7**: IPTV. Investigated in depth; the decoder activation chain involves Orange-PKI mutual TLS and the realistic end state is the hybrid (Livebox-on-LAN as TV+VoIP appliance). See [`docs/13-phase7-iptv.md`](docs/13-phase7-iptv.md).
- **Phase 8**: VoIP / SIP. Folds into the Phase 7 hybrid. See [`docs/14-phase8-voip.md`](docs/14-phase8-voip.md).
- **Phase 9** (WIP): Replicate Livebox-side port forwards for advanced TV features. See [`docs/15-phase9-port-forwards.md`](docs/15-phase9-port-forwards.md).
- **Phase 10** (WIP): 1-2 week stability monitoring. See [`docs/16-phase10-stability-monitoring.md`](docs/16-phase10-stability-monitoring.md).
- **Phase 11** (WIP): Final disposition of the ISP modem (return / store / hybrid). See [`docs/17-phase11-retirement.md`](docs/17-phase11-retirement.md).

If you want the operational detail for any of these, go straight to the corresponding doc. The rest of this README is the cross-cutting insights that don't live cleanly in any single phase.

## Critical insights not in the public docs

These are the things that were not in any guide, forum post, or HOWTO at the time of writing. They cost us hours each to figure out.

### 1. gSerial is the only OMCI field the OLT really enforces

Public guides emphasise getting all OMCI Managed Entity values right: vendor ID (ME 256 attr 1), version (ME 256 attr 2), serial (ME 256 attr 3), equipment ID (ME 257 attr 1), software image versions (ME 7 instances 0 and 1).

In our testing, only the gSerial (ME 256 Serial Number) actually had to match. Equipment ID was completely wrong (mangled to nSerial value) and Version had ASCII '0' padding instead of NUL bytes, and Orange's BNG still authenticated cleanly, issued a DHCP lease, and routed traffic.

This means: **focus your OMCI cloning effort on the gSerial**. The other fields are checked by some OLTs in some configurations, but in many real-world deployments they pass. If gSerial is correct, try the fibre. Don't burn hours on the other fields until you know they actually block you.

### 2. `gpon.onu.mib_file` is a trap

In the rooted Huawei firmware, `omcid.sh` decides which MIB file to load through a four-branch chain in `start_service()`. The third branch (`mib_customized == 1`) is the one that triggers regeneration of `/etc/mibs/custom.ini` from your UCI values.

But the second branch fires first if `gpon.onu.mib_file` is set to anything other than a path containing the literal string `custom.ini`. The default rooted firmware leaves `mib_file` set to the static `/etc/mibs/data_1g_8q_us1280_ds512.ini`, which fires branch 2 and silently bypasses the customisation.

**Fix**: `uci delete gpon.onu.mib_file` (or set it to `/etc/mibs/custom.ini`) before reboot. The script will populate it correctly on first run.

### 3. `omcid` reads ME 256/257 identity from hardware registers, not from the MIB file

This was the biggest surprise. We spent significant effort getting `/etc/mibs/custom.ini` correct, then a "ZZZZ" sentinel test proved omcid does not read ME 256 / 257 vendor, version, or equipment ID from the file at runtime.

Instead: at boot, `/etc/init.d/config_onu` (which runs as S60, before `omcid.sh` at S85) programs hardware identity registers from UCI keys. omcid reads from those registers when it initialises. The custom.ini file's ME 256/257 lines are inert decoration.

**Implication**: the only way to control ME 256/257 identity is via the UCI keys that `config_onu` reads: `gpon.onu.vendor_id`, `gpon.onu.ont_version`, `gpon.onu.equipment_id`, and `gpon.onu.nSerial`.

The MIB file IS authoritative for other MEs (ME 7 Software Image is auto-populated from U-Boot env image0_version / image1_version; everything else is from the file).

### 4. `config_onu` has two known mangling bugs

The Huawei `config_onu` binary on this rooted firmware:

- Reads `gpon.onu.equipment_id` from UCI but writes the value of `gpon.onu.nSerial` to the Equipment ID hardware register. It also rewrites the UCI key with nSerial's value, so the mangling persists across boots.
- Reads `gpon.onu.ont_version` and converts `\0` escape pairs (literal backslash-zero) into ASCII '0' characters before writing to the register and back to UCI. The 14-byte field that should be `ARLTLBN100<NUL><NUL><NUL><NUL>` ends up as `ARLTLBN1000000` (14 ASCII characters).

We attempted to override via `omci_pipe meads` (the OMCI MIB data set CLI) but it enforces OMCI R/W flags and refuses writes to read-only attributes (Vendor ID, Version, Equipment ID are all read-only).

The escape hatch we did not exhaust: `onu onurs` (raw register write by address), which would work if you have the Intel/Lantiq Falcon SoC GPON identity register addresses. Those were not on the device or in the binary's strings; you'd need datasheet access or further reverse engineering.

**For most ISPs**: these mangling bugs don't matter because gSerial is what's enforced (see insight 1). Document them, don't fight them.

### 5. `LOWER_UP` on the SFP netdev does NOT mean GPON authenticated

Trap we fell into for hours in the prior session. `ip link show sfp1` showing `<LOWER_UP>` only means the SFP module is electrically connected and the SerDes link is up. It says nothing about whether the GPON MAC is in ranging, whether PLOAM has succeeded, or whether OMCI provisioning is complete.

**Reliable indicators of actual GPON state** (on the rooted ONT, not the router):

```
onu ploamsg
# curr_state=1: O1 initial (no downstream signal)
# curr_state=2: O2 standby (signal but no ranging)
# curr_state=3: O3 serial number ranging
# curr_state=4: O4 ranging in progress
# curr_state=5: O5 operation (fully authenticated, OMCI happy)
```

You want `curr_state=5` before you expect DHCP to work.

### 6. netifd silently overrides DHCP Option 61

If you set `list sendopts '61:HEX'` on a wan interface in OpenWrt, netifd generates a DUID-UUID and uses that as the Client Identifier instead of your hex. The Option 61 you carefully crafted never reaches the wire.

**Fix**: use `option clientid 'HEX'` on the interface, not `sendopts '61:HEX'`. This is documented somewhere obscure in OpenWrt source but does not appear in most third-party DHCP-options guides.

### 7. PCP=6 egress marking is required on the WAN VLAN for Orange France

The Orange BNG silently drops DHCP packets that arrive without 802.1p priority 6 (Network Control class). Public guides mention this but it's easy to miss.

Set on the interface:

```
uci set network.sfp1_832.egress_qos_mapping='0:6 1:6 2:6 3:6 4:6 5:6 6:6 7:6'
```

Verify on the wire:

```
tcpdump -i sfp1 -nn -e vlan 832 -c 5
# Each frame should print "vlan 832, p 6"
```

### 8. Option 60 says "arcadyan", not "sagemcom"

The Livebox S MAC OUI is `64:75:DA` which is Sagemcom. Despite this, the Option 60 vendor class identifier the Livebox sends in DHCP is `arcadyan` (the previous OEM). Orange checks Option 60 against `arcadyan`. If you send `sagemcom`, your DHCP is rejected.

This is firmware behaviour overriding OEM identification, and is a common pattern across multiple ISPs and rebranded equipment.

### 9. Option 77 user-class length prefix is 0x32 on Livebox Nautilus

DHCP Option 77 (User Class, RFC 3004) is a sequence of one or more length-prefixed strings. The Livebox sends a single class data instance:

```
32 46 53 56 44 53 4c 5f ...  (full string "FSVDSL_livebox.Internet.softathome.LiveboxNautilus")
```

The first byte `0x32` is the length prefix (50 decimal, the length of the string).

**Common mistake**: omit the length prefix, sending only the ASCII string. Orange's BNG will reject. Make sure your `sendopts '77:HEX'` value starts with the length prefix.

### 10. Option 90 (RFC 3118 auth) needs a fresh salt periodically

Orange uses Option 90 (DHCP Authentication, protocol 3 = delayed authentication). The payload includes a server-provided nonce (salt) plus a MD5 hash of password and challenge. The salt expires; old salts produce auth failures.

**Solution**: regenerate before each DHCP attempt. The included `orange-gen-auth.sh` does this; run it as part of your network restart procedure or schedule it weekly via cron.

The MD5 hash is computed over: `salt + ipv4_addr (4 bytes of zeros if unknown) + 0x01 + 0x01 + 0x03 + password`. Format is finicky; the script captures the working format.

## Scripts

Three shell scripts live in `scripts/`, each also embedded inline in the relevant phase walkthroughs. They're sanitised templates; replace the placeholder values (`64:75:DA:XX:XX:XX`, `ARLT12345678`, etc.) with your own captured values before running.

| Script | Purpose | Embedded in |
|---|---|---|
| [`scripts/orange-wan-config.sh`](scripts/orange-wan-config.sh) | Stages OpenWrt UCI for direct GPON WAN via SFP1. Backs up `/etc/config/network`, sets up the tagged VLAN device, configures DHCP/DHCPv6 with the cloned MAC, hostname, and DHCP options (60, 61, 77, 90). Does NOT restart networking. | [`docs/10-phase5-wan-staging.md`](docs/10-phase5-wan-staging.md) |
| [`scripts/orange-gen-auth.sh`](scripts/orange-gen-auth.sh) | Generates a fresh DHCP Option 90 (RFC 3118 delayed-auth) salt and hash from credentials in `/etc/orange-auth`, writes the new payload into UCI. Run before each network restart. | [`docs/10-phase5-wan-staging.md`](docs/10-phase5-wan-staging.md) |
| [`scripts/ma5671a-diagnostic.sh`](scripts/ma5671a-diagnostic.sh) | Snapshot script for the rooted MA5671A: process state, UCI GPON config, OMCI ME 256/257/7 contents, PLOAM state, MIB file selection, recent logs, U-Boot env. Useful for resuming work between sessions. | [`docs/09-phase4-ma5671a-omci-clone.md`](docs/09-phase4-ma5671a-omci-clone.md) |

The credentials file template is at [`etc/orange-auth.example`](etc/orange-auth.example). Copy to `/etc/orange-auth` on the router, edit with your real Orange `fti/...` credentials, `chmod 600`.

## References and credits

### Tools used

- **OpenWrt** — [openwrt.org](https://openwrt.org). The base operating system.
- **GO-BOX** — Diagnostic tool for extracting GPON identity and DHCP options from Sagemcom Livebox devices. (Search "GO-BOX livebox" on hack-gpon forums.)
- **tcpdump / Wireshark** — Packet inspection. The Option 90 reverse-engineering would not have been possible without these.
- **busybox md5sum / hexdump / printf** — POSIX-only Option 90 salt and hash generation, runs on the router itself.

### Research sources

- **hack-gpon.org** — Authoritative reference for rooting GPON SFP modules, OMCI identity cloning concepts, OLT-side checks across vendors. The original source for the "fake O5 status" trap.
- **kgersen's Option 90 generator** — Reference implementation of RFC 3118 for Orange France authenticated DHCP. (Search "kgersen orange option 90" or similar.)
- **OpenWrt forum threads** — Many discussions on bridging Livebox, SFP-via-mdio for BPI-R3, and DHCP option encoding quirks.
- **lafibre.info forums** — French-language community, deep knowledge of Orange France ISP specifics.
- **Lantiq/Intel Falcon SoC** — Some technical detail available in publicly archived datasheets and Intel's Linux driver source. Useful for understanding the GPON MAC architecture.

### Standards and RFCs

- **RFC 2131** (DHCP), **RFC 3004** (User Class), **RFC 3118** (Authentication), **RFC 3315** (DHCPv6).
- **ITU-T G.984** (GPON), **G.988** (OMCI).
- **IEEE 802.1Q** (VLAN tagging), **IEEE 802.1p** (priority code point).

### Communities

- OpenWrt forum: detailed help and configuration debugging.
- hack-gpon: the centre of gravity for SFP ONT rooting and OMCI tricks.
- Reddit r/openwrt, r/HomeNetworking: general help, less specialised.
- Orange France-specific French-language forums (lafibre.info, frenchspeaking forums).

## Licence and disclaimer

This guide and the included scripts are released under the **Creative Commons Attribution 4.0 International License** (CC BY 4.0). See [`LICENSE`](LICENSE).

This work is provided as-is, without warranty. The author is not affiliated with Banana Pi, Huawei, Orange France, or any ISP mentioned. Cloning of GPON identity to a non-ISP-provided device may violate your ISP's terms of service in some jurisdictions; verify your specific situation before proceeding. Use of rooted firmware on hardware may void warranties.

This is not legal advice. This is not financial advice. This is, however, a working configuration for a real direct-GPON deployment on a French residential fibre connection.

---

*Contributions welcome. Open an issue or PR with corrections, ISP-specific notes for ISPs other than Orange France, or hardware-specific notes for routers other than BPI-R3.*
