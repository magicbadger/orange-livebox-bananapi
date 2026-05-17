---
title: OMCI architecture deep dive
nav_order: 19
---

# 18 — OMCI architecture on the rooted MA5671A

A deep dive into how OMCI identity is set, read, and reported on the rooted Huawei MA5671A firmware. This document exists because the practical procedure ([`09-phase4-ma5671a-omci-clone.md`](09-phase4-ma5671a-omci-clone.md)) gives you the right commands without explaining why those specific commands and not others; the wrong mental model wastes hours.

Most of the content here is empirical, derived from a multi-evening reverse-engineering session described in the project's session log. The investigation pattern (read-only diagnostics → hypothesis → targeted test → update model) is itself worth replicating if you need to debug a different firmware variant.

## Three places OMCI identity can live

A naive mental model says OMCI identity is defined in one place. It's not. It's in three:

1. **The MIB file** — a text file (e.g. `/etc/mibs/data_1g_8q_us1280_ds512.ini` or `/etc/mibs/custom.ini`) listing every OMCI Managed Entity instance and its attribute values. `omcid` reads this at startup.
2. **Hardware identity registers** in the Intel/Lantiq Falcon GPON MAC SoC. These hold the bytes that the GPON / OMCI hardware blocks transmit in PLOAM serial-number messages and in OMCI responses for ME 256 / ME 257.
3. **U-Boot environment variables** (`fw_printenv`), specifically `image0_version` and `image1_version`, which `omcid` reads for ME 7 (Software Image) at startup.

Different MEs are sourced from different layers. Worse, the file-vs-register interaction is layered: the file is read at startup, then *some* MEs (the ones we care about for ISP authentication) are *overwritten in memory* with the hardware register contents.

This is the key insight that costs people the most time: **for ME 256 and ME 257, `omcid` reads identity from hardware registers, not from the MIB file.** Editing the MIB file does not change ME 256 Vendor ID, Version, Serial Number, or ME 257 Equipment ID at runtime. We have an experimental test (the "ZZZZ test") that confirms this; see the test section below.

## The boot sequence

When the MA5671A boots, init scripts run in priority order (priorities are encoded in symlink names under `/etc/rc.d/Snn*`):

| Priority | Script | Effect |
|---------:|--------|--------|
| **S60** | `config_onu` | Reads UCI keys `gpon.onu.{vendor_id, ont_version, equipment_id, nSerial, ...}`. Programs hardware identity registers from those values. Has known mangling bugs (see below). |
| S61 | `onu.sh` | Brings up the GPON physical interface. |
| S62 | `sfp_eeprom.sh` | Initialises the SFP I2C EEPROM. |
| **S85** | `omcid.sh` | Decides which MIB file to load. If customisation is enabled, generates `/etc/mibs/custom.ini`. Starts `omcid`. |
| S97 | `monitomcid` | Watchdog. Restarts `omcid` if it dies. |
| S99 | `setserial` (`S99setserial`) | Writes SFP I2C EEPROM identity fields via `sfp_i2c`. Decorative for OMCI; the EEPROM is read by some OLTs as part of SFP MSA but not used for OMCI authentication. |

The interesting interaction is S60 → S85. `config_onu` programs the hardware registers; `omcid` then reads its MIB file but, for ME 256/257 attributes, the register state wins. We confirmed this experimentally (see ZZZZ test).

## `omcid.sh`'s four-branch MIB selection

The relevant function in `/etc/init.d/omcid.sh` is roughly:

```sh
start_service() {
    local mib_file
    # branch 1: U-Boot env override
    mib_file=$(fw_printenv -n mib_file 2>/dev/null)
    if [ -n "$mib_file" ] && [ -f "$mib_file" ]; then
        :  # use this mib_file
    else
        # branch 2: UCI mib_file (with custom.ini guard)
        mib_file=$(uci -q get gpon.onu.mib_file)
        if [ -n "$mib_file" ] && [ "${mib_file##*custom.ini*}" = "$mib_file" ]; then
            :  # use this mib_file (it must not contain "custom.ini")
        else
            # branch 3: customised path
            if [ "$(uci -q get gpon.onu.mib_customized)" = "1" ]; then
                generate_custom_mib
                mib_file="/etc/mibs/custom.ini"
                uci set gpon.onu.mib_file="$mib_file"
                uci commit gpon
            else
                # branch 4: default static
                mib_file="/etc/mibs/data_1g_8q_us1280_ds512.ini"
            fi
        fi
    fi

    /opt/lantiq/bin/omcid -p "$mib_file" -o 160 -i 0 -g1 &
}
```

