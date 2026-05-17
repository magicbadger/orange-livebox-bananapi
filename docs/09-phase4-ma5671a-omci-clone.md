---
title: "Phase 4: OMCI identity clone"
nav_order: 10
---

# 09 — Phase 4: Clone the OMCI identity onto the MA5671A

## Goal

The rooted ONT stick presents itself to the ISP's OLT as a clone of your existing ISP modem at the GPON / OMCI layer. The OLT then authenticates it on the fibre as if it were the original modem.

This phase is done **with the rooted stick plugged into SFP2 of the router**, while the live fibre is still on the original ISP modem. We don't touch the fibre side until Phase 6.

For a deep understanding of the OMCI architecture, read [`18-omci-architecture.md`](18-omci-architecture.md) first or alongside this one. This phase is the practical procedure; the architecture document explains why each step is what it is.

## Success criteria

- ME 256 Serial Number reads back as the cloned GPON SN (4 ASCII vendor bytes + 4 binary bytes)
- The custom MIB framework is active (`/etc/mibs/custom.ini` present, omcid running with `-p /etc/mibs/custom.ini`)
- Values persist across reboot
- Equipment ID and Version mismatches are documented but not fixed (the OLT does not enforce them on Orange France; see README "Critical insights")

## Pre-requisites

- Phase 0 complete (you have the modem identity values captured)
- The rooted stick is in SFP2 and you can SSH into it at the management IP (`192.168.1.10` by default)
- Phase 0 ONT snapshot is saved off-stick

## Values you're cloning

For the reference build, the values captured from the Livebox S are:

| Field | Value | Goes into |
|-------|-------|-----------|
| GPON Serial Number | `ARLT12345678` | `gpon.onu.nSerial`, becomes ME 256 Serial Number (attr 3) |
| Vendor ID | `ARLT` | `gpon.onu.vendor_id`, becomes ME 256 Vendor ID (attr 1) |
| Equipment ID | `PRV33AX346B0000` | `gpon.onu.equipment_id`, *intended* for ME 257 Equipment ID (attr 1) — but see mangling bug below |
| ONT Version | `ARLTLBN100` | `gpon.onu.ont_version`, *intended* for ME 256 Version (attr 2) — but see mangling bug below |
| OMCI Software Version 0 | `SAHNOFR010216` | U-Boot `image0_version`, via `fw_setenv` |
| OMCI Software Version 1 | `SAHNOFR010601` | U-Boot `image1_version`, via `fw_setenv` |

Replace these with your own captured values. If your ISP isn't Orange France, the formats may differ (Vendor ID may not be 4 chars; ONT Version may have a different length); capture what your modem reports and use that verbatim.

## Steps

### 1. SSH into the rooted ONT

From your workstation:

```
sudo arp -d 192.168.1.10 2>/dev/null
ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 \
    -oHostKeyAlgorithms=+ssh-dss \
    root@192.168.1.10
```

Password: depends on firmware variant. The web-flashed variant used in the reference build has no password set for `root`; some other rooted variants use `admin123`. See [`03-ma5671a-specifics.md`](03-ma5671a-specifics.md).

### 2. Capture current state (baseline)

```
uci show gpon.onu > /tmp/gpon-pre.txt
/opt/lantiq/bin/omci_pipe meg 256 0 > /tmp/me256-pre.txt
/opt/lantiq/bin/omci_pipe meg 257 0 > /tmp/me257-pre.txt
/opt/lantiq/bin/omci_pipe meg 7 0 > /tmp/me7-0-pre.txt
/opt/lantiq/bin/omci_pipe meg 7 1 > /tmp/me7-1-pre.txt
fw_printenv > /tmp/fw-env-pre.txt
```

scp these off the stick. You'll want them to compare against post-change state.

### 3. Set UCI identity keys

```
uci set gpon.onu.vendor_id='ARLT'
uci set gpon.onu.nSerial='ARLT12345678'
uci set gpon.onu.ont_version='ARLTLBN100\0\0\0\0'
uci set gpon.onu.equipment_id='PRV33AX346B0000\0\0\0\0\0'
uci set gpon.onu.mib_customized='1'
uci -q delete gpon.onu.mib_file
uci commit gpon
```

