---
title: BPI-R3 specifics
nav_order: 2
---

# 02 — Banana Pi BPI-R3 specifics

Notes that apply specifically to the reference hardware. If you're using a different router, skip to [`03-ma5671a-specifics.md`](03-ma5671a-specifics.md) and adapt the SFP cage naming as you go.

## Hardware overview

The BPI-R3 is a MediaTek MT7986-based router with:

- 2 GB DDR4 RAM
- 8 GB eMMC (preferred boot target), MicroSD slot, NAND, 128 MB SPI-NOR
- 2 x SFP+ cages (`sfp1` and `sfp2`, both 2.5 Gbit-capable)
- 1 x 2.5 GbE WAN copper port (`wan`)
- 4 x 1 GbE LAN copper ports
- Built-in MediaTek WiFi 6 radios (2.4 GHz `radio0` and 5 GHz `radio1`)
- M.2 slot for NVMe SSD (PCIe x1) on later board revisions
- USB 3.0
- Serial console pads on the board, exposed via a 4-pin header

The two SFP cages and the optional NVMe make it well-suited to a "everything in one box" router, ISP termination, light NAS role.

## Boot media: which to use

The board can boot from MicroSD, NAND, eMMC, or SPI-NOR depending on the boot-strap DIP switches. For a production install the recommended order is:

1. Boot from MicroSD with a fresh OpenWrt image. This is your bring-up environment.
2. From the running OpenWrt, write an OpenWrt eMMC image to `/dev/mmcblk0`.
3. Flip the boot switches to eMMC. Reboot.

eMMC is faster, more durable than SD, and the 8 GB capacity is plenty for OpenWrt plus AdGuard Home plus Jellyfin. NAND is older/slower; SPI-NOR is too small for anything useful.

OpenWrt's BPI-R3 device page has the current switch positions and image links: <https://openwrt.org/toh/sinovoip/bananapi_bpi-r3>.

## SFP cages: how they appear in OpenWrt

In recent OpenWrt builds (22.03+), the two SFP cages appear as dedicated netdevs:

- `sfp1` — the right-hand cage as you look at the front panel. **Use this for the WAN-side ONT** (the cage closer to the WAN port is conventionally the WAN cage).
- `sfp2` — the left-hand cage. Convenient as a staging slot for the rooted ONT while the live service is still on the original modem.

You can verify with:

```
ip link show
ls /sys/class/net/
```

Both cages support 2.5GBASE-X and 1000BASE-X (and SGMII to copper modules). For GPON modules, the SFP module itself does the GPON termination and presents a generic ethernet PHY to the host. The SFP+MDIO support in OpenWrt for MT7986 is mature; you should not need any kernel patches.

The SFP cage netdev shows `<UP,LOWER_UP>` when the SFP module is electrically connected and the host SerDes link is up. **This says nothing about whether the GPON link to your ISP is up.** PLOAM state is reported by the ONT itself; see [`03-ma5671a-specifics.md`](03-ma5671a-specifics.md) and [`19-troubleshooting.md`](19-troubleshooting.md).

## OpenWrt version

This guide was developed against OpenWrt 25.12.2 stable. Earlier 22.03 should work but the `apk` package manager replaced `opkg` somewhere along the way; commands here use whichever was current. Translate as needed:

- `opkg update && opkg install igmpproxy` (22.03 era)
- `apk update && apk add igmpproxy` (24.10+ era)

## Default LAN

OpenWrt ships with LAN on `192.168.1.0/24` and the router at `192.168.1.1`. Most ISP modems also default to `192.168.1.0/24`. **You will need to change one of them before connecting them in series in Phase 1.** This guide expects the BPI-R3 to keep `192.168.1.0/24` and the ISP modem to move to a different range (e.g. `192.168.10.0/24` or `192.168.2.0/24` if `192.168.10.x` is already in use elsewhere).

## Serial console (recommended)

The BPI-R3 has a 4-pin UART header on the board. Pinout (with the board oriented so the SFP cages face you):

```
GND  TX  RX  3.3V
```

Connect a 3.3V USB-to-UART adapter:

- Adapter GND → BPI-R3 GND
- Adapter RX → BPI-R3 TX
- Adapter TX → BPI-R3 RX
- Do **not** connect 3.3V from the adapter; the board is powered separately.

Settings: 115200 baud, 8N1, no flow control. From macOS:

```
ls /dev/cu.usbserial-*
screen /dev/cu.usbserial-XXXXXXXX 115200
```

The console gives you U-Boot prompts at boot and a login shell after OpenWrt starts. Essential if you misconfigure networking and lock yourself out via SSH.

The DSD TECH SH-U09C5 (FT232RL) is a known-good adapter. Avoid CH340-based clones; they sometimes drop bytes at 115200.

## SFP2 as staging slot

The recommended workflow during Phase 4 (OMCI clone) and Phase 5 (WAN staging):

1. Leave fibre on the ISP modem; family internet is live.
2. Put the rooted SFP stick in `sfp2`.
3. Bring `sfp2` up in OpenWrt with a static IP on the management subnet (the rooted Huawei firmware defaults its management address to `192.168.1.10`; adjust accordingly, or move it).
4. SSH into the SFP stick via the management interface. Do your OMCI work.

When ready for Phase 6:

1. Power off the BPI-R3.
2. Move the rooted SFP stick from `sfp2` to `sfp1`.
3. Move the fibre from the ISP modem to the rooted SFP stick.
4. Power on. The WAN config you staged in Phase 5 takes effect.

## Useful BPI-R3 commands

```
# Current LAN address and routes
ip addr show br-lan
ip route

# WAN status
ifstatus wan
ip addr show sfp1
ip addr show sfp1.832

# SFP1 module diagnostics
ethtool sfp1
ethtool -m sfp1     # SFP EEPROM (vendor, serial, optical signal levels)

# Multicast/IGMP state (Phase 7)
ip mroute
cat /proc/net/igmp

# Kernel and driver log
dmesg | grep -iE 'sfp|gpon|mt798'
```

## Known quirks

- **WPS + `wpad-basic-mbedtls` is a silent failure**. If you enable WPS on any SSID and the system uses `wpad-basic-mbedtls`, `hostapd` silently fails to bring up that radio. Symptom: `radio0` reports up in UCI but no SSID broadcasts. Fix: install `wpad-openssl` (replace, don't install alongside).
- **SQM `cake` is the right qdisc**. fq_codel works but cake handles ATM/PPPoE overheads cleanly. After Phase 6 it should be bound to `sfp1.832` rather than the previous `wan` interface.
- **Hardware offload (HWNAT)**. The MT7986 supports flow offload. Verify it's enabled in `/etc/config/firewall` (`flow_offloading 1`) if you want to push the full plan throughput. With offload and a 1 Gbit Orange plan, the BPI-R3 idles around 5-10% CPU under full load.