(The actual script may differ in syntax — read your own.)

The branch ordering matters:

- Branch 1 is rarely active; `mib_file` U-Boot env is unset by default.
- **Branch 2 is the trap.** The default rooted firmware ships with `gpon.onu.mib_file=/etc/mibs/data_1g_8q_us1280_ds512.ini`. Branch 2 fires because that path doesn't contain `custom.ini`. The result: the static MIB is loaded, **even if you set `mib_customized=1`**.
- Branch 3 is what we actually want; it fires only if branch 1 and branch 2 both fall through, which requires `gpon.onu.mib_file` to be empty or contain `custom.ini`.

**The fix** is `uci delete gpon.onu.mib_file` before reboot. Branch 3 then fires, generates `custom.ini`, and the file `mib_file` setting is rewritten to `/etc/mibs/custom.ini` at the end of branch 3.

If you accidentally restore an old `gpon.onu.mib_file` value pointing at the static MIB, custom-MIB generation silently gets disabled again. This is one of the most confusing failure modes.

This is README "Critical insights" item 2.

## `generate_custom_mib()`

Roughly:

```sh
generate_custom_mib() {
    cp /etc/mibs/nameless.ini /etc/mibs/custom.ini
    local vendor=$(uci get gpon.onu.vendor_id)
    local version=$(uci get gpon.onu.ont_version)
    local eqid=$(uci get gpon.onu.equipment_id)
    cat >> /etc/mibs/custom.ini <<EOF
256 0 ${vendor} ${version} 00000000 2 0 0 0 0 #0
257 0 ${eqid} 0xa0 0xcc 1 1 64 64 1 64 0 0x007f 0 24 48
EOF
}
```

It copies a template (`nameless.ini`) to `custom.ini`, then appends ME 256 and ME 257 lines built from UCI values. Other MEs come from the template.

`nameless.ini` is mostly defaults; it contains entries for common ME classes (1, 2, 5, 6, 7, 11, 24, 45, 84, ...) with placeholder values that `omcid` populates at runtime or that are simply unimportant for ISP authentication.

ME 7 (Software Image) is special: the template has `7 0` and `7 1` entries with empty version fields. `omcid` populates them from `fw_printenv image0_version` / `image1_version` at startup. So to change ME 7 reported values, `fw_setenv` the U-Boot env vars.

## The ZZZZ test: experimental confirmation

We needed to know whether `omcid` reads ME 256/257 attributes from the MIB file at runtime or from somewhere else. The test:

```sh
# Back up the active custom.ini
cp /etc/mibs/custom.ini /etc/mibs/custom.ini.bak

# Edit the ME 256 line to use sentinel values "ZZZZ"
sed -i 's|^256 0 ARLT |256 0 ZZZZ |' /etc/mibs/custom.ini

# Restart the daemon to force reload
/etc/init.d/omcid.sh restart
sleep 3

# Read back what omcid reports
/opt/lantiq/bin/omci_pipe meg 256 0 | sed -n '/Vendor id/,/-----/p'

# Restore and re-restart
cp /etc/mibs/custom.ini.bak /etc/mibs/custom.ini
/etc/init.d/omcid.sh restart
```

Result on the rooted Huawei firmware: the ME 256 Vendor ID readout was `ARLT`, **not** `ZZZZ`, despite the `custom.ini` file containing `ZZZZ`.

Interpretation: `omcid` does not source ME 256 Vendor ID from the MIB file at runtime. It sources from the hardware identity register that `config_onu` programmed at S60.

We did not test attribute 2 (Version) and attribute 3 (Serial Number) with the same sentinel, but by symmetry — and because all three identity attributes come from `config_onu` UCI reads — they almost certainly behave the same way. The same applies to ME 257 Equipment ID.

For ME 7 (Software Image) the registers don't apply; that ME is populated from U-Boot env. We verified separately by `fw_setenv` and reading `omci_pipe meg 7 0`.

