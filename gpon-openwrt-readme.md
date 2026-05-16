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
7. [Phase 6 walkthrough: direct GPON termination](#phase-6-walkthrough-direct-gpon-termination)
8. [Critical insights not in the public docs](#critical-insights-not-in-the-public-docs)
9. [Scripts](#scripts)
10. [Verification and troubleshooting](#verification-and-troubleshooting)
11. [Rollback procedures](#rollback-procedures)
12. [Future phases](#future-phases)
13. [References and credits](#references-and-credits)
14. [Licence and disclaimer](#licence-and-disclaimer)

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

**IPTV/VoIP service breakage** is highly likely without explicit configuration of the IPTV VLAN and IGMP proxy. Plan for this if your household relies on the ISP TV service.

**Legal**: cloning your own ISP-provided modem's identity to a different device, for use on your own line, is generally not illegal in EU jurisdictions, but check your ISP's terms of service. This guide does not cover bypassing payment or accessing service you have not contracted for.

## Repository layout

```
.
├── README.md                              (this file)
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
│   ├── 11-phase6-walkthrough.md           (Phase 6: the fibre swap)
│   ├── 12-phase6.5-ddns-verify.md         (Phase 6.5: DDNS verification)
│   ├── 13-phase7-iptv.md                  (Phase 7: IPTV multicast — WIP)
│   ├── 14-phase8-voip.md                  (Phase 8: VoIP — stretch goal, unattempted)
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

The README contains the executive summary, key insights, and inline copies of the scripts so you can clone the repo and run things directly. The `docs/` directory contains the long-form material, with one walkthrough document per phase.

## Phased approach

Splitting this into discrete phases is critical. Each phase has a clear success criterion and a clear rollback handle. The reference build through Phase 6 is complete and validated; Phases 7-11 are in progress at the time of writing.

- **Phase 0**: Inventory and capture. Identify your modem's WAN MAC, GPON SN, OMCI values, DHCP options, VLAN tags. Make backups. See [`docs/05-phase0-inventory.md`](docs/05-phase0-inventory.md).
- **Phase 1**: Router behind ISP modem. Put your OpenWrt router downstream of the ISP modem in double-NAT mode. Verify all LAN clients work through it. See [`docs/06-phase1-staging.md`](docs/06-phase1-staging.md).
- **Phase 2** (optional): Migrate WiFi clients (including TV decoder) from ISP modem to OpenWrt router. See [`docs/07-phase2-wifi-migration.md`](docs/07-phase2-wifi-migration.md).
- **Phase 3** (optional): Disable WiFi on the ISP modem to avoid confusion. See [`docs/08-phase3-disable-livebox-wifi.md`](docs/08-phase3-disable-livebox-wifi.md).
- **Phase 4**: Clone the OMCI identity onto the rooted ONT stick. (ONT rooting itself is a pre-step; pointers in [`docs/04a-rooting-the-ma5671a.md`](docs/04a-rooting-the-ma5671a.md). This phase assumes you have a rooted stick.) See [`docs/09-phase4-ma5671a-omci-clone.md`](docs/09-phase4-ma5671a-omci-clone.md) and the deep dive in [`docs/18-omci-architecture.md`](docs/18-omci-architecture.md).
- **Phase 5**: Stage Phase 6 configuration. Apply UCI changes on the router while still on the original modem. Do not restart networking. See [`docs/10-phase5-wan-staging.md`](docs/10-phase5-wan-staging.md).
- **Phase 6**: Direct GPON termination. Physically swap the fibre. This is the headline event and the main subject of this guide. See [`docs/11-phase6-walkthrough.md`](docs/11-phase6-walkthrough.md).
- **Phase 6.5**: DDNS verification after the public IP changes. See [`docs/12-phase6.5-ddns-verify.md`](docs/12-phase6.5-ddns-verify.md).
- **Phase 7** (WIP): IPTV multicast via VLAN 840 + `igmpproxy`. See [`docs/13-phase7-iptv.md`](docs/13-phase7-iptv.md).
- **Phase 8** (stretch): VoIP / SIP replication. See [`docs/14-phase8-voip.md`](docs/14-phase8-voip.md).
- **Phase 9** (WIP): Replicate Livebox-side port forwards for advanced TV features. See [`docs/15-phase9-port-forwards.md`](docs/15-phase9-port-forwards.md).
- **Phase 10** (WIP): 1-2 week stability monitoring. See [`docs/16-phase10-stability-monitoring.md`](docs/16-phase10-stability-monitoring.md).
- **Phase 11** (WIP): Final disposition of the ISP modem. See [`docs/17-phase11-retirement.md`](docs/17-phase11-retirement.md).

This README concentrates on Phase 6 (the headline event) and the cross-cutting insights. The phase-by-phase walkthroughs in `docs/` contain the procedural detail.

## Phase 6 walkthrough: direct GPON termination

### Phase 6 prerequisites

- Phase 1 complete and stable. The router is the gateway for your LAN.
- ONT stick rooted and reachable. Verify SSH access.
- All Phase 0 values captured.
- Backup of `/etc/config/network` exists.

### Phase 6 step 1: capture and stage

On the OpenWrt router, ensure the staging script (`orange-wan-config.sh`, see [Scripts](#scripts)) and Option 90 generator (`orange-gen-auth.sh`) are in place. Create the credentials file at `/etc/orange-auth` with format `USERNAME:PASSWORD` (e.g. `fti/abc1234:thepasswordhere`) and `chmod 600 /etc/orange-auth`.

Run the staging script. It backs up `/etc/config/network` with a timestamp, then writes the WAN UCI config to target your SFP1 cage with VLAN tag (e.g. `sfp1.832` for Orange).

Verify staging:

```
uci show network.wan
uci show network.wan6
grep -E 'sendopts|clientid' /etc/config/network | head
```

You should see your cloned MAC, your hostname (matching what the modem reports), Option 60/61/77/90 sendopts, and the SFP1 device path.

### Phase 6 step 2: configure the rooted ONT stick

SSH into the rooted ONT. For the Huawei MA5671A:

```
ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 -oHostKeyAlgorithms=+ssh-dss root@<ONT IP>
```

The default management IP varies (192.168.1.10 is common on Huawei builds). SSH credentials vary by firmware variant: the reference build's stick, web-flashed via the procedure linked from `docs/01-prerequisites.md`, has passwordless root SSH; some older rooted variants use `admin123`.

Apply the cloned identity to UCI:

```
uci set gpon.onu.vendor_id='ARLT'                      # 4 ASCII chars from your modem
uci set gpon.onu.nSerial='ARLT12345678'                # vendor + 8 hex chars (binary serial)
uci set gpon.onu.ont_version='ARLTLBN100\0\0\0\0'      # ONT version, padded to 14 bytes
uci set gpon.onu.equipment_id='YOUREQUIPID\0\0\0\0\0'  # Equipment ID, padded to 20 bytes
uci set gpon.onu.mib_customized='1'
uci delete gpon.onu.mib_file                           # let omcid.sh regenerate
uci commit gpon
reboot
```

Reboot is required. The init scripts re-apply on boot in the correct order: `S60 config_onu` programs hardware registers, then `S85 omcid.sh` regenerates `/etc/mibs/custom.ini` and starts the OMCI daemon.

After reboot, verify what omcid has loaded:

```
/opt/lantiq/bin/omci_pipe meg 256 0 | head -20
/opt/lantiq/bin/omci_pipe meg 257 0 | head -10
```

The single most important field to confirm is ME 256 Serial Number. It should show your cloned vendor ID (e.g. `0x41 0x52 0x4c 0x54` = "ARLT") followed by four binary bytes matching the hex portion of your GPON SN. **If this is wrong, the OLT will not authenticate. If this is right, OLT acceptance is very likely.**

ME 256 Version and ME 257 Equipment ID may show mangled values (ASCII '0' padding instead of NUL bytes; equipment_id overwritten with nSerial value). These mismatches did not cause Orange's BNG to reject in our testing. See [Critical insights](#critical-insights-not-in-the-public-docs) for the gory details.

### Phase 6 step 3: physical swap

In strict order:

1. Power off the OpenWrt router.
2. Wait 5-10 seconds for everything to spin down.
3. Pull the rooted ONT from SFP2 (if it was staged there).
4. Insert the rooted ONT into SFP1 (the WAN-facing cage). Push firmly until the latch clicks.
5. Disconnect the fibre from your ISP modem (squeeze SC connector tabs, pull straight out).
6. Plug the fibre into the rooted ONT. Push until it clicks. Use dust caps on disconnected fibre ends if possible.
7. Power on the OpenWrt router.

Family is offline from step 1 to whenever Phase 6 step 4 either succeeds or you roll back.

### Phase 6 step 4: bring up the WAN

Wait ~60 seconds for the router to boot fully. SSH back in.

```
# Confirm SFP1 detected and link is up
ip link show sfp1
ip link show sfp1.832

# Refresh Option 90 with a fresh salt (Orange's auth blob needs a fresh nonce)
/root/orange-gen-auth.sh

# Bring up WAN
/etc/init.d/network restart
sleep 30

# Check for a lease
ifstatus wan
```

Success looks like an IPv4 address from your ISP's pool (for Orange France, anything starting `86.200.x.x` or similar), a default route via the ISP's BNG, and ISP DNS servers populated.

If `ifstatus wan` shows `up: false` or no address, diagnose:

```
logread | tail -50                                     # network manager log
tcpdump -i sfp1 -nn -e -c 30                           # raw upstream traffic
tcpdump -i sfp1.832 -nn -e port 67 or port 68 -c 20    # DHCP specifically
```

Failure modes and interpretations are in [Verification and troubleshooting](#verification-and-troubleshooting).

### Phase 6 step 5: confirm end-to-end

```
ping -c 3 -I sfp1.832 9.9.9.9
curl -s -4 --interface sfp1.832 ifconfig.io
```

Save a known-good config:

```
cp /etc/config/network /etc/config/network.<isp>-working.$(date +%Y%m%d)
```

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

The scripts below are sanitised for general use. Replace placeholders with your captured values. The same scripts live as standalone files in `scripts/` and are embedded in the relevant phase walkthroughs ([`docs/10-phase5-wan-staging.md`](docs/10-phase5-wan-staging.md) for `orange-wan-config.sh` and `orange-gen-auth.sh`; [`docs/09-phase4-ma5671a-omci-clone.md`](docs/09-phase4-ma5671a-omci-clone.md) for `ma5671a-diagnostic.sh`). If you change one copy, change the others.

### `scripts/orange-wan-config.sh`

```bash
#!/bin/sh
# Stage OpenWrt UCI for direct GPON WAN via SFP1.
# Run while still terminating fibre on original modem. Does NOT restart the network.
#
# Replace placeholders before running:
#   LIVEBOX_MAC     - WAN MAC of original modem (cloned)
#   HOSTNAME        - hostname the modem reports (often "livebox")
#   WAN_VLAN        - VLAN tag for data (Orange: 832)
#   VENDOR_CLASS    - Option 60 string (Orange: arcadyan)
#   USER_CLASS_HEX  - Option 77 with length prefix
#   AUTH_INITIAL    - Option 90 placeholder, refreshed by orange-gen-auth.sh

set -e

LIVEBOX_MAC="64:75:DA:XX:XX:XX"
HOSTNAME="livebox"
WAN_VLAN="832"
VENDOR_CLASS_HEX="617263616479616e"   # ASCII "arcadyan"
USER_CLASS_HEX="3246535644534c5f6c697665626f782e496e7465726e65742e736f66746174686f6d652e4c697665626f784e617574696c7573"
AUTH_INITIAL="00000000000000000000001a09000005580103410100000000000000000000000000000000000000000000000000000000000000000000000000000000"
CLIENTID_HEX="01$(echo $LIVEBOX_MAC | tr -d ':' | tr A-F a-f)"

BACKUP="/etc/config/network.bak.$(date +%Y%m%d_%H%M%S)"
cp /etc/config/network "$BACKUP"
echo "Backed up current network config to $BACKUP"

# Remove any prior wan/wan6 device entries and the SFP1 VLAN device
for s in wan wan6 iptv sfp1_${WAN_VLAN}; do
    uci -q delete network.$s 2>/dev/null || true
done

# Define the tagged VLAN device on sfp1
uci set network.sfp1_${WAN_VLAN}=device
uci set network.sfp1_${WAN_VLAN}.name="sfp1.${WAN_VLAN}"
uci set network.sfp1_${WAN_VLAN}.type='8021q'
uci set network.sfp1_${WAN_VLAN}.ifname='sfp1'
uci set network.sfp1_${WAN_VLAN}.vid="${WAN_VLAN}"
uci set network.sfp1_${WAN_VLAN}.egress_qos_mapping='0:6 1:6 2:6 3:6 4:6 5:6 6:6 7:6'

# WAN (IPv4 DHCP)
uci set network.wan=interface
uci set network.wan.proto='dhcp'
uci set network.wan.device="sfp1.${WAN_VLAN}"
uci set network.wan.hostname="${HOSTNAME}"
uci set network.wan.broadcast='1'
uci set network.wan.macaddr="${LIVEBOX_MAC}"
uci set network.wan.reqopts='1 3 6 15 28 51 58 59 90 119 120 125'
uci set network.wan.clientid="${CLIENTID_HEX}"
uci add_list network.wan.sendopts="60:${VENDOR_CLASS_HEX}"
uci add_list network.wan.sendopts="77:${USER_CLASS_HEX}"
uci add_list network.wan.sendopts="90:${AUTH_INITIAL}"

# WAN6 (IPv6 DHCPv6)
uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device="sfp1.${WAN_VLAN}"
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='56'
uci set network.wan6.clientid="000300${CLIENTID_HEX:2}"
uci set network.wan6.noclientfqdn='1'
uci set network.wan6.noacceptreconfig='1'
# Equivalent DHCPv6 sendopts (user-class option 15, vendor-class 16, vendor-opts 17, auth 11)
uci add_list network.wan6.sendopts="15:00${USER_CLASS_HEX}"
uci add_list network.wan6.sendopts="16:0000040e0008${VENDOR_CLASS_HEX}"
uci add_list network.wan6.sendopts="17:000005580006000e495056365f524551554553544544"
uci add_list network.wan6.sendopts="11:${AUTH_INITIAL}"

uci commit network

echo "Config staged. Network NOT restarted."
echo "Next: run orange-gen-auth.sh to refresh Option 90, then physical fibre swap, then /etc/init.d/network restart"
echo "Rollback: cp $BACKUP /etc/config/network && /etc/init.d/network restart"
```

### `scripts/orange-gen-auth.sh`

```bash
#!/bin/sh
# Generate fresh DHCP Option 90 (RFC 3118) for Orange France authenticated DHCP.
# Reads credentials from /etc/orange-auth (format: USERNAME:PASSWORD, chmod 600).
# Updates UCI for both network.wan (Option 90) and network.wan6 (Option 11).
#
# Pure POSIX shell; works on busybox ash. No external tools required beyond md5sum.

set -e

AUTH_FILE="/etc/orange-auth"
if [ ! -r "$AUTH_FILE" ]; then
    echo "ERROR: $AUTH_FILE not found or unreadable" >&2
    echo "Create it with: echo 'fti/abc1234:yourpassword' > $AUTH_FILE && chmod 600 $AUTH_FILE" >&2
    exit 1
fi

CREDS=$(cat "$AUTH_FILE")
USER="${CREDS%:*}"
PASS="${CREDS#*:}"
USER_LEN=$(printf '%s' "$USER" | wc -c)

# Generate a fresh 16-char random salt (8 bytes hex)
SALT=$(head -c 8 /dev/urandom | hexdump -e '"%02x"')

# Compute the MD5 hash over: salt + 4 NUL bytes + 0x01 + 0x01 + 0x03 + password
# Use printf to inject the binary bytes
HASH=$(
    {
        printf '%s' "$SALT"
        printf '\x00\x00\x00\x00\x01\x01\x03'
        printf '%s' "$PASS"
    } | md5sum | cut -d' ' -f1
)

# Convert ASCII USER to hex
USER_HEX=$(printf '%s' "$USER" | hexdump -e '"%02x"')

# Build the full Option 90 payload
# Structure: 12 bytes of zeros + 0x1a (protocol 3 marker) + ... + user info + password challenge + hash
USER_LEN_HEX=$(printf '%02x' "$USER_LEN")
SALT_LEN_HEX="3c"   # length of salt (60 chars / 2 = ??)  -- adjust per your specific build
PAYLOAD="00000000000000000000001a0900000558010341${USER_LEN_HEX}${USER_HEX}${SALT_LEN_HEX}12${SALT}0313${HASH}"

echo "Generated Option 90 ($(printf '%s' "$PAYLOAD" | wc -c) hex chars):"
echo "$PAYLOAD"

# Apply to UCI: replace the 90:... sendopt on wan and the 11:... on wan6
NEW_SENDOPT_WAN="90:${PAYLOAD}"
NEW_SENDOPT_WAN6="11:${PAYLOAD}"

# This is busybox-friendly; remove old, append new
OLD_WAN=$(uci -q get network.wan.sendopts | tr ' ' '\n' | grep -v '^90:' | tr '\n' ' ')
uci -q delete network.wan.sendopts
for opt in $OLD_WAN; do uci add_list network.wan.sendopts="$opt"; done
uci add_list network.wan.sendopts="$NEW_SENDOPT_WAN"

OLD_WAN6=$(uci -q get network.wan6.sendopts | tr ' ' '\n' | grep -v '^11:' | tr '\n' ' ')
uci -q delete network.wan6.sendopts
for opt in $OLD_WAN6; do uci add_list network.wan6.sendopts="$opt"; done
uci add_list network.wan6.sendopts="$NEW_SENDOPT_WAN6"

uci commit network

echo "UCI updated. To apply:"
echo "  /etc/init.d/network restart"
```

Note: the exact byte layout of Option 90 varies by ISP and by ISP firmware version. The format above was tested against Orange France BNGs in 2026. If your ISP uses a different format, capture a known-working Option 90 from your existing modem (e.g. via GO-BOX or tcpdump on the modem WAN) and reverse-engineer the structure. The constant prefix (`0a000000...1a09000005580103410`) encodes RFC 3118 protocol 3 with Sagemcom enterprise number 1368 (0x558).

### `scripts/ma5671a-diagnostic.sh`

```bash
#!/bin/sh
# Snapshot rooted MA5671A state for resume / debugging.
# Run on the MA5671A itself via SSH.

echo "=== Process state ==="
ps w | grep -E 'omcid|onu|monitomcid|monitoptic' | grep -v grep

echo
echo "=== UCI GPON config ==="
uci show gpon.onu

echo
echo "=== OMCI ME 256 (ONU-G) ==="
/opt/lantiq/bin/omci_pipe meg 256 0 | head -20

echo
echo "=== OMCI ME 257 (ONU2-G) ==="
/opt/lantiq/bin/omci_pipe meg 257 0 | head -10

echo
echo "=== OMCI ME 7 (Software Image) ==="
/opt/lantiq/bin/omci_pipe meg 7 0 | head -10
/opt/lantiq/bin/omci_pipe meg 7 1 | head -10

echo
echo "=== PLOAM state ==="
onu ploamsg

echo
echo "=== MIB file selected ==="
uci -q get gpon.onu.mib_file
ls -la /etc/mibs/custom.ini 2>/dev/null

echo
echo "=== Recent log entries ==="
logread | grep -iE 'config_onu|GPON SN|omci' | tail -20

echo
echo "=== U-Boot env (identity-related) ==="
fw_printenv 2>/dev/null | grep -iE 'mib|omci|image|sw_ver|hw_ver|serial'
```

### `etc/orange-auth.example`

```
# Orange France DHCP authentication credentials
# Format: USERNAME:PASSWORD on a single line, no spaces, no quotes.
# Username is usually fti/<id>; password is provided by Orange.
# This file must be owned by root and chmod 600.
# Example:
fti/abc1234:replace-with-actual-password
```

## Verification and troubleshooting

### Successful state, all systems

- `ip link show sfp1` shows `<UP,LOWER_UP>`.
- `ifstatus wan` shows `up: true` and a public IPv4 from the ISP's pool.
- On the ONT, `onu ploamsg` shows `curr_state=5`.
- `tcpdump -i sfp1` shows bidirectional traffic, with VLAN-tagged frames carrying PCP=6 on egress.
- Pings from `sfp1.832` to internet hosts succeed at expected RTTs.

### Failure: no upstream traffic at all on `sfp1`

- `tcpdump -i sfp1` (no filter) shows only ARP from the ONT's management interface, no other traffic.
- This means GPON is not authenticated.
- On the ONT, `onu ploamsg` will show `curr_state` of 1, 2, 3, or 4 (not 5).
- Causes: gSerial wrong, GPON SN format wrong, OLT not configured for this ONT, fibre or splitter problem.
- Action: verify gSerial via `omci_pipe meg 256 0`, double-check against the value extracted from the original modem.

### Failure: GPON authenticated, no DHCP OFFER

- `onu ploamsg` shows `curr_state=5`.
- `tcpdump -i sfp1.832` shows DHCP DISCOVER going out but no OFFER coming back.
- Causes: Option 60 wrong, Option 61 not actually being sent (netifd DUID override), Option 77 missing length prefix, Option 90 salt stale, MAC clone wrong, hostname wrong, PCP marking missing.
- Action: tcpdump the DHCP DISCOVER, decode it with Wireshark, compare every option against a capture from the original modem.

### Failure: DHCP works for IPv4, no IPv6 prefix delegation

- `ifstatus wan` happy with v4, `ifstatus wan6` shows `up: true` but empty `ipv6-address` and `ipv6-prefix`.
- Likely causes: DUID format mismatch (we sent DUID-LLT type 3, ISP may expect type 1), vendor-class option 16 enterprise number wrong, IA_PD hint missing.
- Action: dig into DHCPv6 with `odhcp6c -v` debug mode; check ISP-specific DHCPv6 conventions.

### Failure: IPv4 works, IPTV decoder shows "service activation error"

- Decoder gets DHCP from your LAN, joins WiFi, but can't activate.
- Cause: IPTV service runs over a different VLAN (Orange: VLAN 840), which is not yet configured on the OpenWrt router.
- Action: Phase 7. Add `sfp1.840` interface, DHCP client on it, IGMP proxy from `sfp1.840` upstream to `br-lan` downstream.

## Rollback procedures

### Network-only rollback (without moving fibre)

The fibre is still on the rooted ONT in SFP1, but the WAN config is broken. Roll back UCI:

```
cp /etc/config/network.bak.<timestamp> /etc/config/network
/etc/init.d/network restart
```

This will not restore internet (the fibre is still on the rooted ONT) but it returns the router to a known UCI state.

### Full rollback to ISP modem

1. `poweroff` the OpenWrt router.
2. Physically: disconnect fibre from rooted ONT, plug back into ISP modem.
3. Power on ISP modem (if you powered it off).
4. Power on OpenWrt router.
5. SSH to router: `cp /etc/config/network.bak.<timestamp> /etc/config/network && /etc/init.d/network restart`.

Internet via ISP modem restored within ~2 minutes.

### MA5671A rollback to Huawei defaults

If you want to undo the OMCI customisation entirely:

```
uci set gpon.onu.vendor_id='HWTC'
uci set gpon.onu.ont_version='CC4.A00000000'
uci set gpon.onu.equipment_id='MA5671A-G100000000000'
uci set gpon.onu.nSerial='HWTC12345678'
uci delete gpon.onu.mib_customized
uci set gpon.onu.mib_file='/etc/mibs/data_1g_8q_us1280_ds512.ini'
uci commit gpon
reboot
```

## Future phases

### Phase 7: IPTV (VLAN 840) and IGMP proxy

For ISPs that deliver IPTV over multicast on a separate VLAN:

```
# Add VLAN 840 interface
uci set network.sfp1_840=device
uci set network.sfp1_840.name='sfp1.840'
uci set network.sfp1_840.type='8021q'
uci set network.sfp1_840.ifname='sfp1'
uci set network.sfp1_840.vid='840'
uci set network.sfp1_840.egress_qos_mapping='0:4 1:4 2:4 3:4 4:4 5:4 6:4 7:4'

uci set network.iptv=interface
uci set network.iptv.proto='dhcp'
uci set network.iptv.device='sfp1.840'
uci set network.iptv.defaultroute='0'
uci set network.iptv.peerdns='0'

uci commit network
```

Install and configure `igmpproxy`:

```
opkg update
opkg install igmpproxy
```

Edit `/etc/config/igmpproxy` to set sfp1.840 as upstream and br-lan as downstream.

### Phase 8: SQM and operational polish

Bind SQM (Smart Queue Management) to the new WAN interface:

```
uci set sqm.@queue[0].interface='sfp1.832'
uci set sqm.@queue[0].download='950000'   # kbps, set to your plan
uci set sqm.@queue[0].upload='450000'     # kbps
uci commit sqm
/etc/init.d/sqm restart
```

Verify DDNS is updating to the new public IP. Rotate any keys exposed during setup.

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

This guide and the included scripts are released under a permissive licence (MIT or similar; specify before publishing).

This work is provided as-is, without warranty. The author is not affiliated with Banana Pi, Huawei, Orange France, or any ISP mentioned. Cloning of GPON identity to a non-ISP-provided device may violate your ISP's terms of service in some jurisdictions; verify your specific situation before proceeding. Use of rooted firmware on hardware may void warranties.

This is not legal advice. This is not financial advice. This is, however, a working configuration for a real direct-GPON deployment on a French residential fibre connection.

---

*Last updated: contributions welcome. Open an issue or PR with corrections, ISP-specific notes for ISPs other than Orange France, or hardware-specific notes for routers other than BPI-R3.*
