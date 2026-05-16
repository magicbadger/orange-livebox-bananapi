# 05 — Phase 0: Inventory and backup

## Goal

Ensure full recoverability and complete information capture before any change is made. Phase 0 is preparation; it does not touch any live configuration.

## Success criteria

- Router configuration backed up to off-router storage
- ONT stick configuration captured (if accessible)
- Modem credentials confirmed available
- Critical device IPs documented
- Emergency connectivity option lined up

## Pre-requisites

- Working internet via the ISP modem
- The OpenWrt router exists (newly installed or repurposed) but is not yet integrated
- The rooted ONT stick is rooted and you have SSH access to it

## Steps

### 1. Back up the OpenWrt router

From the router:

```
ssh root@<router-ip>
sysupgrade -b /tmp/backup-pre-migration.tar.gz
```

From your workstation:

```
scp root@<router-ip>:/tmp/backup-pre-migration.tar.gz ~/Documents/
```

`sysupgrade -b` produces a tarball of all UCI config, custom files in `/etc/config/`, SSH keys, and anything else that's flagged as backed-up in `/etc/sysupgrade.conf`. It's the same tarball LuCI produces via Backup/Restore.

Test the integrity:

```
tar -tzf ~/Documents/backup-pre-migration.tar.gz | head
```

### 2. Snapshot the ONT stick state

If you can SSH into the rooted ONT (plug it into the router's spare SFP cage and use the management IP):

```
ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 -oHostKeyAlgorithms=+ssh-dss root@192.168.1.10
```

Then:

```
fw_printenv > /tmp/ma5671a-fw-printenv.txt
uci show gpon > /tmp/ma5671a-uci-gpon.txt
cat /etc/rc.d/S99setserial > /tmp/ma5671a-s99setserial.txt
ls -la /etc/mibs/ > /tmp/ma5671a-mibs-ls.txt
```

Copy these off the stick to your workstation. They are the recovery point if you brick the OMCI configuration.

The `scripts/ma5671a-diagnostic.sh` script bundles a more thorough state dump; run it once and save the output:

```
ssh ... root@192.168.1.10 sh < scripts/ma5671a-diagnostic.sh > ~/Documents/ma5671a-snapshot-$(date +%Y%m%d).txt
```

### 3. Confirm ISP credentials are available

For Orange France: the `fti/` username and password. Locations:

- The paper documentation that came with the original Livebox.
- The Orange mobile app under contract details (less reliable for new customers).
- An old Orange email confirming activation.
- Orange 3900 phone support (variable success rate).

If you cannot locate the password, see [`04-orange-france-notes.md`](04-orange-france-notes.md) for fallback options and the discussion of attempting Phase 6 without Option 90.

### 4. Capture modem identity values

From the ISP modem's admin interface (Orange Livebox: "Information système" or equivalent):

- WAN MAC address
- GPON Serial Number (ONT SN)
- OMCI Vendor ID
- OMCI Equipment ID
- OMCI ONT Version / Hardware Version
- OMCI Software image versions (and which is active)
- Box serial number, model, firmware version (reference, not used in cloning)

If your modem doesn't expose all these in the admin UI, Orange France Liveboxes can be queried more thoroughly via GO-BOX. See [`04-orange-france-notes.md`](04-orange-france-notes.md).

### 5. Capture network configuration

From the ISP modem:

- Data VLAN ID (Orange: 832), PCP (6)
- IPTV VLAN ID (Orange: 840), PCP (4)
- Any VoIP VLAN if different
- IPv6 prefix delegated (Orange: /56 with current prefix from RA)
- DHCP options the modem sends (capture via tcpdump if possible)
- DNS resolvers used by the modem

### 6. Document critical device IPs

Make a list of everything on the existing LAN whose IP matters: home assistant, IP cameras, IoT controllers, NAS, the TV decoder, family device DHCP reservations. After Phase 1 the OpenWrt router will own DHCP for the LAN; you want to recreate static leases for anything that other systems address by IP.

### 7. List existing port forwards on the ISP modem

Orange Livebox port forwarding rules (admin UI under NAT/PAT). Common entries:

- STB Remote PVR (decoder → external)
- STB TR-069
- VHD notifications (Voice High Definition notification service)

If you want these features to keep working, you'll replicate them in Phase 9. Note the rule details now while the Livebox UI is still accessible.

### 8. Document SIP / VoIP if applicable

The Livebox admin UI may show the SIP server and the phone number associated with your line. It will **not** show SIP credentials. See [`04-orange-france-notes.md`](04-orange-france-notes.md) and [`14-phase8-voip.md`](14-phase8-voip.md).

Phone number to note for testing: e.g. `+33...`.

### 9. Note the ISP modem admin password

You will change the modem's LAN IP in Phase 1; the admin password is needed for that. Don't lose it.

### 10. Line up emergency connectivity

Have a phone with mobile data, set up as a personal hotspot, ready to go. Multi-hour failures during Phase 4 or Phase 6 are normal in our experience; not being able to look anything up because the house has no internet is a needless source of stress.

## Risks

None. Phase 0 changes nothing.

## Rollback

N/A.

## Outputs to keep for later phases

A folder with:

- `backup-pre-migration.tar.gz` (the router)
- `ma5671a-snapshot-<date>.txt` (the ONT)
- `modem-identity.txt` (handwritten or typed up)
- `modem-network.txt` (VLANs, PCPs, prefixes, DHCP options)
- `modem-port-forwards.txt`
- `device-ip-inventory.txt`
- `isp-credentials.txt` (handle with care; redact before sharing)

Keep these somewhere you can find them under stress with no internet. Print the critical commands and IPs on paper if you're being thorough.