This is README "Critical insights" item 3.

## `config_onu` mangling bugs

Empirically observed on the firmware variant this guide describes:

### Bug 1: Equipment ID is overwritten with `nSerial`

`config_onu` reads `gpon.onu.equipment_id` from UCI but writes `gpon.onu.nSerial`'s value to the Equipment ID hardware register. It also rewrites the UCI `equipment_id` key with `nSerial`'s value, so the mangling persists across reboots.

Verification:

```sh
uci set gpon.onu.equipment_id='PRV33AX346B0000\0\0\0\0\0'
uci set gpon.onu.nSerial='ARLT12345678'
uci commit gpon
reboot

# after reboot:
uci show gpon.onu.equipment_id
# expected: PRV33AX346B0000\0\0\0\0\0
# observed: ARLT12345678
/opt/lantiq/bin/omci_pipe meg 257 0 | head -10
# Equipment id field: ARLT12345678 + NUL padding
```

### Bug 2: `\0` escape pairs in `ont_version` become ASCII `'0'`

`config_onu` reads `gpon.onu.ont_version`. It evidently does its own escape processing on the string. The standard MIB-ini convention is that `\0` is an escape pair representing a NUL byte; `config_onu` instead converts each `\0` into a single ASCII `0` character.

Verification:

```sh
uci set gpon.onu.ont_version='ARLTLBN100\0\0\0\0'   # 14 chars: 10 ASCII + 4 NULs
uci commit gpon
reboot

# after reboot:
uci show gpon.onu.ont_version
# expected: ARLTLBN100\0\0\0\0
# observed: ARLTLBN1000000   (14 ASCII characters, not 10+4)
/opt/lantiq/bin/omci_pipe meg 256 0 | head -20
# Version field: 0x41 0x52 0x4c 0x54 0x4c 0x42 0x4e 0x31 0x30 0x30 0x30 0x30 0x30 0x30
# (= "ARLTLBN1000000" in ASCII, 14 bytes)
```

### Workaround paths

None of these have been fully exercised; they're listed for completeness.

- **`onu onurs`** — raw register write at a specific address. Would work if we knew the addresses of the Equipment ID and Version registers in the Falcon SoC. We don't; the binary's strings table doesn't expose them. Datasheet access (not available) or further reverse engineering of `config_onu` (mapping its UCI read to the register write) would yield them.
- **`LD_PRELOAD`** — wrap libc UCI calls in a shim that returns the correct values from `equipment_id` and `ont_version` keys, then run `config_onu` under that preload. Fragile.
- **Binary patch** — disassemble `config_onu`, find the buggy code, patch it. Most invasive; not attempted.

### Empirical mitigation: don't fight it

The README's "Critical insights" item 1 records the practical finding: Orange France's BNG enforces only the GPON Serial Number (ME 256 attribute 3, the binary 4+4 byte field). Equipment ID and Version mismatches do not block authentication. So:

- Get `gpon.onu.nSerial` right and you're done.
- Document the mangled Equipment ID and Version. They are visibly wrong in `omci_pipe meg` output. That's fine.

This may not hold on other ISPs. If you need correct Equipment ID and Version on a different OLT, `onu onurs` is the most likely path.

## `omci_pipe meads`: limits

`omci_pipe meads <class> <instance> <attr> <byte> [<byte>...]` writes one or more bytes to an attribute. It enforces OMCI R/W flags.

Vendor ID (attr 1 on ME 256), Version (attr 2 on ME 256), and Equipment ID (attr 1 on ME 257) are all flagged read-only by the OMCI standard (ITU-T G.988). `meads` returns `errorcode=-14` on write attempts. We cannot use it as an override path.

Battery backup (ME 256 attr 6, RW) accepts writes — confirming the R/W enforcement is per-attribute and not a blanket refusal. We don't need to write Battery backup, but it's a useful probe.

Attribute numbering caveat: `meg` displays 0-indexed (`0 Vendor id, 1 Version, 2 Serial Number, ...`), while `meads` takes 1-indexed input. So `meg`'s "1 Version" attribute is `meads`'s attribute number 2.

## ME 7 Software Image

