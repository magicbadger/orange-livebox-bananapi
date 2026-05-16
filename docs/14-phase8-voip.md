# 14 — Phase 8: VoIP / SIP (stretch goal)

> **Status: stretch goal, with a pragmatic hybrid path identified.** This phase has not been validated end-to-end, but Phase 7's investigation surfaced that the realistic resolution for both TV and VoIP is the **Livebox-on-LAN hybrid** (option 3 below, which is also Phase 7 option 2). The harder paths — extracting SIP credentials or spoofing TR-069 — are now better characterised but remain blocked by the same Orange PKI architecture that protects the TV decoder. See `docs/13-phase7-iptv.md` for the full architectural picture; this doc focuses on the VoIP-specific framing.

## Goal

Make the household landline number (`+33...`) functional via the BPI-R3 instead of the Livebox. Outgoing calls, incoming calls, voicemail, caller ID, all operating through the router rather than relying on the Livebox's phone port.

## Current understanding

Orange France delivers landline service as SIP over the data VLAN (832 on Orange France residential FTTH). The Livebox terminates SIP internally and exposes only an analog phone port (RJ-11) to the user. SIP credentials are not exposed in the Livebox admin UI; they are auto-provisioned by Orange's back-end.

Replacing VoIP on the BPI-R3 therefore requires obtaining SIP credentials, then running an SIP proxy or PBX (Asterisk, FreeSWITCH, or a hardware ATA) on the LAN.

## Why this is hard

**Credentials are not directly recoverable.** Orange uses SIP digest authentication (RFC 3261). The authentication header in a SIP REGISTER request includes an MD5 hash computed from username, realm, password, server-generated nonce, method, and URI. The password is not transmitted in clear, even briefly. A single `tcpdump` capture of a REGISTER does not yield the password directly.

Approaches considered:

### 1. tcpdump + offline brute force

Capture SIP REGISTERs over time. Each captures a different nonce and produces a different hash for the same password. Brute-force the password against the captured (nonce, hash) pairs.

- Password length on Orange SIP is unknown to us; if it's 8+ random characters, brute force is infeasible.
- Even if it's shorter, this requires either rented GPU time or significant local compute.
- Once you have the password, you can re-register from any SIP UA. Reconfigure Asterisk or similar.

### 2. TR-069 spoofing

Pretend to be a Livebox to Orange's auto-provisioning server. Receive the SIP credentials in the provisioning payload. This is how the Livebox itself gets them.

- Requires reverse-engineering Orange's TR-069 dialect.
- The Livebox identifies itself via TLS mutual auth using a device certificate from Orange's PKI (verified during Phase 7 investigation; see `docs/13-phase7-iptv.md` for the cert chain). Spoofing this requires extracting the Livebox device certificate and private key from physical hardware (rooting the Livebox), which is its own multi-week project with uncertain reusability — Orange's certs are per-line provisioned.
- May breach Orange's terms of service in ways the rest of this guide does not.

### 3. Hybrid: keep the Livebox alive on the LAN (recommended; same as Phase 7 option 2)

This is the same hybrid topology Phase 7 settles on for TV: the Livebox stays plugged in behind the BPI-R3 as a permanent TV+VoIP appliance, with the BPI-R3 owning the fibre.

In this topology:

- The Livebox sits on the BPI-R3 LAN; its WAN port gets a DHCP lease from the BPI-R3 LAN (typically `192.168.1.x`).
- The Livebox's internal SIP client uses its existing Orange-issued credentials (which we don't have access to, but the Livebox does) to REGISTER with Orange's SIP infrastructure.
- SIP REGISTER traffic flows: Livebox → BPI-R3 LAN → BPI-R3 NAT → fibre → Orange SIP server.
- SIP authentication is credential-based (digest auth over RFC 3261), not source-IP-based, so the NAT chain shouldn't matter to Orange.
- The Livebox's RJ-11 phone port keeps working normally; the user-visible behaviour is unchanged from a fibre-on-Livebox setup.