Three things to notice:

- `nSerial` is 12 characters: 4 ASCII vendor prefix + 8 hex digits. `config_onu` parses this and writes 4 ASCII bytes + 4 binary bytes (representing those 8 hex digits) into the ME 256 Serial Number attribute.
- `\0` in UCI is the standard escape for a NUL byte; the values are intended to land in fixed-width fields padded with NULs. **But** `config_onu` mangles this for `ont_version` (see below).
- `mib_customized=1` triggers `generate_custom_mib()` in `omcid.sh` at boot. `uci delete mib_file` removes the trap that would otherwise prevent custom-MIB generation. See [`18-omci-architecture.md`](18-omci-architecture.md) for the explanation of why this delete is required.

### 4. Set U-Boot software-image version strings

```
fw_setenv image0_version "SAHNOFR010216"
fw_setenv image1_version "SAHNOFR010601"
```

These surface as ME 7 instance 0 / 1 Software Image version. `omcid` reads them from U-Boot env at startup and writes them into the MIB.

If you want, also set decorative `omci_sw_ver1` / `omci_sw_ver2` — but on the firmware variant we tested they are not actually read by `omcid` and have no effect on the OMCI report. Setting them doesn't hurt.

### 5. (Optional) Mirror values into SFP I2C EEPROM

If your ISP reads SFP MSA fields (rare; most read OMCI):

```
/opt/lantiq/bin/sfp_i2c -i 6 -s "PRV33AX346B0000"    # Equipment ID
/opt/lantiq/bin/sfp_i2c -i 7 -s "ARLT"               # Vendor ID
/opt/lantiq/bin/sfp_i2c -i 8 -s "ARLT12345678"       # GPON SN
```

Confirm the index map on your firmware variant with `sfp_i2c -h`.

Persist across reboot by appending to `/etc/rc.d/S99setserial`:

```
cat >> /etc/rc.d/S99setserial <<'EOF'
/opt/lantiq/bin/sfp_i2c -i 8 -s "ARLT12345678"
/opt/lantiq/bin/sfp_i2c -i 6 -s "PRV33AX346B0000"
/opt/lantiq/bin/sfp_i2c -i 7 -s "ARLT"
EOF
```

