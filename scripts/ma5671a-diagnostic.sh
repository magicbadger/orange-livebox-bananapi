#!/bin/sh
# Snapshot rooted MA5671A state for resume / debugging.
# Run on the MA5671A itself via SSH.
#
# Source of truth: this file is mirrored in README.md and docs/09-phase4-ma5671a-omci-clone.md.

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
