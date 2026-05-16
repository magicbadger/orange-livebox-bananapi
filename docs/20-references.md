# 20 — References, tools, and credits

A consolidated list of where to look for further information, what tools to have to hand, and acknowledgements for prior work this guide builds on.

## Software and tools used in this project

### On the OpenWrt router

- **OpenWrt** — the base operating system. <https://openwrt.org>. This guide tested with 25.12.2.
- **udhcpc / odhcp6c** — default DHCPv4 and DHCPv6 clients (busybox). Sufficient with the right UCI options.
- **netifd** — OpenWrt's network interface manager. Read its UCI documentation carefully; some options behave non-obviously (Option 61 → DUID override).
- **fw3 / nftables** — OpenWrt's firewall manager. Used for port forwards (Phase 9), zone rules, IGMP rules (Phase 7).
- **tcpdump-mini** — `opkg install tcpdump-mini` or `apk add tcpdump-mini`. Essential for diagnosing DHCP issues. The mini variant is smaller; the full `tcpdump` works equally well.
- **igmpproxy** — multicast forwarding for IPTV (Phase 7).
- **ddns-scripts** + provider-specific scripts — DDNS updates. Plus your provider's API documentation (Gandi LiveDNS, Cloudflare, etc.).
- **sqm-scripts** + `luci-app-sqm` — traffic shaping. `cake` qdisc is the modern choice.

### On the MA5671A

Provided by the rooted firmware; no installation needed:

- **BusyBox** — `ash`, `sed`, `grep`, `printf`, `hexdump`, `md5sum`, `wc`, `tr`, etc.
- **uci** — OpenWrt config.
- **fw_printenv / fw_setenv** — U-Boot environment.
- **/opt/lantiq/bin/omcid** — OMCI daemon.
- **/opt/lantiq/bin/omci_pipe** — OMCI MIB inspection.
- **/opt/lantiq/bin/config_onu** — programs hardware identity registers (has known bugs; see [`18-omci-architecture.md`](18-omci-architecture.md)).
- **/opt/lantiq/bin/onu** — Intel/Lantiq Falcon GPON control. `onu ploamsg` is the key diagnostic.
- **/opt/lantiq/bin/sfp_i2c** — SFP I2C EEPROM access.

### On the workstation

- **SSH client** — macOS Terminal, Linux, or Windows + WSL/PuTTY. Recent OpenSSH may need explicit legacy KEX/HostKey flags to talk to the MA5671A.
- **tcpdump / Wireshark** — packet inspection. Wireshark's DHCP dissector is what makes reverse-engineering Option 90 tractable.
- **scp / rsync** — file transfer to/from the router.
- **A text editor that handles long lines** — DHCP Option hex strings are long.

### Reverse-engineering aids

- **GO-BOX** — diagnostic tool for extracting GPON / OMCI / DHCP fields from Sagemcom Livebox devices over the Livebox's diagnostic protocol. The fastest way to capture Orange France Livebox config. Search "GO-BOX livebox" on hack-gpon-related forums; distribution is community-mediated.
- **kgersen's Option 90 generator** — historical reference implementation of RFC 3118 for Orange France's authenticated DHCP. Useful as a cross-check when writing your own (`orange-gen-auth.sh` is a re-implementation that runs on busybox).
- **`strings <binary>`** — primary tool for understanding undocumented binaries on the MA5671A.

## Research sources

### hack-gpon.org

The authoritative community site for rooting GPON SFP modules, OMCI identity cloning, and OLT vendor specifics. Articles on:

- The "fake O5 status" trap (LOWER_UP doesn't mean GPON authenticated)
- Cloning identity across vendor-OLT pairs
- Rooting procedures for MA5671A, FS sticks, Carlito-modded sticks, SourcePhotonics
- OLT-side enforcement variations across Huawei, Nokia, ZTE, Calix

Specifically used for the reference build:

- **MA5671A overview**: <https://hack-gpon.org/ont-huawei-ma5671a/> — hardware, firmware variants, capability summary. Start here for context.
- **MA5671A web-root walkthrough**: <https://hack-gpon.org/ont-huawei-ma5671a-root-web/> — the in-browser rooting procedure for an unrooted stock-firmware stick. Used together with the tvi.al SFP-to-TTL adapter in the reference build. The resulting firmware has passwordless root SSH (no `admin123`).

If you're new to direct GPON termination, read the hack-gpon primer before this guide.

### OpenWrt forum threads

- "Bridging Livebox" threads — multiple, covering Orange France specifics
- BPI-R3 SFP threads — confirm SFP-via-mdio support, kernel driver status
- DHCP option encoding threads — `sendopts`, `clientid`, `reqopts` interactions

Search `forum.openwrt.org` for current threads; specific URLs go stale.

### lafibre.info

French-language community focused on fibre and ISP specifics in France. Deep knowledge of Orange France, Free, Bouygues, SFR. Topics:

- Authentified DHCP on Orange France (Option 90 RFC 3118)
- VLAN tagging per ISP
- IPTV multicast configurations
- Voltage / signal level expectations for FTTH
- SFP GPON stick rooting via the SFP-to-TTL adapter + web-page flash workflow

The forum is the right place for ISP-side debugging questions if hack-gpon's general guidance doesn't apply to your specific provider.

Companion article used alongside the hack-gpon walkthrough: <https://lafibre.info/materiel-informatique/adaptateur-sfp-to-ttl-v1-1-pour-flasher-vos-modules-gpon-fibre/> — French-language coverage of the same tvi.al SFP-to-TTL adapter with hardware photos and pinout. The hack-gpon links (under "hack-gpon.org" above) are the canonical rooting procedure; this lafibre.info article is supplementary context.

### Intel/Lantiq Falcon SoC

The GPON MAC on the MA5671A is an Intel/Lantiq Falcon (acquired by MaxLinear, then various rebrandings). Some technical detail is available in:

- Publicly archived datasheets (search engine queries for "Intel Falcon GPON datasheet")
- The Intel/Lantiq Linux driver source in the kernel mainline (`drivers/net/ethernet/lantiq/...` and related; not all relevant code is upstream)
- Patents and academic publications referencing the Falcon block

For our purposes (overriding ME 256/257 register addresses), none of this has been sufficient. If you find authoritative register-address documentation, this guide would benefit.

## Standards and RFCs

- **RFC 2131** — DHCP. The base. <https://datatracker.ietf.org/doc/html/rfc2131>
- **RFC 3004** — DHCP User Class option (Option 77). <https://datatracker.ietf.org/doc/html/rfc3004>
- **RFC 3118** — Authentication for DHCP. Orange France uses protocol 3 (delayed authentication). <https://datatracker.ietf.org/doc/html/rfc3118>
- **RFC 3315** (obsoleted by RFC 8415) — DHCPv6. <https://datatracker.ietf.org/doc/html/rfc8415>
- **ITU-T G.984** series — GPON. The physical and MAC layer.
- **ITU-T G.988** — OMCI. Managed Entity definitions including ME 256 (ONU-G), ME 257 (ONU2-G), ME 7 (Software Image). The R/W flags per attribute are defined here.
- **IEEE 802.1Q** — VLAN tagging.
- **IEEE 802.1p** — priority code points (the PCP field).

The ITU-T documents are paywalled but draft versions and large excerpts are widely available via academic search.

## Communities

- **OpenWrt forum** — <https://forum.openwrt.org>. General OpenWrt help, detailed troubleshooting, device-specific advice.
- **hack-gpon** — discord / forum / wiki. GPON SFP rooting and OMCI work.
- **lafibre.info** — French ISP specifics.
- **Reddit r/openwrt, r/HomeNetworking** — broader audience, less specialised but sometimes useful for sanity checks.
- **Banana Pi forums** — <https://forum.banana-pi.org>. Hardware-specific BPI-R3 questions.
- **Discord servers** — various, including `#openwrt` on Libera Chat IRC. Real-time help when forums are slow.

## Hardware suppliers (reference)

Not endorsements, just where we sourced parts for the reference build:

- **Banana Pi BPI-R3** — direct from SinoVoip's online shop, also available via AliExpress and Amazon resellers.
- **Huawei MA5671A (pre-rooted)** — community-trusted sellers on hack-gpon; some AliExpress vendors. Avoid generic "Huawei MA5671A" listings without root confirmation, you'll spend a weekend rooting.
- **DSD TECH SH-U09C5 UART adapter** — Amazon, ~€15. FTDI FT232RL chipset is the part to look for; avoid CH340-based clones.
- **SFP-to-TTL adapter** — the small purpose-built board used in the reference build, available from <https://tvi.al/sfp-to-ttl-adapter/>. Exposes the MA5671A's UART pins on a USB-friendly header so you can flash the stick without soldering. Roughly €15-25. The lafibre.info article under "Research sources" walks through using it.

## Credits

This guide builds on:

- **The hack-gpon community** for the foundational research on rooting MA5671A and OMCI identity cloning.
- **kgersen** and the lafibre.info community for the Orange France Option 90 generator concept and the multi-year reverse-engineering of Orange's authenticated DHCP.
- **Orange France subscribers** who have documented Livebox firmware behaviour over multiple Livebox generations on lafibre.info.
- **The OpenWrt project** for the foundation everything else builds on.

The specific empirical work on `config_onu` mangling bugs and the ZZZZ MIB-file test was done as part of this project; if you build on it, attribute back to this guide.

## Versioning of this guide

The reference setup uses values valid as of 2026. Some specifics will date:

- Orange France firmware revisions on the Livebox change Option 60/77 strings infrequently but not never.
- The MA5671A firmware variant landscape shifts as new community-distributed builds emerge.
- OpenWrt syntax and package names evolve.

When something stops working, first check this guide's "Last updated" date against today. If significantly out of date, search the active forums and supplement.

## Contributing back

This guide is intentionally self-contained but missing many things:

- Other ISPs (the framework would adapt; specifics need capture)
- Other GPON SFP modules (FS, Carlito, SourcePhotonics)
- Other routers with SFP cages (BPI-R4, MikroTik CRS series, Turris Omnia + SFP add-on)
- VoIP credential extraction approaches that actually work

If you complete Phase 7 / Phase 8 and document them properly, or if you adapt this for another ISP, a write-up or PR is welcomed. Contact via the repository if hosted on GitHub or similar.
