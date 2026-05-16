# 17 — Phase 11: ISP modem retirement

> **Status: work in progress (decision phase).** Final disposition of the ISP modem once stability monitoring has confirmed the direct-GPON setup is reliable.

## Goal

Decide and execute the final disposition of the original ISP modem (Livebox, in the reference case). Three reasonable options; pick one based on your situation.

## Success criteria

- Decision documented (in this file, or in a personal note)
- Action completed (returned / stored / hybrid use)
- No unexpected ISP charges
- Fallback plan still exists if BPI-R3 setup fails later

## Pre-requisites

- Phase 10 complete (stable operation confirmed)

## Option A: return to the ISP

Orange France's contract terms typically require return of the Livebox if it's a leased device. Conditions vary by contract; check before doing anything irreversible.

### Steps

1. Check your Orange contract. Look for "restitution du matériel" or similar. The contract or a recent bill usually specifies the return window (typically 30 days from end of service or replacement) and the return procedure.
2. Contact Orange via web chat, the app, or Orange 3900 to declare you no longer use the Livebox. Request a return slip / instructions.
3. Orange will typically send a prepaid return label or instruct you to drop off at an Orange shop or designated point relais.
4. Factory-reset the Livebox before returning (Settings → Reset, or hold the reset button while powering up). This removes your credentials and personal config.
5. Pack with original packaging if you still have it; otherwise wrap in bubble wrap, include the power supply.
6. Ship / drop off. Keep the tracking number / receipt for proof of return.
7. Check next month's bill to confirm no equipment-non-return charge has been added (typical penalty: €50-150 if not returned within the window).

### Pros

- Compliant with contract
- One less device using power and taking space
- Avoids potential charges

### Cons

- Lose the fallback. If the BPI-R3 setup fails in the future, you'll need a new ONT from Orange (and they may want to send a new Livebox, restarting the cycle).
- Once posted back, you cannot get it back.

## Option B: keep as emergency fallback

If your Orange contract permits keeping the Livebox (e.g. you bought it outright, or the contract is silent on return), or you accept the small risk of a charge in exchange for having a fallback:

### Steps

1. Confirm the contract allows keeping it. If silent, accept that Orange might bill you and decide whether that's acceptable.
2. Factory-reset the Livebox to remove your config (optional, but it's clean state if you ever need to redeploy).
3. Store it somewhere accessible, with the power supply and a labelled fibre patch cable.
4. Note its location in a personal document or family-shared note. Stress moments do not include "where did I put that?".
5. Periodically (annually) power it on, connect a fibre patch, verify it still authenticates with Orange. Cycle this annually so you know it works when needed.

### Pros

- You have a tested fallback if the BPI-R3 dies
- Useful insurance for the ~5 minutes per year of testing

### Cons

- Takes a shelf
- Possible Orange charge depending on contract
- The Livebox firmware ages; eventually Orange may stop accepting an older Livebox on the OLT, devaluing the fallback

## Option C: hybrid (Livebox-on-LAN for TV + VoIP)

This is the same hybrid topology characterised in Phase 7 (option 2) and Phase 8 (option 3). The Livebox stays on the BPI-R3 LAN as a permanent appliance providing decoder activation (Sysbus + local UPnP), live-TV multicast bridging, and SIP for the RJ-11 phone port. The BPI-R3 owns the fibre and handles all routed/NAT traffic for other LAN clients.

Pre-requisite: this option is only viable if Phase 7's option-2 test confirms that the Livebox's local services (Sysbus, SIP, UPnP) all come up correctly without fibre. The Livebox's WiFi has been observed to come up in that state; the rest hasn't been verified at the time of writing. See `docs/13-phase7-iptv.md` for the full architectural picture and the prediction.

### Steps

1. Phase 6 is active (fibre on BPI-R3 via MA5671A).
2. Plug the Livebox WAN port into a LAN port on the BPI-R3. Livebox gets DHCP from BPI-R3 LAN (`192.168.1.x`).
3. Optionally disable the Livebox's WiFi if you want a single SSID via the BPI-R3 — but if the decoder is on Livebox WiFi today, keeping it there avoids a re-pairing step. The decoder needs to discover the Livebox via SSDP, which works best if both are on the same Livebox-LAN segment.
4. On the BPI-R3, install and configure `igmpproxy` to forward IPTV multicast from `sfp1.832` to `br-lan` (the segment the Livebox WAN port sits on). See the multicast plumbing in `docs/13-phase7-iptv.md`.
5. Optionally add the firewall rules for IGMP and the `232.0.0.0/8` SSM range from WAN.
6. Verify: decoder activates, live TV channels tune, RJ-11 phone registers via the Livebox's SIP client to Orange.

### Pros

- Phone keeps working with no new SIP infrastructure
- TV keeps working (decoder uses the Livebox's local cert/Sysbus)
- All non-decoder traffic gets Phase 6 benefits: direct GPON, single NAT, public IPv4 + IPv6
- WireGuard / inbound services hosted on the BPI-R3 directly
- Same Livebox does both jobs (TV + phone); only one device to keep alive

### Cons

- Permanent dependence on the Livebox (~10 W continuous, takes a shelf)
- Decoder is double-NATted (decoder behind Livebox behind BPI-R3) — fine for outbound HTTPS/multicast but limits any inbound-services use of the decoder
- More complex topology than a clean BPI-R3-only setup

### Unverified assumptions

These are the bits the Phase 7 option-2 test specifically verifies:

- Livebox local Sysbus / UPnP services come up without fibre
- Livebox SIP client REGISTERs and handles calls without fibre
- Decoder activation completes with the Livebox-on-LAN as the local API source
- Multicast forwarding via `igmpproxy` on the BPI-R3 reaches the decoder through the Livebox

If any of these fail when actually tested, Option C reverts to "not viable for this Livebox firmware version", and the practical answer is to either stay on the original Phase 1 topology (Livebox terminates fibre, BPI-R3 downstream — gives up Phase 6 benefits but keeps everything else working) or accept TV/phone loss and use Option A or B.

## Recommendation

If you want TV and VoIP working alongside Phase 6 internet, **Option C is the realistic answer**. The Phase 7 investigation converged on this topology as the cleanest available end state — Orange's per-device PKI architecture effectively rules out Livebox-free decoder activation and SIP credential extraction for most users. Option C lets the Livebox keep doing the parts only it can do, while the BPI-R3 takes everything else.

If TV and VoIP aren't required (or you've moved to streaming alternatives and a mobile phone), **Option B** is the conservative second choice: keep the Livebox as emergency-fallback hardware while the BPI-R3-only setup proves itself, then potentially move to A later. Don't return the Livebox until you're sure you won't need it.

**Option A** is the cleanest end state but assumes everything else works without the Livebox. Not recommended until at least 6-12 months of stable BPI-R3-only operation, and even then only if you've explicitly given up on Orange TV / Orange landline.

## Risks

- **Option A risk**: BPI-R3 fails, you have no fallback. Orange will eventually send a new Livebox but you'll be without service for days or weeks.
- **Option B risk**: Orange bills you for unreturned equipment if your contract requires return.
- **Option C risk**: Adds complexity, partial Livebox dependence; phone may stop working with no clear reason.

## Notes

This decision is mostly non-technical and depends on:

- Your relationship with Orange
- Whether you have other landline alternatives
- How much shelf space the Livebox earns
- Your tolerance for occasional internet outages while you fix the BPI-R3 in scenarios where it breaks

There's no right answer. Document your decision so future-you and (if applicable) household members know what to do if the internet stops working at 22:00 on a Tuesday.
