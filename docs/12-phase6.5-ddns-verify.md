# 12 — Phase 6.5: DDNS verification

## Goal

Confirm that your DDNS hostname updates to the new public IP after the Phase 6 swap, and that inbound services (VPN, port-forwarded apps) remain reachable from outside the LAN.

The new public IP comes from Orange's BNG pool and is almost certainly different from the one the ISP modem had. Inbound traffic to the old IP will time out until DDNS propagates and your client refreshes.

## Success criteria

- DDNS hostname resolves to the new public IP from an external DNS server (i.e. the update has propagated)
- A WireGuard / VPN client outside the LAN can establish a tunnel via the DDNS hostname
- Any other inbound services (HTTPS, SSH, etc.) reachable

## Pre-requisites

- Phase 6 complete (router has public IPv4 on `sfp1.832`)
- DDNS configured and running on the router (this guide assumes Gandi or a similar provider; the principles transfer)

## Steps

### 1. Check the new public IP

From the router:

```
ssh root@<router-ip>
curl -s -4 https://ifconfig.io
```

Note the IP. Compare to the previous public IP (which the ISP modem had); they will be different.

### 2. Trigger the DDNS update manually

OpenWrt's `ddns-scripts` runs on a schedule; we want immediate update.

```
/usr/lib/ddns/dynamic_dns_updater.sh -v 2 -S <ddns-section-name>
```

Replace `<ddns-section-name>` with the name of your DDNS config section. Find it with:

```
uci show ddns | grep '=service'
```

Look for the verbose output to confirm the API call succeeded.

For Gandi specifically: the older ddns-scripts code used the deprecated XML-RPC API. Modern Gandi requires their REST LiveDNS API with Bearer authentication. If your script uses an outdated update URL, fix it (`uci set ddns.<section>.update_url='https://api.gandi.net/v5/livedns/...'` etc., and use Bearer auth headers via the `httpheaders` directive).

### 3. Wait and verify propagation

DDNS propagation depends on your DNS provider's TTL. Common TTLs:

- Gandi LiveDNS: default 300 s (5 minutes)
- Cloudflare: as low as 60 s
- Most others: 300-3600 s

Wait the TTL plus a buffer, then check from an external DNS server (not the router's local resolver, which may cache):

```
nslookup <your.ddns.hostname> 8.8.8.8
dig @8.8.8.8 <your.ddns.hostname>
```

The answer should be the new public IP from step 1.

If it still shows the old IP after the TTL has passed, the update didn't reach your DNS provider. Check the DDNS log:

```
logread | grep -i ddns
cat /var/log/ddns/<section>.log
```

Common issues:

- API token expired (rotate via provider UI, update `/etc/config/ddns`)
- Wrong update URL (provider changed API; refer to provider docs)
- Rate limit hit (provider rejecting too-frequent updates)

### 4. Test inbound VPN

From outside the LAN — phone on mobile data hotspotting to your laptop, or another remote location:

1. Disconnect from the LAN's WiFi.
2. Activate your WireGuard / VPN tunnel using the DDNS hostname as the endpoint.
3. Ping a LAN IP through the tunnel:

   ```
   ping -c 3 192.168.1.1
   ```

Should respond.

If the tunnel doesn't come up:

- DNS not propagated yet — wait longer, recheck step 3.
- VPN client is using a cached old IP — restart the VPN client, or wait for its own internal DNS refresh.
- The router firewall isn't accepting on the new WAN interface — verify the firewall rule covers the `wan` zone (which now includes `sfp1.832`) and not just `wan` device. `uci show firewall` and check zone membership.
- Port forwarding from Phase 1 — the old modem-side port forward is gone (the modem is unplugged). The router directly receives inbound traffic now; the existing OpenWrt firewall rules accepting on `wan` should suffice.

### 5. Test other inbound services

If you run HTTPS, SSH, or other inbound: connect from outside via the DDNS hostname. Confirm each works.

If you previously relied on the ISP modem doing port forwarding (Phase 1 double-NAT), you no longer need those rules on the modem; everything is direct on the router now. Clean up the modem port-forward entries when you next have admin access to it.

## Risks

- **TTL longer than you expect**: if your DDNS hostname has a 3600 s TTL, you'll be waiting an hour for clients to refresh. Plan accordingly; consider lowering the TTL in advance of Phase 6.
- **VPN client caching**: some clients (especially on mobile) cache DNS aggressively. Force-quit and reopen.
- **DDNS provider API outage**: rare but it happens. Check the provider's status page.

## Rollback

N/A — this is diagnostic only. If DDNS is broken, the router still has internet; you can fix DDNS at leisure.

## Notes

This phase often "just works" after a 5-10 minute wait. If you've been doing DDNS for a while and the script is healthy, the update on first network restart after Phase 6 is automatic.

It's worth keeping the previous public IP written down for a day or two. If you have monitoring or alerting tied to a specific IP, update those configs in parallel with this phase.

The IPv6 prefix is also new after Phase 6 (the BNG assigns a fresh /56 each time the line authenticates). If you run any inbound IPv6 services or have IPv6 firewall rules referencing specific addresses, expect to update them. AAAA records for the DDNS hostname should also refresh; verify with `dig AAAA <hostname> @8.8.8.8`.