(Make sure the script remains executable; `chmod +x /etc/rc.d/S99setserial` if you've replaced it rather than appended.)

### 6. Reboot the stick

```
reboot
```

The stick takes about 60 seconds to come back. Wait, then SSH back in.

### 7. Verify OMCI state

```
/opt/lantiq/bin/omci_pipe meg 256 0 | head -20
/opt/lantiq/bin/omci_pipe meg 257 0 | head -10
/opt/lantiq/bin/omci_pipe meg 7 0 | head -10
/opt/lantiq/bin/omci_pipe meg 7 1 | head -10
uci show gpon.onu
ls -la /etc/mibs/custom.ini
```

#### What you should see (good)

- **ME 256 attr 0 Vendor ID**: `ARLT` (or your value) — **critical**, must be right
- **ME 256 attr 2 Serial Number**: 8 bytes; first 4 = ASCII `0x41 0x52 0x4c 0x54` (= "ARLT"), last 4 = binary representation of `54 74 0E 9B` — **critical**, must be right
- **`/etc/mibs/custom.ini` exists** and is non-empty

#### What you may see (and what it means)

- **ME 256 attr 1 Version**: `ARLTLBN1000000` (14 ASCII characters). This is the `config_onu` `\0`-to-`'0'` mangling bug. Documented in [`03-ma5671a-specifics.md`](03-ma5671a-specifics.md) and the README. On Orange France this does **not** block authentication.
- **ME 257 attr 0 Equipment ID**: `ARLT12345678` followed by NULs, not your `PRV33AX346B0000`. This is the `config_onu` Equipment-ID-overwritten-with-nSerial bug. On Orange France this also does **not** block authentication.
- **UCI `equipment_id` and `ont_version` rewritten** by `config_onu` to mangled values. Re-setting them with `uci set ...` does not help: the next boot rewrites them again. Don't fight this.

#### What you should not see (bad)

- ME 256 Vendor ID stays `HWTC` (Huawei default). Means the customisation didn't take — `mib_customized` wasn't set, or `mib_file` was still pointing at the static MIB. Re-check step 3.
- ME 256 Serial Number stays `HWTC...`. Same problem.
- `omcid` is not running. Check `ps w | grep omcid`; if not running, look at `/tmp/log/messages` or `logread` for the failure reason. The `omcid` startup logs a benign "can't resolve symbol 'uloop_run_events'" warning that does not stop it; if you see only that and nothing else, the daemon is fine.

### 8. Confirm the omcid command line

```
ps w | grep omcid | grep -v grep
```

You should see something like:

```
/opt/lantiq/bin/omcid -p /etc/mibs/custom.ini -o 160 -i 0 -g1
```

The `-p /etc/mibs/custom.ini` confirms `omcid` is using the generated custom MIB rather than the stock `/etc/mibs/data_1g_8q_us1280_ds512.ini`.

### 9. Verify PLOAM state

```
onu ploamsg
```

With no fibre, `curr_state=1` (O1 initial). This is normal at this stage; the stick is electrically up but has no downstream signal. We're not testing GPON yet; we're confirming the OMCI configuration is correct in the absence of a fibre signal.

You cannot actually verify against the live OLT until Phase 6, when the fibre moves.

### 10. Capture diagnostic snapshot

The `scripts/ma5671a-diagnostic.sh` script (embedded in [`03-ma5671a-specifics.md`](03-ma5671a-specifics.md)) bundles all the inspection commands into one script. Run it and save:

```
sh /tmp/ma5671a-diagnostic.sh > /tmp/post-clone-snapshot.txt
```

scp to workstation, keep alongside the Phase 0 baseline.

## Risks

- **Wrong UCI keys** — values typed wrong. Symptom: ME 256 Serial Number doesn't match. Re-set, reboot, verify.
- **MIB customisation not taking** — `mib_file` trap not avoided. Symptom: `omcid` running without `-p /etc/mibs/custom.ini`. Re-run step 3 with the `uci -q delete gpon.onu.mib_file`.
- **`config_onu` segfaults at boot** — rare, but observed if UCI values are malformed (e.g. `nSerial` with the wrong length). Symptom: stick boots, SSH works, but `omcid` is not running and `logread` shows `config_onu` crash. Fix the UCI value and reboot.
- **Cannot SSH in after reboot** — `gpon` UCI changes can sometimes flap the management interface. Wait 2 minutes, then power-cycle. As a last resort, factory reset to the Huawei stock (which restores SSH) and re-root.

## Rollback

Restore Huawei defaults:

```
uci set gpon.onu.vendor_id='HWTC'
uci set gpon.onu.ont_version='CC4.A00000000'
uci set gpon.onu.equipment_id='MA5671A-G100000000000'
uci set gpon.onu.nSerial='HWTC12345678'                  # use your stick's original SN
uci delete gpon.onu.mib_customized
uci set gpon.onu.mib_file='/etc/mibs/data_1g_8q_us1280_ds512.ini'
uci commit gpon
reboot
```

If you saved the Phase 0 snapshot of `uci show gpon` you can replay it directly. Note that `config_onu` will rewrite `equipment_id` and `ont_version` regardless of what you set, so the rollback may not look exactly like the pre-state for those two keys.

## Notes on the empirical findings

The README's "Critical insights" section captures the verbatim findings from this work. The headline result:

> Only the gSerial (ME 256 Serial Number) actually had to match. Equipment ID was completely wrong (mangled to nSerial value) and Version had ASCII '0' padding instead of NUL bytes, and Orange's BNG still authenticated cleanly, issued a DHCP lease, and routed traffic.

Translating to action: **don't burn hours on Equipment ID and Version**. Get gSerial right, accept the mangled values for the others, move to Phase 5 and 6 to test against the live OLT.

If your ISP is not Orange France, you may not have the same leniency. In that case, the OMCI architecture document covers the `onu onurs` raw-register-write escape hatch as a starting point — but expect significant additional work.

## Embedded: `scripts/ma5671a-diagnostic.sh`

For convenience, the diagnostic script is reproduced here. Same content as `scripts/ma5671a-diagnostic.sh` in the repository — if you change one, change both.

```sh
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
