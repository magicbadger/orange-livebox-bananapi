---
title: Contributing
nav_order: 99
---

# Contributing

This repository documents replacing an Orange France Livebox with a Banana Pi BPI-R3 running OpenWrt plus a rooted Huawei MA5671A GPON SFP. Contributions are very welcome — this is a community resource and the accumulated knowledge benefits from corrections, additions, and adaptations for hardware combinations not yet documented.

## Scope and intent

This is a **hardware portability** resource. It exists for people who want to control the hardware terminating their own fibre connection on their own subscriber line, rather than depending on ISP-supplied equipment they neither own nor can fully configure. End-user control of one's own network hardware is a normal freedom concern, recognised in many jurisdictions (for example, the EU's "router freedom" principle).

**In scope:**

- Direct GPON termination on user-owned hardware.
- Cloning OMCI identity from your own ISP-provided modem to your own rooted SFP, for use on your own line.
- Configuring DHCP / PPPoE / authentication options to satisfy your own ISP's BNG.
- Network configuration patterns: VLAN tagging, IGMP proxy, IPv6 PD, SQM, DDNS.
- Investigation of ISP-side architectures (e.g. Orange's per-device PKI for the decoder activation chain) where the findings inform what's achievable in practice.
- Adaptations for other ISPs, other OpenWrt-capable routers, other rooted ONT sticks.

**Out of scope:**

- Anything that enables accessing service you have not contracted for, or impersonating another subscriber. Cloning your own modem's identity for use on your own line is hardware portability; cloning someone else's modem to use their service is theft.
- Bypassing payment, account suspensions, or contract restrictions you've agreed to.
- Bulk SIP credential brute-force, voice fraud, premium-rate exploitation.
- Stealing or redistributing per-line credentials, certificates, or keys obtained from other customers' hardware.
- Anything an ISP's fraud or abuse team would (correctly) treat as harmful.

The line is straightforward: this resource helps you exercise control of *your own* hardware on *your own* line. It is not a recipe book for fraud. If a contribution is genuinely aimed at the latter and not the former, please don't open the PR.

## What's especially welcome

- **Corrections** to anything in the docs, especially where current claims have been disproven by later testing or differ from your own setup.
- **ISP-specific notes** for ISPs other than Orange France — even a single section in the style of [`docs/04-orange-france-notes.md`](docs/04-orange-france-notes.md) for your ISP would be a major addition.
- **Hardware-specific notes** for routers other than BPI-R3 — particularly other OpenWrt-capable boards with SFP cages.
- **Other ONT sticks** beyond the Huawei MA5671A: FS-modded, Carlito, SourcePhotonics, etc.
- **Packet captures or detailed findings** that resolve open questions (especially the Phase 7 IPTV / mTLS investigation).
- **Diagnostic procedures** that helped you when something went wrong.
- **Tooling**: scripts, validation helpers, anything genuinely useful.

## How to contribute

- **Issues** for questions, corrections to specific claims, or "here's a thing I observed that doesn't match the docs."
- **Pull requests** for changes to the content itself.

Small PRs are easier to review than large ones. If you want to do a substantial rework of a section, opening an issue first to discuss is often faster than a large PR that needs back-and-forth.

## Style and conventions

- **Markdown**: GitHub-flavoured, wrapped at sensible points but not strictly 80 columns. Aim for readable diffs.
- **Shell scripts**: POSIX / busybox `ash`. They run on OpenWrt and (for `ma5671a-diagnostic.sh`) on the MA5671A's OpenWrt 14.07 base. No bashisms, no GNU-only flags. Use `printf` / `hexdump` / `md5sum` rather than reaching for `xxd` or `openssl`.
- **Documenting findings**: distinguish what's verified (you saw it in a capture or test) from what's community-claimed or inferred. The repository has been bitten by AI-generated summaries with confidently fabricated specifics; treat any citation as needing independent verification.
- **Personal data**: do not include real subscriber identifiers in PRs (FTI usernames, GPON serials, MAC addresses, phone numbers, IPv6 prefixes, DDNS hostnames). Use placeholders following the existing patterns (`ARLT12345678`, `64:75:DA:XX:XX:XX`, `fti/abc1234`, etc.).
- **Preserve the "Critical insights" section's claims** unless you have new evidence. Each item there was confirmed by a specific diagnostic; corrections welcome with evidence, additions welcome held to the same standard.

## Project choices already taken

For transparency, framings the project has settled on (open to revision with new evidence, not open to drive-by changes):

- The hybrid (Livebox-on-LAN) is presented as the realistic Phase 7 end state for TV and VoIP. The cert-chain analysis in [`docs/13-phase7-iptv.md`](docs/13-phase7-iptv.md) shows why full Livebox elimination requires Livebox certificate extraction — a deep engineering project with uncertain per-line reusability. If someone publishes a working "full elimination" procedure for a specific decoder generation, that would change the framing.
- Decoder certificate or SIP credential extraction is not covered here. Those are separate research projects with their own legal and ethical considerations.

## Licence

By contributing, you agree your contribution will be released under the same licence as the project: **Creative Commons Attribution 4.0 International** (CC BY 4.0). See [`LICENSE`](LICENSE).

## Tone

This is a technical resource. Discussions are most useful when they're specific, evidence-based, and focused on the technical content. Personal attacks, ISP-bashing, or political tangents (about EU vs. US router-freedom rules, about Orange's commercial decisions, etc.) belong elsewhere — even when they're well-argued.

If you've gotten something working that's not yet in the docs, the most useful contribution is a write-up of what you did and what worked. Even a rough draft is a useful starting point — happy to help polish it during review.

---

Thanks for reading this far. The project has more value the more people contribute. Happy hardware-controlling.
