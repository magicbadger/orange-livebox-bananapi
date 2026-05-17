---
title: "Phase 7: IPTV (investigation)"
nav_order: 14
---

# 13 — Phase 7: IPTV multicast via VLAN 840

> **Status: investigated, blocked on decoder activation.** The multicast plumbing (VLAN 840 + `igmpproxy`) in the second half of this document is correct for what it does, but an earlier blocker has been identified: the Orange France TV decoder cannot complete its activation handshake against Orange's STB cloud on a BPI-R3-only setup, regardless of multicast configuration. Both live TV and VOD fail with "Erreur G01" because activation never succeeds. The root cause is **mutual TLS authentication between the decoder and Orange's STB activation server, using credentials that the Livebox normally holds and the BPI-R3 doesn't have access to**. The activation problem has been thoroughly characterised but is unresolved; the "Activation prerequisite" section below documents the findings and "Possible ways forward" lists the realistic paths.

## Activation prerequisite

The Orange TV decoder is not a simple multicast receiver. On boot it tries to register itself with Orange's STB management infrastructure ("activate"), and refuses to do anything else (no live channels, no VOD, no Orange TV app remote) until that registration completes. The error code displayed on a failed activation is **"Erreur G01"** after the "Association de livebox" screen.

This is a separate problem from the multicast plumbing in the rest of this document. Multicast can be perfectly configured and the decoder will still show G01.

> **A note on sources.** The activation analysis below is mostly from packet captures taken in this project; those findings are reliable. Where we cite community guidance, treat it as a starting point for your own verification, not as ground truth. During the investigation we consulted AI-assisted summaries of community write-ups that produced confidently-stated specifics (hex strings, hostnames, GitHub repos, MAC OUI tables) which subsequently failed verification — hallucinated GitHub repositories, malformed Option 125 hex, mis-attributed MAC OUI vendors. The lafibre.info forum threads on Livebox replacement are real and well-discussed (the section "Remplacer la Livebox par un routeur" has multiple long threads on Orange DHCP and OpenWrt setups), and those primary sources are worth reading directly. Don't trust intermediary summaries — including this document — without checking against captures or the real forum threads.

### How decoder activation works on Orange France

Based on `br-lan` packet captures from a BPI-R3 setup with a SoftAtHome-firmware Orange decoder (User-Agent `POSIX UPnP/1.0 SoftAtHome/1.7.19`), the activation sequence is:

1. Decoder boots, gets DHCP from the router's LAN. No vendor-specific DHCP options requested or required.
2. Decoder sends SSDP M-SEARCH for `urn:schemas-upnp-org:device:InternetGatewayDevice:1` — standard UPnP IGD discovery, **not Orange-proprietary**.
3. The Livebox (normally on the LAN) responds with an SSDP HTTP/UDP unicast carrying a `LOCATION:` header pointing at its UPnP description XML.
4. Decoder fetches `rootDesc.xml` and per-service SCPDs (`WANIPCn.xml`, `WANCfg.xml`, `L3F.xml`).
5. Decoder makes standard SOAP calls on `urn:schemas-upnp-org:service:WANIPConnection:1`: `GetConnectionTypeInfo`, `GetStatusInfo`, `GetNATRSIPStatus`, `GetExternalIPAddress`. The Livebox answers; decoder now has WAN info (public IP, NAT status, etc.).
6. Decoder opens TLS to `oras.vo.orange.fr:7443` (Orange-side STB infrastructure; the hostname appears in the SNI of the captured TLS Client Hello, and the IP `185.145.78.96` is in Orange's address space).
7. **Mutual TLS handshake** with Orange. The decoder presents a client certificate that Orange's server validates against the subscriber line's identity.
8. Once mTLS succeeds, decoder fetches subscriber/STB configuration from Orange's cloud, then begins normal operation including IGMP joins for live multicast.

The Livebox is the source of the device/subscriber identity used in step 7. Without it, step 7 fails and activation stops with G01.

### Side-channel: gateway:443 HTTPS

The decoder also opens a TLS connection to its default gateway on port 443 during the activation sequence. On a normal Livebox-present setup, the Livebox listens with a Livebox-issued certificate and responds to a Livebox-local API call (likely a TR-064-style SOAP endpoint). On a BPI-R3 setup with default LuCI, `uhttpd` presents an OpenWrt self-signed certificate; the decoder responds with a TLS Alert (consistent with `bad_certificate` / `unknown_ca`) and RSTs the connection.

**This side-channel has been bisected and confirmed not to be the activation blocker.** Disabling `uhttpd` on 443 makes no difference to the G01 symptom. The gateway:443 call may be used for advanced features (remote PVR, Orange TV app local control) but is not gating activation itself.

### What's confirmed at each layer

Three layers of the activation chain have been characterised. The first is solvable; the second is a side-channel; the third is the actual blocker.

#### Layer 1: SSDP UPnP IGD discovery — solvable with `miniupnpd`

Without anything on the LAN advertising itself as `InternetGatewayDevice:1`, the decoder's M-SEARCH gets no response, no `LOCATION:` URL, no description XML to fetch. The decoder hangs on "Association de livebox" until timeout → G01.

OpenWrt's standard `miniupnpd-nftables` package fully satisfies this layer. It advertises the router as `urn:schemas-upnp-org:device:InternetGatewayDevice:1`, serves a vanilla IGD description XML on port 5000, and responds correctly to the standard `WANIPConnection:1` SOAP actions the decoder calls. This is **definitively confirmed**: a working Livebox's own IGD description (captured separately — see "Decoder identification and DHCP behaviour" below) is bog-standard UPnP IGD v1 with the same service URN tree miniupnpd advertises and no Orange-specific extensions. The decoder's IGD-discovery requirement is generic, not Orange-flavoured.

Captured behaviour with miniupnpd present:

- Decoder sends M-SEARCH, miniupnpd responds with `LOCATION: http://192.168.1.1:5000/rootDesc.xml`.
- Decoder GETs `rootDesc.xml`, then `WANIPCn.xml`, `WANCfg.xml`, `L3F.xml` (User-Agent: `POSIX SAH DLNA Stack/1.0 UPnP/1.0 DLNADOC/1.50`, SAH = SoftAtHome).
- Decoder POSTs SOAP calls to `/ctl/IPConn`: `GetConnectionTypeInfo`, `GetStatusInfo`, `GetNATRSIPStatus`, `GetExternalIPAddress`. All return HTTP 200 OK with real WAN data.

**Conclusion**: no Orange-specific UPnP services are needed in the IGD itself. A vanilla IGD is enough for the decoder to progress to the cloud-side activation step. Install on the BPI-R3:

```sh
apk update
apk add miniupnpd-nftables luci-app-upnp

uci set upnpd.config.enabled='1'
uci set upnpd.config.enable_natpmp='0'
uci set upnpd.config.enable_upnp='1'
uci set upnpd.config.secure_mode='1'
uci commit upnpd
/etc/init.d/miniupnpd enable
/etc/init.d/miniupnpd start

# verify
ss -ulnp | grep 1900            # SSDP listener
ss -tlnp | grep ':5000'         # HTTP description server
```

#### Layer 2: gateway:443 HTTPS endpoint — Livebox-local API check (role uncertain)

Decoder opens TLS to its default gateway on port 443 and expects a Livebox-style HTTPS endpoint. With OpenWrt's `uhttpd` self-signed cert, the handshake fails with a TLS Alert from the decoder side, decoder RSTs.

The Livebox runs a local management API; the SoftAtHome firmware family calls it "Sysbus" (a D-Bus-based service exposing device state and commands). The decoder is plausibly calling into that API to validate its environment as a real Livebox. The specific endpoint(s), request payload(s), and what the decoder validates in the response are not known from our captures; community guides have proposed specific URLs but those claims need first-hand verification on a real Livebox before being treated as fact.

We've now verified the certificate-chain side of this layer (see "Livebox TLS certificate chain" under the Verified DHCP/UPnP section below): the Livebox presents a per-device leaf cert signed by an `Orange Devices Generic4 CA` intermediate, which chains to `Orange Devices Root CA` (Orange-controlled root). The decoder almost certainly has this root burned into its firmware as a trust anchor. This effectively means a "fake Livebox" service at the BPI-R3's gateway:443 cannot present a cert the decoder accepts without first extracting a real Livebox device certificate (and its private key) from physical hardware — see way forward #5.

What we can say from our own captures:

- The decoder opens TLS to the gateway IP on port 443.
- It sends a TLS Client Hello, receives the server's certificate, then closes the connection (TLS Alert from the decoder side, consistent with `bad_certificate` / `unknown_ca`).
- The router's `uhttpd` self-signed cert does not satisfy whatever trust check the decoder performs.

Disabling `uhttpd` HTTPS so port 443 returns ECONNREFUSED produces the same G01 symptom. **This is not a conclusive bisection** — if the gateway:443 check and the Orange-cloud mTLS handshake (layer 3 below) are both required preconditions, disabling either one will produce G01. To tell which is the actual gate, both endpoints would need to succeed simultaneously, then disable each in turn. We have not done that.

So from the evidence so far, layer 2 could be: (a) not required for activation, (b) one of two required preconditions, or (c) the actual blocker, with the layer-3 Orange handshake being a downstream consequence. Treat its role as **open**.

Solving layer 2 in practice would require either:

- A "fake Livebox" service responding on the router's gateway:443 with the API shape the decoder expects, **and** a TLS cert chained to `Orange Devices Root CA` (verified, see Verified section below). A self-signed cert isn't enough; only a real Livebox device certificate (and its private key) extracted from physical hardware will work. Per-line provisioning means a cert from a different subscriber's Livebox probably won't either — the leaf CN encodes the line's specific OUI/model/serial. Community Python/Lua scripts to emulate the *API shape* exist in scattered forum posts, but they can't solve the cert wall on their own.
- Bypassing the gateway:443 check entirely by having the decoder talk directly to Orange (see the Brouter approach under "Possible ways forward").

#### Layer 3: Orange cloud mTLS handshake — a blocker, possibly the only one

After successful IGD discovery, the decoder opens TLS to `oras.vo.orange.fr:7443`. The captured handshake:

```
decoder → Orange   SYN
Orange  → decoder  SYN-ACK
decoder → Orange   190 bytes  (TLS Client Hello, SNI: oras.vo.orange.fr)
Orange  → decoder  5254 bytes (Server Hello + Certificate, in 4 TCP segments)
decoder → Orange   ACK (no payload)
[5 second pause; decoder sends nothing further]
Orange  → decoder  FIN
```

The decoder receives Orange's full Server Hello + Certificate, ACKs receipt, and then sends nothing. In a normal TLS 1.2 handshake the decoder should follow with `ClientKeyExchange + ChangeCipherSpec + Finished`. It doesn't. After 5 seconds, Orange closes the connection. The decoder times out → G01.

The 5254-byte server response is large for Server Hello + Certificate alone. It is consistent with Orange's response containing a `CertificateRequest` TLS message — i.e. **Orange is requiring mutual TLS** and asking the decoder to present a client certificate. The decoder's silence after receiving the request is the well-known symptom of a TLS client that has no client certificate to send (or no certificate that matches the CA filter Orange's `CertificateRequest` specifies).

In a normal Livebox-present setup, the decoder either:

- Receives subscriber-specific credentials (cert/key, or auth token wrapping a cert) from the Livebox over a local API at boot, then presents those in its mTLS handshake against Orange's cloud, or
- Has a per-decoder device certificate provisioned at first activation, signed by an Orange-controlled CA that whitelists devices tied to an active Livebox subscriber line.

Either way, the credentials live in or pass through the Livebox. Without the Livebox, the decoder has nothing valid to present, and Orange's STB cloud refuses the handshake.

Note: as discussed in Layer 2, we have not bisected definitively whether the gateway:443 Sysbus check and this layer-3 mTLS handshake are both required, or just one of them. A reader testing this should keep both candidate blockers in mind.

**Plausible model** (consistent with all observations, but not yet directly verified): the decoder has its own per-device cert provisioned by Orange at decoder activation, signed by the same Orange CA hierarchy that signs Livebox certs. The decoder uses this cert as a client cert in mTLS to both the Livebox's local Sysbus API (Layer 2) and Orange's cloud (Layer 3). On Layer 3, the decoder may additionally include a session token or state derived from a successful Layer 2 Sysbus call — which would explain why the broken-setup test (no working Sysbus, miniupnpd-only) saw the decoder reach Orange's TLS handshake but go silent after the server's `CertificateRequest`: it couldn't satisfy the certificate request because it lacked the Sysbus-derived state, not because its cert itself is invalid. If this model is right, **option 2 (Phase 6 + Livebox-on-LAN, hybrid) should successfully activate the decoder** because a real Livebox would provide the Sysbus state. The option-2 captures will confirm or refute this.

### What this rules out (with caveats)

Several plausible-sounding hypotheses are contradicted by the evidence collected so far. Caveats noted where the evidence is suggestive rather than conclusive:

- **Phase 7 multicast plumbing alone won't fix this.** Live TV and VOD both fail before multicast becomes relevant. Configuring VLAN 840 + `igmpproxy` + firewall rules is still required for live TV once activation works, but it's not the activation fix.
- **Bridging the decoder onto VLAN 840 is not the activation fix.** Decoder is doing LAN-side UPnP discovery, not VLAN-840-side anything. Activation traffic to Orange goes out the regular data VLAN (832), not VLAN 840. (However, bridging the decoder onto VLAN 832 — the Brouter approach — is a separate proposal worth considering, see "Possible ways forward".)
- **Missing DHCP vendor options is not visibly the cause** in the captures we took. The decoder didn't issue a fresh DHCPREQUEST during the activation window (lease was cached from earlier), so we couldn't observe what options it asks for or whether it cares about the OFFER's contents. Community write-ups suggest DHCP Option 125 may be relevant; see "Community claims to consider" below.
- **DNS filtering (AdGuard) is not visibly the cause.** Decoder made no DNS queries at any point during the captured activation window — it used gateway IP and the hardcoded `oras.vo.orange.fr` (the SNI is the only place that hostname appears). Different decoder firmwares may behave differently.
- **Self-signed cert on gateway:443 is not conclusively the sole blocker.** Disabling 443 entirely produces the same G01, but this could mean either (a) it's not required, or (b) it's one of several preconditions that all need to be satisfied — see Layer 2 above.
- **Bridging the Livebox into the LAN without fibre may not work either.** Some Livebox firmware refuses to advertise UPnP services or otherwise function when it detects no upstream PON link. Unverified.

### Decoder identification and DHCP behaviour (verified from a working line baseline)

Packet captures from a working Orange France line — Livebox S terminating fibre, a Sagemcom WHD-series decoder on Livebox WiFi — gave the following verified data. These are the values to start from when emulating Livebox-side behaviour or setting up a non-Livebox DHCP server that the decoder will accept. The specific values come from one decoder unit; older or newer generations may use different strings.

**Decoder identifies itself in DHCP with**:

- **Source MAC**: Sagemcom OUI (`64:18:DF:XX:XX:XX` shape — `64:18:DF` is registered to Sagemcom Broadband SAS in the IEEE OUI database).
- **Option 60 (Vendor Class Identifier)**: exact string `sagem` (5 ASCII chars). Not `sagemcom`, not `sagemcom_WHD94`, just `sagem`.
- **Option 77 (User Class)**: exact string `PC_MLTV_WHD95`. The `WHD95` model code matches the actual decoder; community summaries citing `WHD94` for the same generation appear to have been wrong (or referring to a different sub-model).
- **Option 125 (Vendor-Identifying Vendor-specific Info)**: 8-byte option using **enterprise number 1368** (Sagemcom's IANA PEN, hex `00 00 05 58`), with a single 3-byte sub-option `0d 01 01` (sub-option code 13, length 1, value 1 — meaning unpublished by Sagemcom but probably "device type = STB" or similar).
- **Option 55 (Parameter Request List)**: requests these options, in order — subnet mask (1), default gateway (3), DNS (6), log server (7), hostname (12), domain name (15), broadcast address (28), static route (33), NTP (42), vendor option (43), WWW server (72), classless static route (121), Vendor-Identifying Vendor-specific Information (125).
- **Option 57 (Max DHCP Message Size)**: 598 bytes.

**Livebox responds in DHCP OFFER/ACK with**:

- **Domain Name (Option 15)**: `home`.
- **DNS (Option 6)**: the Livebox's own LAN IP (typically `192.168.x.1`).
- **Lease time (Option 51)**: 3600 seconds (1 hour). This is why DHCP exchanges become visible during a power-cycle of the decoder if the lease has expired.
- **Renew time (Option 58)**: 1800 seconds.
- **Rebind time (Option 59)**: 3150 seconds.
- **Option 125 (Vendor-Identifying Vendor-specific Info)**: 48-byte option using **enterprise number 3561** (ADSL Forum / TR-069 lineage, hex `00 00 0d e9`), carrying 43 bytes of data length-prefixed (the `2b` byte) and split into three sub-options:

  | Sub-option | Length | Content (ASCII) | Meaning |
  |---:|---:|---|---|
  | `04` | 6 | `6475DA` | Livebox's MAC OUI as ASCII (Sagemcom Broadband SAS) |
  | `05` | 15 | `JA12345AV000000` (example shape) | Livebox's serial number |
  | `06` | 16 | `Livebox Nautilus` | Livebox model name (matches the user-class string the Livebox itself uses for upstream DHCP authentication) |

**Ready-to-paste `dnsmasq` form** for emulating the Livebox's Option 125 OFFER (substituting your own Livebox's OUI / serial / model for the ASCII fields, and adjusting the sub-option length bytes plus the leading `2b` total-data-length and `30` option-length accordingly):

```
dhcp-option-force=tag:decoder,125,00:00:0d:e9:2b:04:06:36:34:37:35:44:41:05:0f:4a:41:31:32:33:34:35:41:56:30:30:30:30:30:30:06:10:4c:69:76:65:62:6f:78:20:4e:61:75:74:69:6c:75:73
```

**What we don't yet know**: whether the decoder *requires* this Option 125 in the OFFER for activation to succeed. The decoder asks for it in its Parameter Request List, but requesting an option doesn't mean refusing to function without it. Empirical test: stand up a non-Livebox DHCP server with and without the Option 125 entry, see whether activation behaviour changes.

**IPTV multicast on the working line uses SSM (Source-Specific Multicast)**: the decoder joined `232.0.3.15` during channel viewing (captured as an IGMPv2 leave message when it switched off). Orange France's live-TV multicast is in the `232.0.0.0/8` SSM range. The decoder issues IGMP joins on its LAN-side IP and the Livebox handles the upstream relay; we don't have a capture of the Livebox WAN side to confirm whether the upstream traffic is on VLAN 832 (unified VLAN model) or VLAN 840 (legacy model).

**Decoder's own UPnP advertisements** (it advertises itself, separately from being a consumer of the Livebox's services) — verified from `curl http://<decoder>:42300/description.xml`:

- friendlyName: `Decodeur TV Orange`
- manufacturer: `SoftAtHome`
- modelName: `SoftAtHome Media Renderer`, version `1.7.19`
- Services: `AVTransport:1`, `ConnectionManager:1`, `RenderingControl:1`, `urn:orange.com:service:RemoteControl:1`

These are services the Orange TV mobile app consumes via the decoder (for in-home remote control of the STB). Not relevant to the decoder-to-Livebox activation flow, but useful confirmation that the decoder's UPnP stack is SoftAtHome-branded.

**Livebox TLS certificate chain on port 443** — verified from `openssl s_client -connect <livebox-ip>:443 -showcerts`. The Livebox presents a real PKI chain controlled by Orange:

| Position | Subject | Issuer | Algorithm | Validity |
|---|---|---|---|---|
| **Leaf** | `C=FR, O=Orange, CN=<OUI>-Livebox Nautilus-<serial>` (per-device) | `Orange Devices Generic4 CA` | EC P-384, ECDSA-SHA256 | 15 years (issued at device activation) |
| **Intermediate** | `Orange Devices Generic4 CA` | `Orange Devices Root CA` | RSA 4096, SHA256 | 23 years (2014→2037) |
| **Root** | `Orange Devices Root CA` (self-signed) | self | RSA 4096, SHA256 | 30 years (2011→2041) |

The leaf CN format is `<OUI>-<Model>-<Serial>` (literally the three fields the Livebox also advertises in DHCP Option 125 sub-options 04/05/06 — see DHCP section above). Subject Alternative Name on the leaf includes the IP literal `192.168.1.1` (the Livebox's *default* LAN IP, not necessarily its current one if the user has changed the LAN subnet).

CRL distribution URLs point at `pki-crl.security.intraorange/...` (Orange-internal) and `pki.orange.com/...` (Orange-public).

**Critical implication for "fake Livebox" approaches**: the decoder almost certainly has `Orange Devices Root CA` burned into its firmware as a trust anchor. To produce a leaf cert it will accept, you need a signing chain back to that root — meaning either:

- The private key of an Orange intermediate CA (lives only inside Orange's PKI infrastructure; not extractable in normal circumstances)
- The leaf private key from a real, line-active Livebox (only obtainable by rooting a physical Livebox and extracting from its filesystem)
- Modifying the decoder firmware to trust a different root (very hard)

This effectively confirms what the Phase 7 doc already speculates: Sysbus / Livebox-API emulation as a path to decoder activation requires Livebox cert extraction, which is its own deep engineering project with no guarantee the cert is reusable across subscriber lines.

**Other Livebox services** — from a port scan (`nmap -sT -p 1-65535` against the Livebox LAN IP), the listening ports are:

| Port | Service | Notes |
|---:|---|---|
| 53 | DNS | Standard local resolver |
| 80 | HTTP | Admin UI redirect to HTTPS, possibly some internal endpoints |
| 443 | HTTPS | Admin UI + Sysbus API (see Layer 2 above) |
| **8883** | secure-MQTT | MQTT-over-TLS. Presents the **same Livebox device certificate** as port 443. Probed with a TLS 1.3 handshake: broker terminates with `certificate_required` alert (SSL alert 116) when no client cert is presented. **Confirms: enforces mutual TLS — clients must present a certificate signed by an Orange CA.** Same pattern as Sysbus; same wall. Decoder presumably has its own Orange-issued per-device cert it uses to authenticate to Livebox services. |
| 60000 | UPnP description | The IGD service (see above) |

The Sysbus API on port 443 is reachable but gated. Direct probes from outside the Livebox return `504 Gateway Timeout` (reverse proxy timeout — backend exists but isn't responding) or `400 Bad Request` depending on path. Likely behind session auth (cookies from Livebox admin login), client-cert requirement, or source-MAC filtering. Successfully reaching it doesn't enable emulation anyway (cert chain locks that out per the analysis above).

**Livebox SOAP IGD calls** — verified from `curl -X POST 'http://192.168.3.1:60000/.../upnp/control/WANIPConn1'`. The Livebox responds to standard SOAP calls (e.g. `GetExternalIPAddress` returns the actual public IP, `GetStatusInfo` returns link state). `miniupnpd` on OpenWrt serves the equivalent responses by default — no Orange-specific behaviour at this layer.

**Livebox UPnP advertisements** — verified from a captured `gssdp-discover` response and a follow-up `curl` of the description URL. The Livebox replies to SSDP M-SEARCHes unicast back to the requester (not via multicast), so the request has to come from a host that will see the response — `gssdp-discover` from a laptop on the Livebox WiFi works, or a Python script from the BPI-R3 itself sending the M-SEARCH from a fixed source port.

SSDP advertisement (`urn:schemas-upnp-org:device:InternetGatewayDevice:1`):

```
USN: uuid:<random-uuid>::urn:schemas-upnp-org:device:InternetGatewayDevice:1
LOCATION: http://<livebox-ip>:60000/<8-hex-digits>/gatedesc1.xml
```

The 8-hex-digits prefix appears to be a per-boot identifier. The port 60000 is consistent across captures.

Description XML (`gatedesc1.xml`) is **bog-standard UPnP IGD v1** — no Orange-specific service URNs at any level. Verbatim structure from a working Livebox S:

| Element | Value |
|---|---|
| `<deviceType>` | `urn:schemas-upnp-org:device:InternetGatewayDevice:1` |
| `<friendlyName>` | `Orange Livebox` |
| `<manufacturer>` | `Arcadyan` (matches the Option 60 `arcadyan` value the Livebox uses for upstream DHCP authentication; firmware lineage detail confirmed at the UPnP layer too) |
| `<manufacturerURL>` | `https://www.arcadyan.com` |
| `<modelName>` | `Residential Livebox (GPON, WAN Ethernet)` |
| `<modelDescription>` | `Arcadyan,fr,ARNA-fr-G01.R06.C01_04` (firmware version string) |
| `<modelNumber>` | `4+` |
| `<serialNumber>` | Livebox serial (matches the value seen in DHCP Option 125 sub-option 05) |
| `<presentationURL>` | `http://<livebox-ip>` (the Livebox admin web UI) |

Embedded Microsoft PnP-X metadata (Windows discovery hints):

- `X_hardwareId`: `VEN_0129&DEV_0000&SUBSYS_03&REV_250417`
- `X_compatibleId`: `GenericUmPass`
- `X_deviceCategory` (PnP-X): `NetworkInfrastructure.Gateway`
- `X_deviceCategory` (Device Foundation): `Network.Gateway`

Nested device tree and services:

```
InternetGatewayDevice:1
  (no services on the root device beyond the standard PnP-X metadata above)
  └── WANDevice:1
        ├── service: urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1
        │       SCPD: /<prefix>/gateicfgSCPD.xml
        │       controlURL: /<prefix>/upnp/control/WANCommonIFC1
        └── WANConnectionDevice:1
              └── service: urn:schemas-upnp-org:service:WANIPConnection:1
                      SCPD: /<prefix>/gateconnSCPD_IP.xml
                      controlURL: /<prefix>/upnp/control/WANIPConn1
```

**Significant finding**: the Livebox's UPnP IGD has **no Orange-specific service URNs at any level**. Everything is bog-standard UPnP IGD v1. This means OpenWrt's `miniupnpd-nftables` package (which advertises exactly the same standard service set) is sufficient for the IGD-discovery layer of decoder activation. The Orange-specific stuff (Sysbus API on gateway:443, mTLS to Orange cloud) is **not** in UPnP — those are separate services the decoder reaches via other means (hardcoded URLs, probably).

Service SCPDs (action definitions) — fetched and verified standard:

- `WANCommonInterfaceConfig:1` at `/<prefix>/gateicfgSCPD.xml`: `GetCommonLinkProperties`, `GetTotalBytesSent`, `GetTotalBytesReceived`, `GetTotalPacketsSent`, `GetTotalPacketsReceived`. Standard IGD v1.
- `WANIPConnection:1` at `/<prefix>/gateconnSCPD_IP.xml`: `SetConnectionType`, `GetConnectionTypeInfo`, `RequestConnection`, `RequestTermination`, `ForceTermination`, `Set/GetAutoDisconnectTime`, `Set/GetIdleDisconnectTime`, `Set/GetWarnDisconnectDelay`, `GetStatusInfo`. Standard IGD v1.

No Orange extensions, no custom actions. `miniupnpd` implements the standard correctly; no need to do anything special at this layer for emulation.

### Community claims to consider (unverified)

These topics come from community discussion of Orange-decoder-without-Livebox setups but have **not** been validated against captures or testing in this project. Listed for awareness so a reader knows what to investigate further; treat each as a starting point, not as confirmed.

#### Decoder generation matters

Behaviour observed in this project is from a single decoder unit (Sagemcom WHD-series, identifying as `PC_MLTV_WHD95` in DHCP — see verified DHCP details above). Different decoder generations are likely to behave differently. Orange has shipped several generations (often referred to in the community as TV 4, TV UHD, TV 6, etc.), with physical and firmware differences between them. Visual identification varies by generation: older units tend to be plain black plastic boxes, newer ones (TV 6 era) have rounded corners and a fabric finish.

The simplest reliable way to identify your decoder is to look at the User-Class string (Option 77) it sends in DHCP. The MAC OUI gets you to "Sagemcom-built" but doesn't pin the model.

Specific advice claimed for specific generations (e.g. "the Brouter approach works for TV 6 but not TV 4") is repeated in community summaries but the underlying primary evidence has not been independently verified here. Read the lafibre.info threads directly before committing to a generation-specific approach.

#### Which IPTV VLAN your line uses

Older Orange FTTH deployments used VLAN 840 for live-TV multicast, separate from VLAN 832 for data. Community discussion suggests that more recent deployments unify everything onto VLAN 832 — internet, VoD, and live-TV multicast all multiplexed on a single VLAN, with prioritisation handled via 802.1p (PCP) marking. The transition timing and which deployments are affected is community-claimed rather than documented in any primary source we've verified.

What we can confirm from the working baseline capture on the line in this project: **the decoder uses SSM in the `232.0.0.0/8` range** for live-TV multicast (specifically captured: a join/leave for `232.0.3.15` on the Livebox-LAN side). This tells us the multicast group address family, but not which VLAN tag the upstream traffic uses — the Livebox does whatever VLAN handling it does internally between its WAN and its LAN, and that boundary isn't visible from the BPI-R3 in the current topology.

**How to tell what your line uses on the WAN side**: capture traffic on the Livebox's WAN-side fibre interface (only possible if you can SSH into the Livebox — generally you can't on stock firmware), or capture on the SFP cage of a router terminating fibre directly (i.e. Phase 6 setup with the BPI-R3 owning the fibre). If you see IGMP membership reports and multicast group traffic on VLAN 832, your line uses the unified model. If you see them on VLAN 840, you're on the legacy model. This determines whether the multicast plumbing in the lower half of this document applies, or whether something like the Brouter approach handles multicast at L2 implicitly.

The original Phase 0 capture in this project saw VLAN 840 referenced in the Livebox S admin UI, but that may reflect legacy fields the firmware still exposes rather than actual current usage.

#### DHCP Option 125: now characterised (see verified section above)

Option 125 exchange is now characterised from a working line — see "Decoder identification and DHCP behaviour" above for the exact contents in both directions, with a ready-to-paste `dnsmasq` configuration example.

What remains uncertain: whether the decoder *requires* the Livebox's Option 125 in the OFFER, or whether it functions without it. The decoder requests Option 125 in its Parameter Request List, but requesting an option doesn't mean refusing to function without one. Empirical test would be to stand up a non-Livebox DHCP server, omit Option 125, see whether the decoder shows W04 ("can't find Livebox") or proceeds normally.

#### PCP marking on VLAN 832

Phase 5/6 in this project uses uniform PCP 6 on VLAN 832 egress, and this works for the router's WAN authentication. Some community guides suggest that Orange's BNG drops DHCP frames with PCP 0 (no priority marking), but accepts PCP 6 — consistent with our experience. Other guides suggest that different traffic classes on VLAN 832 should get different PCP values (PCP 6 for signaling, PCP 5 for video, etc.); we have not verified whether this is required or whether uniform PCP 6 is sufficient.

For a Brouter setup where the decoder's traffic exits the same VLAN 832, the egress QoS mapping on the bridged WAN device should preserve whatever PCP the decoder marks at L2 (or apply a default if the decoder doesn't mark). Specific recommended UCI snippets seen in community guides should be tested before relied on; an example mapping seen in one source (`'0:0 1:0 2:0 3:0 4:0 5:5 6:6 7:0'`) only differentiates PCP if the kernel's internal priority is already set to 5 or 6 via separate rules, which most home setups don't have. Uniform PCP 6 across egress (current Phase 5/6 config) is the pragmatic default.

#### Possibly stale or context-dependent

These come from external write-ups but didn't match our captures, or look like cargo-cult advice — listed for completeness rather than as recommendations.

- **DNS hijacking of `livebox.home`** to point at the router's IP. Our captures showed zero DNS queries from the decoder during activation, so this may be stale advice or apply to a different firmware. Don't configure speculatively.
- **Specific Orange STB IP ranges** (often-cited examples like `193.253.148.0/24`, `80.10.117.0/24`) as static routes. Address ranges change; empirically confirm against actual decoder traffic before adding static routes.
- **Forcing the decoder to use Orange's DNS resolvers** (e.g. `80.10.246.2`, `80.10.246.129`). May matter post-activation for content delivery; not visibly relevant during the activation handshake itself.

If any of these turn out to apply to your setup, document the result so future readers can rely on it rather than re-deriving.

## Possible ways forward

None of these have been validated end-to-end in this project. Listed as candidates worth investigating, ranked roughly by effort and reported feasibility from community sources.

### 1. Hybrid: Livebox-in-line as a TV + VoIP appliance on the LAN (recommended primary path)

The full picture this resolves to is: the **BPI-R3 owns the fibre and the main LAN**, while the **Livebox sits behind the BPI-R3 as a dedicated appliance** providing local services to Orange-locked devices (TV decoder, RJ-11 phone). Everything else (laptops, phones, AdGuard, Jellyfin, WireGuard) lives on the BPI-R3 LAN with full Phase 6 benefits.

#### End-state topology

```
                    ┌──────────────────────────────────────────┐
                    │              BPI-R3                      │
   [fibre]─→ MA5671A→ sfp1.832 ──┬──→ network.wan              │
                    │            │    (direct GPON, public IP) │
                    │            │                             │
                    │  br-lan: 192.168.1.0/24                  │
                    │   ├── WiFi: phones, laptops, smart home  │
                    │   ├── AdGuard, Jellyfin, WireGuard       │
                    │   └── lan4 → ───┐                        │
                    └─────────────────│────────────────────────┘
                                      │ ethernet
                                      ↓
                              ┌───────────────────┐
                              │     Livebox       │
                              │ WAN: 192.168.1.x  │ (DHCP from BPI-R3)
                              │ LAN: 192.168.3.0/24
                              │  ├── WiFi         │
                              │  │   └── decoder  │ (e.g. 192.168.3.7)
                              │  ├── RJ-11 phone  │
                              │  └── status LED: "no fibre" (services up regardless)
                              └───────────────────┘
```

#### What works where

| Service | Path | Phase 6 benefit |
|---|---|---|
| Internet for BPI-R3 LAN clients | Client → BPI-R3 → fibre | **Yes**: single NAT, public IPv4, IPv6 /56, no Livebox bottleneck |
| Decoder activation against Orange cloud | Decoder → Livebox (local Sysbus, cert handshake) → BPI-R3 NAT → Orange cloud | Indirect: relies on Livebox holding its own cert; works because the Livebox cert is portable across network paths |
| Live TV multicast | Orange → fibre → BPI-R3 sfp1.832 → `igmpproxy` to br-lan → Livebox WAN → Livebox bridges to WiFi → decoder | Requires `igmpproxy` plumbing on BPI-R3 (see this document's existing multicast section) |
| VOD on the decoder | Decoder → Livebox NAT → BPI-R3 NAT → fibre → Orange VoD CDN | Double-NAT but unicast HTTPS — works fine |
| VoIP (RJ-11 phone) | Livebox SIP client → BPI-R3 NAT → fibre → Orange SIP infrastructure | Resolves Phase 8 pragmatically without SIP credential extraction — see [`14-phase8-voip.md`](14-phase8-voip.md) |
| Inbound services (WireGuard, etc.) | External → BPI-R3 public IP | **Yes**: hosted on BPI-R3, no Livebox port forwarding needed |
| Livebox remote management by Orange (TR-069) | Livebox outbound through BPI-R3 NAT | Works |

#### Practical considerations

- The Livebox must be alive enough on the LAN without fibre. On-site observation confirms that the Livebox's **WiFi radios** come up without fibre (the status LED complains about no fibre signal but WiFi clients can associate). **What's not yet verified** is whether the Livebox's local Sysbus / SIP / UPnP services all stay functional in the same no-fibre state. Some CPE firmware gates internal services on detecting upstream connectivity; if the Livebox decides it's "offline" and refuses local API calls, decoder activation will fail. This is one of the things the option-2 test specifically verifies — see "Reasonable test approach" below.
- The Livebox's LAN IP needs to be reachable by the decoder. If the Livebox runs DHCP on a different subnet from the BPI-R3 LAN, the decoder will see the Livebox's SSDP advert (multicast crosses subnets at L2) but won't be able to fetch the description URL. Either move the Livebox to the BPI-R3 LAN subnet, or just let the Livebox keep its own LAN segment behind its WAN port (the Livebox NATs between its LAN and its WAN, so as long as the decoder reaches the Livebox at its LAN IP, things work).
- Turn off `miniupnpd` on the BPI-R3 if you had it running, so the decoder picks the Livebox unambiguously.
- IGMP proxy on the BPI-R3 is needed for live-TV multicast to flow from the fibre side to the Livebox (and through the Livebox to the decoder). See the Steps section below.

#### What you gain vs. what you keep

**Gain**:
- Phase 6 benefits for all non-decoder devices: direct GPON, single NAT, public IPv6, SQM/QoS control on the BPI-R3
- Inbound services (WireGuard, port-forwards) hosted on the BPI-R3 public IP directly
- Better demarcation: Orange-locked services on Orange hardware; everything else under your control

**Keep**:
- The Livebox as a permanent fixture (~10W continuous, takes a shelf)
- Decoder activation tied to the Livebox being on (some decoders cache activation state for hours/days; others re-validate per boot — empirical)
- VoIP tied to the Livebox firmware (no migration off Orange SIP)
- One extra device in the topology with its own failure mode

**Don't gain** vs. current Phase 1 state:
- Fewer devices
- Power savings
- Full elimination of Orange-supplied hardware

This is the realistic best-case outcome of the Phase 7 investigation: not a full Livebox elimination (blocked by the Orange-PKI mutual-TLS architecture), but a sensible division of labour where the Livebox keeps doing what only Orange-issued hardware can do, and the BPI-R3 takes everything else.

### 2. Brouter (Bridge-Router): full Livebox elimination — untested, lower confidence than the hybrid

**Status: proposed, not tested in this project.** The most ambitious of the Phase 7 paths — if it works, the Livebox is gone entirely (for TV; VoIP needs a separate solution, see below). Discussed in community threads on lafibre.info as a candidate path for TV 6 decoders specifically; we have not seen a verified end-to-end procedure for this decoder generation, only second-hand summaries (some of which turned out to be unreliable on verification — see the source-trust note near the top of the activation prerequisite section).

#### The idea

Rather than have the decoder be a LAN client behind the router's NAT (or behind a Livebox), **bridge a dedicated LAN port to the WAN VLAN device** so the decoder is on Orange's VLAN 832 at Layer 2, with its own MAC, its own DHCP from Orange's BNG, and (if its credentials are self-sufficient) its own activation against Orange's cloud — bypassing both the Livebox's Sysbus check and the requirement for a Livebox to be on the LAN at all.

#### Why this might work

The decoder has its own Orange-issued per-device certificate (inferred from the verified cert-chain analysis — the decoder authenticates to the Livebox's local Sysbus / MQTT via mTLS in the working setup, which means it must own a cert in the Orange PKI). That cert authenticates the decoder to Orange wherever its traffic originates from. If Orange's BNG provisions DHCP for the decoder's MAC and the decoder's own cert is sufficient for Orange cloud activation (i.e. activation does *not* require a Livebox-mediated Sysbus session token), Brouter works.

#### Why this might not work

The cross-layer hypothesis from the Phase 7 investigation (see Layer 3 section above) is that the decoder needs Sysbus-derived state from a Livebox to satisfy Orange's cloud TLS handshake. Brouter removes the Livebox entirely. So:

- **If the cross-layer hypothesis is right**: Brouter cannot work for activation. The decoder will reach Orange cloud, send TLS Client Hello, receive cert + CertificateRequest, then stall (same pattern as the previous broken-setup test).
- **If the hypothesis is wrong**: Brouter works, and the decoder's own cert is sufficient. The hypothesis being wrong is a useful finding in itself — the simpler "decoder cert is enough" model would be the right one.

**Brouter is a falsifying test for the cross-layer hypothesis.** The test result is informative either way.

#### Topology

```
[fibre] → MA5671A → BPI-R3 sfp1.832 ─→ bridge br-wan-tv ─┬─ network.wan (router DHCP session)
                                                          │   - cloned Livebox MAC
                                                          │   - Phase 5/6 options (Option 60 'arcadyan',
                                                          │     Option 77 LiveboxNautilus, Option 90 auth)
                                                          │
                                                          └─ lan4 (dedicated decoder port)
                                                              │
                                                              ↓
                                                          TV decoder
                                                          - own MAC (Sagemcom OUI)
                                                          - own DHCP request to Orange BNG
                                                          - own Orange-issued mTLS cert

br-lan (192.168.1.0/24) for other LAN clients, routed/NATed via br-wan-tv
```

#### Verified decoder DHCP options it would present

The decoder's DHCP request goes directly to Orange's BNG on VLAN 832 in this topology, not to the BPI-R3's dnsmasq. The BPI-R3 doesn't need to forge or supply any DHCP options for the decoder; the decoder identifies itself. Verified values from the working baseline capture:

- **Source MAC**: Sagemcom OUI (`64:18:DF:...` for the reference unit)
- **Option 60 (Vendor Class)**: `sagem` (5 ASCII chars)
- **Option 77 (User Class)**: `PC_MLTV_WHD95`
- **Option 125 (Vendor-Identifying VS Info)**: enterprise number `1368` (Sagemcom IANA PEN, `00 00 05 58`), 3-byte sub-option `0d 01 01`
- **Option 55 (Parameter Request List)**: 1, 3, 6, 7, 12, 15, 28, 33, 42, 43, 72, 121, 125
- **Option 57 (Max DHCP Message Size)**: 598

#### Conceptual config

```sh
# Back up first
cp /etc/config/network /etc/config/network.bak.brouter.$(date +%s)
cp /etc/config/firewall /etc/config/firewall.bak.brouter.$(date +%s)

# Create the bridge containing sfp1.832 + a dedicated decoder port
uci set network.br_wan_tv=device
uci set network.br_wan_tv.name='br-wan-tv'
uci set network.br_wan_tv.type='bridge'
uci add_list network.br_wan_tv.ports='sfp1.832'
uci add_list network.br_wan_tv.ports='lan4'
uci set network.br_wan_tv.igmp_snooping='1'

# Re-target network.wan from sfp1.832 to br-wan-tv
# All other network.wan options (macaddr=cloned Livebox MAC, sendopts including
# Option 60 'arcadyan', Option 77 LiveboxNautilus, Option 90 auth, clientid)
# stay unchanged — they apply via the bridge interface.
# Do not substitute community-claimed alternatives (e.g. Option 60 'sagem' for the
# router's session); the verified Phase 5/6 values are line-specific and stay.
uci set network.wan.device='br-wan-tv'

# Make sure lan4 isn't also in br-lan (depends on current bridge config).
# Inspect first: uci show network.br_lan
# Then remove lan4 from br-lan's ports list if present.

uci commit network
/etc/init.d/network restart
```

**Read this as a sketch, not a recipe.** The exact UCI syntax for the bridge device and how it interacts with the firewall zone configuration needs validation. The bridged lan4 port now carries Orange's VLAN 832 traffic, so it's conceptually on the WAN zone, not LAN. Firewall rules assuming lan4 is in the LAN zone need adjusting — be careful with rules that allow LAN-zone access to BPI-R3 services (LuCI, SSH) so they aren't exposed via the bridged port.

#### What Brouter doesn't solve

- **VoIP**. Without the Livebox, there's no SIP client registering to Orange's voice infrastructure. You need a separate path — port the number to a third-party VoIP provider, or skip landline entirely. See `docs/14-phase8-voip.md`. The Phase 8 hybrid option (keep the Livebox alive for phone only) does **not** apply to a Brouter setup because there's no Livebox in the topology.
- **Orange TV mobile-app remote control of the decoder**. The app talks to the decoder via Orange-managed identity that flows through the Livebox; without a Livebox, the app may not find or control the decoder.
- **Cloud PVR, Orange-bouquet specific features**. Untested; might work, might not.
- **TR-069 telemetry from the Livebox**. Without a Livebox, your line drops out of Orange's management — usually harmless but may affect Orange's tech support if you ever need to call them ("we don't see your Livebox responding").

#### Likelihood (informal)

| Outcome | Rough probability |
|---|---|
| Decoder activates first try | 20-30% |
| Decoder activates after tuning (PCP marking, IGMP snooping, firewall zones) | 10-20% |
| Decoder DHCP succeeds but Orange cloud activation fails the same way as in the broken-setup test (cross-layer hypothesis confirmed) | 30-40% |
| Decoder gets no DHCP from Orange BNG (BNG MAC pre-provisioning, line not configured for multiple devices) | 10-20% |

A clear failure mode is still informative — confirms or refutes the cross-layer hypothesis, which has value for future investigation regardless of the immediate outcome.

#### Comparison with the hybrid (option 1)

| Dimension | Hybrid (recommended) | Brouter (ambitious) |
|---|---|---|
| Eliminates Livebox | No (Livebox stays on LAN) | Yes (if it works) |
| TV expected to work | Yes (high confidence per cert-chain analysis) | Uncertain (depends on cross-layer hypothesis being wrong) |
| VoIP solved | Yes (Livebox handles SIP) | No (need separate path: port number or skip landline) |
| Configuration complexity | Moderate (`igmpproxy` plumbing) | Moderate (bridge + firewall zone reorganisation) |
| Risk of breaking BPI-R3 internet during test | Low (clear rollback) | Low (clear rollback) |
| Diagnostic value of a failure | Tells us where in the activation chain something broke | Tells us whether the cross-layer Sysbus hypothesis is correct |

#### Test procedure

**Pre-requisite**: option 1 (Hybrid) has been tested. Brouter is the "push for full elimination" follow-up. Don't attempt Brouter first; the hybrid has higher likelihood and provides a known-good fallback to return to if Brouter doesn't work out.

1. **Maintenance window**: 1-2 hours, household tolerates internet disruption. Back up `/etc/config/network` and `/etc/config/firewall`.

2. **Apply the bridge config** (see "Conceptual config" above).

3. **Verify the router's own internet still works** before involving the decoder:
   - `ifstatus wan` shows public IP from Orange
   - `ping -c 3 9.9.9.9` from the BPI-R3
   - Test from a LAN client (laptop on BPI-R3 WiFi or wired LAN)
   If broken, rollback before continuing — the bridge config has issues that need fixing first.

4. **Start three parallel captures** before powering the decoder:
   ```sh
   tcpdump -i sfp1.832 -nn -e -s 0 -w /tmp/brouter-sfp.pcap &
   tcpdump -i lan4 -nn -e -s 0 -w /tmp/brouter-decoder.pcap &
   tcpdump -i br-wan-tv -nn -e -s 0 -w /tmp/brouter-bridge.pcap &
   ```

5. **Plug the decoder into the dedicated bridged LAN port**. **Power-cycle the decoder**. Let captures run for 3-4 minutes. Watch the decoder screen. Stop the captures.

6. **Interpret the captures**, in order:

   | What you see | What it means |
   |---|---|
   | DHCPDISCOVER from decoder MAC on sfp1.832, BNG returns DHCPOFFER with Option 125 | BNG is provisioning the decoder. Proceed. |
   | DHCPDISCOVER goes out but no DHCPOFFER comes back | BNG isn't provisioning the second MAC. Brouter doesn't work for this line. Stop. |
   | DHCP succeeds, decoder opens TLS to `oras.vo.orange.fr:7443` | Decoder is reaching Orange cloud. Proceed. |
   | TLS handshake completes — `ClientKeyExchange + ChangeCipherSpec + Finished` from decoder visible | **Success**. Activation likely succeeded. Check decoder screen. |
   | TLS handshake stalls at the same point as the broken-setup test (Server Hello + cert from Orange, silence from decoder, FIN from Orange after 5s) | Cross-layer Sysbus hypothesis confirmed. Brouter cannot work without Livebox state. Stop. |
   | TLS completes but channels don't tune | Multicast routing issue. Check IGMP joins, multicast group traffic on 232.0.0.0/8, PCP marking. Solvable with further tuning. |

7. **Decoder screen outcomes**:

   - **Channels tuning**: success. Document the working config; the Orange France community would find this useful.
   - **Erreur G01 with same TLS-stall pattern**: cross-layer hypothesis confirmed. Brouter doesn't work for this decoder. Rollback.
   - **Erreur W04 or "Pas de DHCP"**: BNG didn't provision. Rollback.
   - **Erreur G01 with successful TLS handshake**: activation passed but something else broke. Could be solvable; investigate captures.

8. **Rollback**:
   ```sh
   cp /etc/config/network.bak.brouter.<timestamp> /etc/config/network
   cp /etc/config/firewall.bak.brouter.<timestamp> /etc/config/firewall
   /etc/init.d/network restart
   /etc/init.d/firewall restart
   ```
   Then reset the decoder to its previous WiFi/wired connection.

#### If Brouter succeeds

End state is fully Livebox-free for TV:

- BPI-R3 owns fibre (Phase 6 + bridge)
- Decoder bridged onto VLAN 832 via dedicated LAN port
- Multicast flows L2 from VLAN 832 to decoder; no `igmpproxy` needed (or only minimal config for snooping)
- VoIP unsolved — port the number to a third-party VoIP provider (Phase 8 path 2) or skip landline (Phase 8 path 4)

Document for the project record:

- The decoder's DHCP exchange with Orange's BNG (BNG-side Option 125 contents, IP allocated, any other options Orange sets)
- Whether IGMP snooping on the bridge mattered, and any specific multicast-related tuning required
- Whether any firewall zone adjustments were needed
- The TLS handshake pattern that succeeded (compared to the previous failed pattern)

This would be a publishable result — the lafibre.info community would benefit.

#### If Brouter fails

The captures tell us specifically *what* failed:

- **No DHCP for decoder MAC**: BNG-side provisioning limitation. Brouter is dead for this line; not your fault, not fixable from your side.
- **DHCP works, TLS handshake stalls**: cross-layer Sysbus hypothesis confirmed. The decoder genuinely needs Livebox-mediated state. Stay on the hybrid.
- **DHCP + TLS work, channels don't tune**: multicast routing issue, possibly solvable with further tuning (PCP marking, IGMP snooping config, firewall rules). Worth a second iteration.

Either way, rollback to the hybrid (option 1) — which is expected to work, and which also solves VoIP.

### 3. Community projects emulating the Livebox

Attempts at "fake Livebox" tools — small scripts or services that emulate the Livebox-local API enough for the decoder to pass its initial check — surface periodically in community discussion. Worth searching:

- lafibre.info forum threads on Livebox replacement (the "Remplacer la Livebox par un routeur" section has active long threads on Orange DHCP and OpenWrt — read the threads themselves, not summaries of them)
- hack-gpon.org for STB-related material
- GitHub search for terms like `livebox`, `softathome`, `orange-stb` — bearing in mind that several confidently-stated repo names that have circulated in summaries (`orange-sysbus-validator`, `OpenOrange`, etc.) don't actually exist. Confirm anything you find is a real, populated repo before trusting it.

Realistic expectations:

- Any specific project name you read in a summary is worth confirming exists; AI-assisted research has been observed to confidently invent plausible-sounding tool names that turn out to be hallucinated.
- Emulation scripts can in principle answer the API calls but cannot solve the per-Livebox TLS certificate problem on their own. Most plausible "fake Livebox" approaches assume you have a real Livebox device certificate (and key) extracted from physical hardware. Without that, the TLS handshake fails at certificate validation regardless of how good the emulated API responses are.
- Orange updates the backend periodically, so historical projects may need adapting to current behaviour.

If a project documents success for your decoder model and firmware **with reproducible captures or a working configuration**, it's worth trying. If all you have is a forum post asserting success without artefacts, treat it as a hypothesis to verify.

### 4. Confirm the mTLS hypothesis by decoding the TLS handshake

Open the Orange handshake capture in Wireshark and look for a `CertificateRequest` message in Orange's first ~5KB after the SYN. Confirms what we already suspect but doesn't directly unblock anything. Useful if a community project disagrees about the activation protocol or if Orange changes their backend.

### 5. Extract a Livebox device certificate

If you have a Livebox and can get filesystem access to it (rooting procedure for the relevant Livebox model), the device certificate (and any associated keys) may be extractable. Then:

- Provision the cert into a local HTTPS server on the BPI-R3 that the decoder is steered to, or
- Use an mTLS-aware proxy that intercepts the decoder's outbound HTTPS to Orange and inserts the client cert.

Both are deep engineering projects. Per-Livebox keys may be tied to the specific subscriber line, so a cert extracted from a Livebox on a different line probably won't work for yours.

### 6. Accept the limitation

Run the BPI-R3 for internet directly (Phase 6). Keep the Livebox plugged in for TV. Live with the partial migration. Reasonable answer if TV is critical and engineering time is limited.

## Diagnostic toolkit

Commands to characterise decoder behaviour on any Orange France BPI-R3 setup:

```sh
# Capture decoder boot to activation failure (replace IP with decoder's lease)
tcpdump -i br-lan -nn -e -s 0 -w /tmp/decoder-boot.pcap host <decoder_ip>

# SSDP / UPnP payload — what the decoder searches for, what it advertises
tcpdump -r /tmp/decoder-boot.pcap -nn -A 'host 239.255.255.250 and udp port 1900' | head -150

# All TCP destinations the decoder tries
tcpdump -r /tmp/decoder-boot.pcap -nn 'tcp[tcpflags] & tcp-syn != 0' | awk '{print $3, "->", $5}' | sort -u

# DNS queries (expected on Orange France: none during activation window)
tcpdump -r /tmp/decoder-boot.pcap -nn 'port 53'

# DHCP exchanges including vendor options
tcpdump -r /tmp/decoder-boot.pcap -nn -vvv 'port 67 or port 68'

# All multicast/broadcast from decoder
tcpdump -r /tmp/decoder-boot.pcap -nn 'host <decoder_ip> and (multicast or broadcast)'

# Full Orange cloud TLS exchange
tcpdump -r /tmp/decoder-boot.pcap -nn 'host 185.145.78.96 or port 7443' | head -60
```

Indicators and what they mean:

- **No SSDP response on the LAN** → no IGD; install `miniupnpd`. Layer 1 is the fix.
- **Decoder SYN to `oras.vo.orange.fr:7443`, receives ~5KB, then silence for 5 s, then Orange FIN** → mTLS failure. Layer 3 is the blocker; see "Possible ways forward".
- **Decoder makes DNS queries during activation** → unusual; the Orange France decoder observed here used hardcoded IPs and made no DNS queries. May indicate a different decoder model or firmware that's worth re-characterising.
- **Decoder reaches Orange and the handshake completes (`ClientKeyExchange` visible)** → activation should succeed. If it doesn't, characterise the next failure (likely an HTTP response from Orange you can examine).

## Once activation is solved

The multicast plumbing in the rest of this document **may or may not be needed**, depending on which Orange topology applies to your line:

- **If your line uses a separate VLAN for IPTV multicast** (historically VLAN 840 on Orange France, especially on older deployments): you need a VLAN 840 device on `sfp1`, DHCP on it, `igmpproxy` to forward multicast into the LAN, and firewall rules permitting IGMP and the multicast destination range. That's the setup below.
- **If your line uses a unified VLAN model** (community reports suggest more recent FTTH deployments multiplex internet, VoD, and live-TV multicast on VLAN 832 alone): the multicast plumbing below isn't relevant. If the decoder is on the LAN side of the router NAT, you'd still need an IGMP proxy on VLAN 832. If the decoder is on a bridged port (Brouter approach, "Possible ways forward" option 1), multicast is switched at L2 and no proxy is needed.

How to tell which model your line uses: capture from a working Livebox's WAN side (or from the SFP cage on a router doing direct GPON). If multicast traffic and IGMP membership reports are on VLAN 840, you're on the legacy model. If on VLAN 832, you're on the unified model.

VOD on Orange France runs over the regular internet path (TLS unicast to Orange's VOD CDN over VLAN 832) regardless of topology — no multicast needed for VOD.

The sections below describe the VLAN 840 + `igmpproxy` path. Use them if you've established that VLAN 840 applies to your service. Otherwise skip and use the appropriate path from "Possible ways forward".

---

## Goal

Make live TV channels work through the OpenWrt router instead of through the ISP modem. Orange France IPTV is a multicast service on VLAN 840; the router needs:

1. A VLAN 840 interface on `sfp1`
2. A DHCP client on that interface to receive an IP from the IPTV side
3. `igmpproxy` running, forwarding multicast from VLAN 840 upstream to the LAN bridge downstream
4. Firewall rules permitting IGMP and the multicast address range

The TV decoder is on the regular LAN (with a static lease, IP `192.168.1.12` in this project). It joins multicast groups via IGMP; the proxy translates those joins upstream to VLAN 840, and forwards the multicast payload back down.

## Success criteria

- The TV decoder, on the router's LAN, tunes live channels reliably
- Channel zapping (switching) is responsive (< 2 s)
- No multicast errors in `logread` over a typical evening of TV
- Other LAN traffic is not impacted

## Pre-requisites

- Phase 6 complete (internet via direct GPON)
- **Decoder activation working** — see "Activation prerequisite" above. This is the harder problem. Until it's solved, multicast plumbing alone won't make TV work, and you'll waste time chasing multicast issues that aren't there.
- TV decoder accessible and powered (still on the ISP modem WiFi if you're following Option B ordering from Phase 2)
- `igmpproxy` package available in your OpenWrt repository

## Steps

> The steps below are the multicast-side plumbing needed for live TV once the decoder is activating successfully. Running them on their own does not fix the "Erreur G01" symptom — that's the activation prerequisite above, which has to be solved first. Both pieces are likely needed for live TV; only the activation piece is needed for VOD.

### 1. Install `igmpproxy`

```
apk update
apk add igmpproxy
```

(On older OpenWrt: `opkg update && opkg install igmpproxy`.)

### 2. Add the VLAN 840 device

If you staged this in Phase 5 (the `network.iptv` section in the staging script may or may not include it; the version in this guide adds it now):

```
ssh root@<router-ip>

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
/etc/init.d/network restart
```

Notes:

- PCP=4 (Video class) on egress, not PCP=6 (Network Control). Don't copy the data VLAN's PCP=6.
- `defaultroute=0`: the IPTV interface should not provide a default route; that's the data VLAN's job.
- `peerdns=0`: the IPTV DHCP server may push DNS resolvers; don't accept them on the LAN.

### 3. Verify the IPTV interface comes up

```
ifstatus iptv
ip addr show sfp1.840
```

You should see an IPv4 lease from Orange's IPTV-side DHCP pool. The address range is Orange-specific and different from the data IPv4 pool.

If `ifstatus iptv` shows `up: false`, check:

- The VLAN tag is correct (`network.sfp1_840.vid='840'`)
- The PCP marking is on (some BNGs check for PCP=4 on VLAN 840)
- The DHCP request doesn't have leftover Option 90 / clientid (it shouldn't — `network.iptv` is a separate interface from `network.wan`)

### 4. Configure `igmpproxy`

Edit `/etc/config/igmpproxy`:

```
config igmpproxy
    option quickleave 1

config phyint
    option network iptv
    option zone wan
    option direction upstream
    list altnet 0.0.0.0/0

config phyint
    option network lan
    option zone lan
    option direction downstream
```

`quickleave 1` makes the proxy send IGMP Leave promptly when a downstream subscriber disconnects; this speeds up channel zapping.

`altnet 0.0.0.0/0` accepts multicast sources from any subnet (the IPTV multicast sources are in Orange's network, not in our IPTV-side subnet). Restricting this further is an optimisation; start permissive.

### 5. Firewall rules for IGMP and multicast

```
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IGMP-from-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='igmp'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Multicast-from-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_ip='224.0.0.0/4'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
/etc/init.d/firewall restart
```

These permit IGMP and multicast destination addresses from the WAN zone (which `network.iptv` belongs to once added). Without these the router silently drops the multicast at the firewall and tuning fails.

### 6. Start `igmpproxy`

```
/etc/init.d/igmpproxy enable
/etc/init.d/igmpproxy start
```

Verify it's running:

```
ps w | grep igmpproxy | grep -v grep
logread | grep -i igmpproxy | tail
```

### 7. Migrate the TV decoder to the LAN

If you followed Phase 2 Option B, the decoder is still on the ISP modem WiFi. Migrate now (the modem's WiFi is presumably disabled by Phase 3, so this is overdue):

1. Add the static lease (Phase 2 step 5b).
2. Join the decoder to the router WiFi (Phase 2 step 5c).
3. Power-cycle the decoder.

### 8. Test channel tuning

Power on the decoder. Try a live channel. Expected:

- Picture and sound within 5-10 s
- Channel zapping responsive
- No reboot loops on the decoder
- No "service activation error" or similar Orange error messages

If tuning fails:

- `cat /proc/net/igmp` should show the multicast groups joined by the decoder being mirrored upstream.
- `tcpdump -i sfp1.840 -nn -c 50` should show multicast traffic from Orange.
- `tcpdump -i br-lan -nn igmp -c 20` while powering the decoder should show IGMP Join from the decoder.

If you see IGMP from the decoder but no upstream traffic on sfp1.840: `igmpproxy` is not forwarding. Check the `phyint` configuration; `altnet` may be too restrictive.

If you see upstream traffic on sfp1.840 but nothing crosses to br-lan: firewall is blocking, or the `downstream` phyint isn't matching. Check the firewall rules and the `network lan` reference in igmpproxy config.

### 9. Stress test

Switch through 20 channels quickly. Watch for stalls, picture freezes, audio dropouts. The first watch may stutter as multicast trees prime; subsequent zaps should be quick.

## Risks

- **Decoder doesn't authenticate at Orange** — separate from multicast. The decoder needs to reach Orange's auto-provisioning over the data side. If it complains about service activation, that's not multicast; check the decoder gets internet via the LAN data path.
- **Multicast traffic but no picture** — codec mismatch, decoder bug. Unrelated to this phase.
- **VLAN tagging mismatch** — Symptom: VLAN 840 interface up but no multicast traffic visible with tcpdump. Re-check the VLAN ID.
- **`altnet` too restrictive** — proxy receives IGMP from LAN but doesn't forward upstream. Open `altnet` further or remove the restriction temporarily.
- **PCP=4 missing** — some BNGs drop IPTV frames without PCP=4. Verify with `tcpdump -e`.
- **Hardware offload interferes with multicast** — flow_offloading on the MT7986 has historically had issues with multicast forwarding. If you've enabled HWNAT and multicast is unstable, try disabling flow_offloading and re-test.

## Rollback

To back the multicast plumbing out without touching activation work:

```sh
/etc/init.d/igmpproxy stop
/etc/init.d/igmpproxy disable
uci set network.iptv.disabled='1'
uci -q delete firewall.@rule[X]    # the Allow-IGMP / Allow-Multicast rules added in step 5
uci commit network
uci commit firewall
/etc/init.d/network restart
/etc/init.d/firewall restart
```

If TV is the priority and activation is unsolved, the practical rollback is to revert to a Livebox-in-line topology (either fibre back to the Livebox temporarily, or the hybrid LAN-side Livebox described in "Possible ways forward" option 1). The multicast plumbing on the BPI-R3 can be left in place — it doesn't actively hurt — but it also doesn't help until activation works.

## Open questions for future testing

When this phase is picked up again, these are worth verifying:

- Whether the IPTV DHCP requires any specific options. Some Orange installations are vanilla DHCP on VLAN 840; others may require an Option 60 string. Capture from a working Livebox before swap if possible.
- Whether the decoder requires IPv6 on VLAN 840. Probably no, but worth checking.
- Whether Orange's IPTV multicast tree is IGMPv2 or IGMPv3. `igmpproxy` handles both but version mismatch can cause weirdness.
- Whether MediaTek MT7986 hardware flow offload interferes with multicast forwarding. Historically there have been issues; if multicast is unstable with HWNAT on, try disabling `flow_offloading` and re-test.

When activation is solved and multicast verified, this document should gain a "What actually worked" subsection with the final configuration.
