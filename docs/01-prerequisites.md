# 01 — Prerequisites

What you need before starting the migration. The README has a condensed version of this; this document is the long form.

## Hardware

### Router

An OpenWrt-capable router with at least one SFP cage. Two cages is significantly better: you can stage the rooted ONT in the second cage and talk to it over SSH without disturbing the live service on the first.

The reference build for this guide uses a Banana Pi BPI-R3. Details specific to that hardware are in [`02-bpi-r3-specifics.md`](02-bpi-r3-specifics.md). Other supported boards include the BPI-R4, Turris Omnia (with SFP add-on), and various MikroTik units; the SFP-on-mdio support story varies and is best verified against current OpenWrt device pages before buying.

Minimum:

- One SFP cage with confirmed SFP-via-mdio support in your OpenWrt build (the SFP module needs an exposed netdev like `sfp1`)
- 256 MB RAM, 128 MB storage (more if you want to run extras like AdGuard Home, Jellyfin)
- Gigabit ethernet for LAN
- Wired serial console pads on the board (optional but strongly recommended)

### GPON SFP stick

A rooted ONT-on-SFP module compatible with your ISP's OLT vendor. The reference build uses a Huawei MA5671A. Other options:

- **Huawei MA5671A** — most common, OEM rooted with various firmware variants. The variant this guide describes ships with an OpenWrt 14.07 base, BusyBox userland, Intel/Lantiq Falcon GPON SoC, and a small set of `omcid` / `config_onu` / `onu` binaries from Huawei.
- **FS-modded sticks** (e.g. FS GPON ONT-SFP) — different firmware, different command set.
- **Carlito-modded sticks** — community-rooted, again different binaries.
- **SourcePhotonics SOG-4321** — another option, less common.

The OMCI cloning steps in this guide work specifically with the Huawei MA5671A variant. The general principles transfer, but expect command names and config paths to differ on other sticks.

### Procurement and rooting for the reference build

The MA5671A in the reference build was bought from an AliExpress seller at a low price (no specific seller endorsed; listings come and go). The stick shipped with stock Huawei firmware and was rooted in-house using the hack-gpon.org web-flash procedure, with a third-party SFP-to-TTL adapter for UART access.

See [`04a-rooting-the-ma5671a.md`](04a-rooting-the-ma5671a.md) for hardware needed, the canonical procedure references (hack-gpon.org), what "rooted" looks like once done, and failure modes the reference build actually hit. That document is a pointer to authoritative external guides, not a duplicated procedure.

Once rooted, the variant from this procedure has **passwordless root SSH**. Some other rooted firmware variants in circulation use `admin123`; either way, set a password with `passwd` on first login if the stick will sit on a routed segment.

### Fibre infrastructure

