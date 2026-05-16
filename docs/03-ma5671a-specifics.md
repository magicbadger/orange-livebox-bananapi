# 03 — Huawei MA5671A specifics

The MA5671A is a GPON SFP stick originally sold as a customer-premises ONT for B2B applications. The community has rooted several firmware variants. This guide describes the variant most commonly distributed by hack-gpon-community-trusted sellers: a Huawei stock firmware on an OpenWrt 14.07 base, with SSH access enabled and the management interface bound to `192.168.1.10`.

If your stick was rooted from a different source you may find different command sets and different config paths. The general architecture below should still apply.

## Hardware

- Intel/Lantiq Falcon SoC (PXB GPON MAC + MIPS CPU). The Falcon was Intel's reference GPON design before they sold the line to MaxLinear.
- 1 Gbit GPON upstream and downstream
- SFP form factor with SC/APC fibre receptacle
- 3.3V management interface via the SFP I2C bus (used for `sfp_i2c` writes to OMCI EEPROM-mapped fields)
- Runs hot. A small passive heatsink is strongly recommended; many vendors ship one in the box.

## Firmware overview

The rooted variant exposes:

- BusyBox userland on OpenWrt 14.07 base
- Dropbear SSH on TCP/22. **SSH credentials vary by firmware variant**: the web-flashed variant used in the reference build (see [`01-prerequisites.md`](01-prerequisites.md)) has passwordless root login. Some older community-rooted variants use `root` / `admin123`. Set a password with `passwd` on first login if the stick will sit on a routed segment.
- Default management IP `192.168.1.10/24` on the SFP module's ethernet side
- U-Boot environment accessible via `fw_printenv` / `fw_setenv`
- Huawei/Lantiq vendor binaries under `/opt/lantiq/bin/`:
  - `omcid` — the OMCI daemon
  - `omci_pipe` — CLI for inspecting and (sometimes) modifying the OMCI MIB
  - `config_onu` — programs hardware identity registers from UCI
  - `onu` — Intel/Lantiq Falcon control binary, ~306 subcommands
  - `sfp_i2c` — writes to the SFP I2C EEPROM (decorative for OMCI identity, used by some OLTs that read SFP MSA data)
- Init scripts in `/etc/init.d/` and symlinked into `/etc/rc.d/Snn*` for boot ordering
- MIB definition files in `/etc/mibs/`

## SSH access

The Dropbear build is old enough to need legacy KEX and hostkey algorithms. From a modern OpenSSH client:

```
sudo arp -d 192.168.1.10 2>/dev/null    # clear stale ARP if you've moved the stick
ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 \
    -oHostKeyAlgorithms=+ssh-dss \
    root@192.168.1.10
```

Password prompt behaviour depends on the firmware variant. The web-flashed variant used in the reference build (see [`01-prerequisites.md`](01-prerequisites.md) for the procedure) accepts root with no password; other rooted variants commonly prompt and accept `admin123`. If you didn't flash the stick yourself, try empty first, then `admin123`. Set a real password with `passwd` after first login.

For repeat access, drop the legacy flags into `~/.ssh/config`:

```
Host ma5671a
    HostName 192.168.1.10
    User root
    KexAlgorithms +diffie-hellman-group1-sha1
    HostKeyAlgorithms +ssh-dss
```

## Boot order and init scripts

The interesting init scripts (paths in `/etc/init.d/`, with their `S` priorities from `/etc/rc.d/`):

| Priority | Script | What it does |
|---------:|--------|--------------|
| `S60` | `config_onu` | Reads UCI keys (`gpon.onu.*`) and programs hardware identity registers in the GPON MAC. |
| `S61` | `onu.sh` | Brings up the GPON physical interface. |
| `S62` | `sfp_eeprom.sh` | Initialises the SFP I2C EEPROM. |
| `S85` | `omcid.sh` | Generates `/etc/mibs/custom.ini` (if customisation is enabled), starts `omcid`. |
| `S97` | `monitomcid` | Watchdog for `omcid`; restarts it if it dies. |
| `S99` | `setserial` (`S99setserial`) | Writes SFP I2C EEPROM identity fields via `sfp_i2c`. |

The order matters: `config_onu` programs the hardware registers **before** `omcid` runs. `omcid` reads ME 256/257 identity from those registers at start-up, not from the MIB file. See [`18-omci-architecture.md`](18-omci-architecture.md) for the full architecture.

## UCI: the keys that matter

```
uci show gpon.onu
```

The keys that drive identity:

- `gpon.onu.vendor_id` — 4 ASCII characters, the OMCI Vendor ID and the first 4 bytes of the GPON Serial Number.
- `gpon.onu.nSerial` — full GPON Serial Number, 4 ASCII vendor prefix + 8 hex characters. `config_onu` parses this and writes the 8-byte ME 256 Serial Number attribute (4 ASCII bytes + 4 binary bytes).
- `gpon.onu.equipment_id` — up to 20 chars, the OMCI Equipment ID (ME 257 attribute 1).
- `gpon.onu.ont_version` — up to 14 chars, the OMCI ONT Version (ME 256 attribute 2).
- `gpon.onu.mib_customized` — `1` to enable custom MIB generation, otherwise the stock MIB is used.
- `gpon.onu.mib_file` — path to MIB file. **This is a trap key**: see [`18-omci-architecture.md`](18-omci-architecture.md). Set to a path containing `custom.ini` or delete it.

Less important (decorative or vendor-only):

- `gpon.onu.gSerial` — older variants used this; the newer firmware uses `nSerial`.
- `gpon.onu.password` — OMCC password for OLT registration. Some ISPs use this, most don't.
- `gpon.onu.omcc_version` — protocol version for OMCC. Default 160 (HWTC mode) works for Orange France.

## OMCI inspection: `omci_pipe`

`omci_pipe` is the CLI for talking to the OMCI MIB held in `omcid`'s memory:

```
# Get all attributes of a Managed Entity instance
/opt/lantiq/bin/omci_pipe meg <class> <instance>

# Get a single attribute (1-indexed)
/opt/lantiq/bin/omci_pipe meadg <class> <instance> <attr_num>

# Set an attribute (1-indexed, bytes as 0xNN or NN, one per argv)
/opt/lantiq/bin/omci_pipe meads <class> <instance> <attr_num> <byte> [<byte>...]
```

The MEs that matter for ISP identity:

| ME class | Name | Key attributes |
|---------:|------|----------------|
| 7 | Software Image | Version (per-instance, two instances 0 and 1) |
| 256 | ONU-G | Vendor ID (attr 1), Version (attr 2), Serial Number (attr 3) |
| 257 | ONU2-G | Equipment ID (attr 1), plus a bunch of capability attrs |

### `meg` vs `meads` attribute numbering

A subtle annoyance: `meg` displays attributes 0-indexed (so "0 Vendor id, 1 Version, 2 Serial Number..."), but `meads` takes attributes 1-indexed (so attr 1 = Vendor id, attr 2 = Version). Translate when scripting against the output of one for input to the other.

### Read-only enforcement on `meads`

`meads` enforces OMCI R/W flags. Writes to read-only attributes return `errorcode=-14` regardless of syntax. Vendor ID, Version, and Equipment ID are all read-only at the OMCI layer, so you cannot override them from `omci_pipe`. They must be programmed at the register level via `config_onu` (which reads UCI), or at the raw register level via `onu onurs`.

### `omci_pipe` and the MIB file

`omcid` reads most ME data from a MIB definition file at startup. The path is decided by branches in `omcid.sh` at boot time. But **ME 256 and ME 257 identity attributes are read from hardware registers, not from the MIB file.** Editing the MIB file has no effect on the OMCI report of those fields. See the ZZZZ test in [`18-omci-architecture.md`](18-omci-architecture.md) for the experimental evidence.

## The `onu` binary

```
/opt/lantiq/bin/onu <subcommand> [args...]
```

Approximately 306 subcommands. The ones that come up:

- `onu ploamsg` — show the PLOAM state. The single most important diagnostic for "is the GPON link up?".
  - `curr_state=1` → O1 (initial; no downstream signal)
  - `curr_state=2` → O2 (standby; downstream seen, no ranging)
  - `curr_state=3` → O3 (serial number ranging in progress)
  - `curr_state=4` → O4 (ranging in progress)
  - `curr_state=5` → O5 (operational; PLOAM authenticated, ready for OMCI)
- `onu onurs <addr> <bytes>` — raw register write. Potential escape hatch for overriding identity registers; needs register address documentation that we have not located.
- `onu onutms <mode>` — test mode set. Used by `config_onu` for `ignore_ploam_rx_loss_enable=1` style toggles.
- Hundreds of `gpe_*` commands for the GPON packet engine (data plane).

The binary has no built-in commands for setting OMCI identity at runtime. The path for that is UCI → `config_onu` at boot. See the next section for the bugs there.

## `config_onu`: known mangling bugs

Confirmed empirically on the firmware variant this guide describes:

1. **`equipment_id` gets overwritten with `nSerial`'s value.** Whatever you put in `gpon.onu.equipment_id`, `config_onu` reads the UCI, programs the Equipment ID register with `nSerial`'s value instead, **and** rewrites the UCI key back with `nSerial`'s value. The clobber persists across boots. You can `uci set` the correct value, but on next boot it's clobbered again.
2. **`ont_version` `\0` escape pairs get converted to literal ASCII `'0'`.** If you set `gpon.onu.ont_version='ARLTLBN100\0\0\0\0'` (the standard MIB-file syntax for padding to 14 bytes with NUL), `config_onu` writes the register as `ARLTLBN1000000` — 14 ASCII characters, the four trailing `\0` escape pairs each replaced by a single ASCII `0`. UCI is rewritten with the mangled value too.

Workarounds:

- **For most ISPs, you don't need a workaround.** Orange France's OLT enforces the GPON Serial Number (ME 256 Serial Number) but does not appear to enforce Equipment ID or Version. We left both fields visibly wrong and the OLT authenticated cleanly. See the README's "Critical insights" section for the test.
- **If your OLT does enforce these fields**, the available escape hatches are:
  - `onu onurs` to write the identity registers directly, in a script at S65 priority (after `config_onu` clobbers them, before `omcid` reads them). Requires identifying the register addresses on the Falcon SoC; we have not done this.
  - `LD_PRELOAD` to intercept `config_onu`'s UCI reads and substitute correct values. Fragile.
  - Patch the `config_onu` binary. Most invasive; last resort.

## SFP I2C EEPROM: `sfp_i2c`

```
/opt/lantiq/bin/sfp_i2c -h     # show the index table
/opt/lantiq/bin/sfp_i2c -i 6 -s "PRV33AX346B0000"    # set Equipment ID in EEPROM
/opt/lantiq/bin/sfp_i2c -i 7 -s "ARLT"               # set Vendor ID in EEPROM
/opt/lantiq/bin/sfp_i2c -i 8 -s "ARLT12345678"       # set GPON SN in EEPROM
/opt/lantiq/bin/sfp_i2c -g                            # dump all current EEPROM values
```

Notes:

- The index map varies by firmware variant. Use `-h` on your stick to confirm.
- Writes to the SFP I2C EEPROM are **separate** from OMCI register state. They surface to the host router as SFP MSA fields (visible via `ethtool -m sfp1`), and to the OLT only if it reads SFP MSA before OMCI. Orange France does not appear to rely on these.
- Make EEPROM writes persistent across reboot by appending the `sfp_i2c` calls to `/etc/rc.d/S99setserial`.

## Custom MIB file

When custom MIB generation is enabled (`uci set gpon.onu.mib_customized='1'`, `uci delete gpon.onu.mib_file`, reboot), `omcid.sh` runs `generate_custom_mib()` which:

1. Copies `/etc/mibs/nameless.ini` to `/etc/mibs/custom.ini`.
2. Appends ME 256 and ME 257 lines built from UCI values:

```
256 0 ${vendor_id} ${ont_version} 00000000 2 0 0 0 0 #0
257 0 ${equipment_id} 0xa0 0xcc 1 1 64 64 1 64 0 0x007f 0 24 48
```

3. Sets `gpon.onu.mib_file=/etc/mibs/custom.ini`.

`omcid` is then started with `-p /etc/mibs/custom.ini`.

For ME 7 (Software Image) and most other MEs, `omcid` reads from this file at startup. **For ME 256/257 identity, it reads from hardware registers as covered above.** The two appended lines in `custom.ini` are inert for those specific attributes. They are nevertheless worth keeping correct: if a future firmware update changes the architecture, the file content gives a future debugger the right values to work from.

## U-Boot environment

`fw_printenv` shows the U-Boot environment, which is `omcid`'s source of truth for **ME 7 Software Image** version strings and a few other fields:

- `image0_version` / `image1_version` — populated as ME 7 instance 0 / 1 Software Image version.
- `omci_sw_ver1` / `omci_sw_ver2` — decorative; not currently read by `omcid` on this firmware variant.
- `equipment_id`, `vendor_id` — decorative; the live source of truth is UCI.

Modify with `fw_setenv key value`. Changes are persistent.

## Useful diagnostic snapshot

`scripts/ma5671a-diagnostic.sh` (mirrored in [`09-phase4-ma5671a-omci-clone.md`](09-phase4-ma5671a-omci-clone.md)) bundles the common state-inspection commands into one script you can run when picking the work up after a break.

## Thermal note

The MA5671A runs warm even with a heatsink. Some users have reported instability when the stick is in an enclosed cage with no airflow. Symptoms: random PLOAM drops, OMCI disconnects under load. Mitigation: passive heatsink minimum, and avoid stacking SFP cages above a hot ASIC. If you have ongoing thermal issues, an active solution (small fan blowing across the SFP cages) is more effective than larger heatsinks.