ME 7 has two instances (0 = "first image", 1 = "second image"). Each has a Version attribute and an Activate flag. `omcid` populates the Version fields at startup from U-Boot env:

- `image0_version` → ME 7 instance 0 Version
- `image1_version` → ME 7 instance 1 Version

To set these:

```sh
fw_setenv image0_version "SAHNOFR010216"
fw_setenv image1_version "SAHNOFR010601"
reboot
```

After reboot:

```sh
/opt/lantiq/bin/omci_pipe meg 7 0 | head -10
/opt/lantiq/bin/omci_pipe meg 7 1 | head -10
```

`omci_sw_ver1` and `omci_sw_ver2` U-Boot env vars (which exist on some MA5671A variants) appear decorative on the firmware we tested — `omcid` does not read them. Set them if you want, no harm done, but `image0_version` / `image1_version` are the live source.

## ME 256 Serial Number: the critical field

The format of the Serial Number attribute on ME 256:

```
8 bytes total:
  bytes 0-3: ASCII vendor prefix (e.g. "ARLT" = 0x41 0x52 0x4c 0x54)
  bytes 4-7: binary representation of the hex serial (e.g. "54740E9B" = 0x54 0x74 0x0e 0x9b)
```

`gpon.onu.nSerial='ARLT12345678'` (12 character ASCII string: 4 vendor + 8 hex) is what `config_onu` reads. It parses the 8 hex characters into 4 binary bytes and writes the full 8-byte structure to the hardware register.

In `omci_pipe meg 256 0` output, the Serial Number field shows the 8 bytes as one hex string:

```
attribute 3 Serial Number: 0x41 0x52 0x4c 0x54 0x54 0x74 0x0e 0x9b
                          (A    R    L    T  )(0x54 0x74 0x0E 0x9B)
```

This is the field the OLT checks at PLOAM ranging time. Get this right and PLOAM gets to O5; get it wrong and PLOAM stalls at O2 or O3.

## OMCC version

`gpon.onu.omcc_version` defaults to 160 ("HWTC mode") on the rooted Huawei firmware. It surfaces as the `-o 160` flag on the `omcid` command line:

```
/opt/lantiq/bin/omcid -p /etc/mibs/custom.ini -o 160 -i 0 -g1
```

OMCC version determines protocol details for the OMCI Common Channel. Orange France's OLT accepts 160. Other OLTs may want a different value; if PLOAM completes but OMCI provisioning fails (`curr_state=5` but no DHCP from the data side), suspect this.

## The benign `uloop_run_events` warning

`omcid` startup logs (visible in `logread`):

```
omcid: can't resolve symbol 'uloop_run_events' in lib '/opt/lantiq/bin/omcid'
```

This is a libubox version mismatch in a code path that isn't on the hot path. The daemon operates correctly anyway. Ignore.

## Verification commands quick reference

```sh
# Daemon and process state
ps w | grep -E 'omcid|onu|monitomcid' | grep -v grep
logread | tail -50

# UCI source of truth
uci show gpon.onu

# MIB file selection (after reboot, this is final)
uci -q get gpon.onu.mib_file
ls -la /etc/mibs/custom.ini

# OMCI MIB state (this is what the OLT sees)
/opt/lantiq/bin/omci_pipe meg 256 0
/opt/lantiq/bin/omci_pipe meg 257 0
/opt/lantiq/bin/omci_pipe meg 7 0
/opt/lantiq/bin/omci_pipe meg 7 1

# GPON link state
onu ploamsg

# U-Boot env for ME 7
fw_printenv | grep -iE 'image[0-9]+_version'

# Diagnostic snapshot (one-shot)
sh /etc/init.d/.. # the scripts/ma5671a-diagnostic.sh bundle
```

## Open questions

- The exact register addresses for ME 256 Version and ME 257 Equipment ID. Locating these would unlock `onu onurs` as an override path.
- Whether the `\0`-mangling in `ont_version` is in `config_onu`'s argv parsing, its UCI library, or its register-write routine. Determines whether a different escape would survive.
- Whether other Huawei MA5671A firmware variants share these bugs (likely yes; the binary appears unchanged across most variants we've heard about, only the OpenWrt base differs).

If you find answers to any of the above, document and link from [`20-references.md`](20-references.md).