- Existing SC/APC (or your ISP's connector) fibre patch from the ONT to the ODF/wall plate
- The ability to disconnect/reconnect the fibre safely (handle SC/APC tabs gently, never look into the bare connector, keep dust caps to hand)
- The original ISP modem/router available as a fallback for the entire procedure

### Tools

- USB-to-UART adapter for the router serial console (3.3V TTL). DSD TECH SH-U09C5 with FT232RL is a known-good cheap option. Strongly recommended in case SSH dies during configuration.
- USB-to-UART adapter or purpose-built SFP-to-TTL adapter board for the SFP stick — only required if you're rooting the stick yourself. The reference build used the board from <https://tvi.al/sfp-to-ttl-adapter/>; details and walkthrough under "Procurement and rooting for the reference build" below.
- A Mac/Linux workstation with SSH, `tcpdump`, ideally Wireshark.
- Smartphone with mobile data, set up as a personal hotspot, for emergency connectivity while debugging.

## Software

### On the router

- OpenWrt 22.03 or later. This guide was developed against 25.12.
- `udhcpc` (busybox default) for IPv4 DHCP; `odhcp6c` for IPv6 (both default).
- `tcpdump` (`opkg install tcpdump-mini`, or `apk add tcpdump-mini` on apk-based snapshots).
- `igmpproxy` for IPTV (Phase 7).
- `kmod-ipt-nat6` for IPv6 NAT (optional, depends on your topology).
- `luci-app-sqm` and `sqm-scripts` if you want traffic shaping.

### On the workstation

- SSH client. macOS, Linux, or Windows with WSL/PuTTY.
- `tcpdump` or Wireshark for packet inspection. Essential if you need to reverse-engineer ISP DHCP options.

### On the SFP stick (Huawei MA5671A reference)

What ships with the rooted firmware:

- BusyBox userland (`ash`, `sed`, `grep`, `cat`, `cut`, `head`, `tail`, `wc`, `tr`, `md5sum`, `hexdump`).
- `fw_printenv`/`fw_setenv` for U-Boot environment access.
- `uci` for OpenWrt-style config.
- Huawei/Lantiq binaries in `/opt/lantiq/bin/`: `omcid`, `omci_pipe`, `config_onu`, `onu`, `sfp_i2c`.
- Init scripts under `/etc/init.d/` and `/etc/rc.d/`.

You should not need to install anything on the stick. If you do, you'll have to cross-compile against a 14.07 toolchain, which is painful; avoid it.

## Information you must capture from the existing modem

Before any swap, capture from the ISP-supplied modem:

### Identity (mandatory)

- **WAN-side MAC address** of the modem
- **GPON Serial Number** (4-char vendor prefix + 8 hex chars, e.g. `ARLT12345678`)
- **OMCI Vendor ID** (4 ASCII chars, often matches GPON serial prefix, e.g. `ARLT`)
- **OMCI Equipment ID** (up to 20 chars, e.g. `PRV33AX346B0000`)
- **OMCI Hardware Version / ONT Version** (up to 14 chars, e.g. `ARLTLBN100`)

### Identity (optional but worth capturing)

- OMCI Software image versions 0 and 1 (e.g. `SAHNOFR010216`, `SAHNOFR010601`)
- Which software image is active
- ONT manufacturer/model strings the modem reports

### Network configuration (mandatory)

- VLAN ID for data (Orange France: 832)
- VLAN ID for IPTV (Orange France: 840; uses multicast)
- VLAN ID for VoIP (Orange France: 832, same as data)
- VLAN priority (PCP) for each VLAN
- DHCP authentication scheme: bare DHCP, PPPoE, or RFC 3118 authenticated DHCP
- DHCP options the modem sends (Option 60 vendor class, Option 61 client ID, Option 77 user class, Option 90 auth)
- DHCPv6 options and DUID format
- IPv6 prefix size (PD; Orange: /56)

### Credentials (mandatory if your ISP uses authenticated DHCP)

- Username (Orange France: `fti/...`)
- Password (paper documentation or ISP-provided app)

### Service configuration (optional)

- Static lease for the IPTV decoder
- Any port-forwarding rules running on the modem
- DDNS or static IP requirements
- SIP credentials for VoIP if you intend to replicate the phone line

### How to capture

The cleanest tool for Orange France Liveboxes is **GO-BOX**, which speaks the Livebox's diagnostic protocol and dumps all the OMCI/DHCP fields. Search "GO-BOX livebox" on hack-gpon forums.

Generic approaches:

- **The modem's admin web UI** exposes some fields directly. On Orange France, look under "Information système" or similar.
- **`tcpdump` on a SPAN port** between the modem and the OLT captures real DHCP options on the wire. Some routers can be configured as a transparent bridge for this.
- **Reading the modem's NVRAM** if you can pull the device apart non-destructively. Not generally needed if GO-BOX is available.

## Skills

You should be comfortable with:

- OpenWrt UCI configuration and `/etc/config/` files
- Editing init scripts and shell scripts in busybox `ash`
- Reading and interpreting `logread` and kernel `dmesg` output
- Reading raw `tcpdump` output for DHCP/DHCPv6 packets (or transferring captures to Wireshark)
- DHCP option encoding in hex (`hexdump`, `printf`)
- 802.1Q VLAN tagging and 802.1p priority code points
- GPON activation states (PLOAM O1-O5) at a conceptual level
- Reading `strings` output from binaries when documentation is missing

If you've never done any of these, this is a steep learning curve. Read [`03-ma5671a-specifics.md`](03-ma5671a-specifics.md) and [`18-omci-architecture.md`](18-omci-architecture.md) end-to-end before touching anything live.

## Time and downtime budget

First time, end-to-end:

- **Phase 0** (inventory and backup): 1-2 hours
- **Phase 1** (router behind modem): 30-60 minutes
- **Phase 4** (OMCI clone): 1-2 hours if everything goes well, multi-evening if you need to investigate the firmware
- **Phase 5** (stage WAN config): 30-60 minutes
- **Phase 6** (fibre swap): 30 minutes to many hours depending on whether DHCP succeeds first try
- **Phase 7** (IPTV): 1-2 hours
- **Phase 9** (port forwards): 30 minutes

Realistic total: 2-4 evenings of 2-3 hours each, spread over a week. Don't try to do this in a single sitting.

Per-swap downtime: 2-5 minutes for the physical swap and `network restart`. If DHCP fails, you'll either iterate (more downtime) or roll back (immediate restoration). Plan attempts when household demand for internet is low.

## Risk: keep the ISP modem available

Throughout every phase, the original ISP modem must remain plugged in, plugged into mains, and capable of taking the fibre back. Internet restoration is "fibre back to ISP modem, power it on, wait 90 seconds" — under two minutes — but only if the modem hasn't been packed away. Box it up only after Phase 10 stability monitoring is complete.