**Pros**:

- Zero VoIP-specific engineering effort. No SIP credentials to extract, no PBX to run on the BPI-R3, no SIP ALG tuning (probably — see caveats).
- Phone works unchanged.
- Resolves Phase 8 *and* Phase 7 in one move.
- No legal grey area: the Livebox does what it always did; the BPI-R3 just takes over the fibre side.

**Cons / risks**:

- Ongoing dependence on the Livebox (the same drawback Phase 7's hybrid carries).
- ~10 W continuous power draw.
- **Unverified**: whether the Livebox keeps SIP REGISTER alive in its "no fibre" state. Some Livebox firmwares might disable SIP when they detect no upstream link, even when LAN-side connectivity is fine. Earlier on-site test confirmed the Livebox's WiFi stays up without fibre, but didn't validate SIP. The Phase 7 option-2 test (when scheduled) will incidentally answer this — watch for `tcpdump -i sfp1.832 -nn host <orange-sip-server>` during the test window.
- **Possible**: SIP/RTP NAT traversal edge cases (one-way audio, registration drops). In practice Orange's SIP infrastructure handles residential NAT well, but if you hit issues, the BPI-R3 firewall may need `helper=sip` modules loaded or symmetric-RTP settings.

If the Livebox does refuse SIP without fibre — a firmware-version-dependent outcome — fall back to leaving the Livebox on fibre permanently (i.e. don't do Phase 6 at all, stay on the original topology) or accept landline loss.

### 4. Skip landline

Use mobile phones. Use a third-party VoIP provider (OVH, Voipfone, etc.) for a landline-style service unrelated to Orange.

- Simplest. Many households have already de-facto skipped landline.
- Loses the existing phone number (or requires porting it out of Orange).

## Recommendation

**Option 3 (hybrid) is the realistic path.** Phase 7's investigation has converged on the same hybrid topology for TV; doing it once gets you both. Don't pursue options 1 or 2 unless you have specific reasons (research curiosity, eliminating the Livebox is a hard requirement, etc.). The cert-extraction barrier characterised in Phase 7 makes option 2 (TR-069 spoofing) a multi-week project; option 1 (SIP credential brute force) is computationally speculative.

If landline is critical and the Livebox refuses SIP without fibre (untested as of writing), the practical fallback is to stay on the current Phase 1 topology — Livebox terminates fibre, BPI-R3 is downstream — and accept that the Phase 6 direct-GPON benefit can't be combined with VoIP for your specific Livebox firmware version.

## What would success look like

If this phase ever gets done:

- The Livebox phone port still works (Option 3) **or** a SIP ATA on the LAN registers to Orange SIP and provides an analog phone port (options 1, 2)
- Incoming calls ring the phone
- Outgoing calls succeed
- Caller ID works
- Voicemail (which is server-side on Orange) accessible via the usual short-code
- E911-equivalent (in France: `112`, `15`, `17`, `18`) calls work — **non-negotiable for any landline replacement; verify before relying on it**

## Risks

- **Emergency services.** This is the biggest concern. If your VoIP setup is unreliable or misconfigured, you may not be able to call emergency services when needed. **Do not** replace landline with a VoIP setup unless you're confident in its reliability and have a backup (mobile phone known to be charged). For most households, leaving Phase 8 unattempted and using mobile for emergencies is the safest call.
- **Number portability.** If you give up on Orange SIP and port the number to another VoIP provider, you can't undo the port easily.
- **Legal / TOS.** Cloning a Livebox's TR-069 identity (option 2) may violate Orange's terms of service in ways direct GPON cloning does not. Investigate before pursuing.

## Notes

The README and the rest of the guide refer to this as a stretch goal precisely because it's underspecified and household-dependent. Don't treat the lack of a procedure here as a flaw of the guide; treat it as honest about where this work has and hasn't been done.

If someone reading this has cracked one of the options above for Orange France, a PR or external write-up linked from [`20-references.md`](20-references.md) would be welcomed.
