# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A technical writeup, not a software project. It documents a hands-on procedure for replacing an Orange France Livebox with a Banana Pi BPI-R3 running OpenWrt plus a rooted Huawei MA5671A GPON SFP. There is no build system, no test suite, no package manager.

**This is a work in progress.** Phase 6 (direct GPON termination) is validated as a procedure; Phases 7-11 (IPTV, VoIP, port forwards, monitoring, retirement) are at various stages from "next up" to "untouched stretch goal". As later phases get tested, earlier documents may need revisiting: a finding in Phase 7 may show that a Phase 5 staging choice was wrong, or that a "Critical insights" note in the README is now incomplete. Treat the whole corpus as living, not frozen.

Top-level published files:

- `gpon-openwrt-readme.md` — the headline guide. Contains the executive summary, the "Critical insights not in the public docs" findings, inline copies of the three shell scripts, and links into `docs/`.
- `docs/01-prerequisites.md` through `docs/20-references.md` — long-form material, one walkthrough per phase plus reference docs (BPI-R3 specifics, MA5671A specifics, Orange France specifics, OMCI architecture deep dive, troubleshooting catalogue, references). `docs/04a-rooting-the-ma5671a.md` is an out-of-band pointer doc for the rooting pre-step (the canonical procedure lives at hack-gpon.org; we deliberately don't duplicate it). Phases marked WIP at the top of each phase doc are sketches based on the original migration plan, not validated procedures.
- `scripts/orange-wan-config.sh`, `scripts/orange-gen-auth.sh`, `scripts/ma5671a-diagnostic.sh` — standalone copies of the scripts. Mirrored in the README and in the relevant phase docs; keep all copies in sync.
- `etc/orange-auth.example` — credential file template.

The repository's `.gitignore` excludes personal working notes (session logs, in-progress investigation runbooks, packet captures, credentials). Those files exist locally for the maintainer's own use but are not part of the public guide.

## Working in this repo

- The readme and the phase docs both inline the scripts. The `scripts/*.sh` standalone files are the canonical copy. When a script changes, update all three places (standalone file, README inline, relevant phase doc inline) in the same change. Don't let them drift.
- Treat the embedded shell scripts as POSIX/busybox ash (they run on OpenWrt and on the MA5671A's OpenWrt 14.07 base). No bashisms, no GNU-only flags. Use `printf`/`hexdump`/`md5sum` rather than reaching for `xxd` or `openssl`.
- When editing the guide, preserve the empirical findings in the README's "Critical insights not in the public docs" section verbatim unless there's evidence they're wrong. Each item there was confirmed by a specific diagnostic; rewriting them risks losing hard-won detail. The same holds for the experimental confirmations in `docs/18-omci-architecture.md` (the ZZZZ test, the `config_onu` mangling bug reproductions).

## Flag earlier documentation when later progress contradicts it

This is the most important guidance for ongoing work in this repo. As later phases get tested, earlier docs (or the README) may become wrong, incomplete, or misleading. **When you notice this, flag it explicitly to the user; do not silently rewrite.**

Concrete triggers:

- A reader reports that something documented as working actually doesn't, or vice versa. Surface every doc that asserts the now-wrong claim. Ask whether to update or to add a "later finding" note.
- Someone reports a value (option byte, package name, command flag) that differs from what's currently in the docs. Don't assume the new value supersedes; ask whether the old value was wrong, environment-specific, or a versioning shift.
- A WIP phase gets completed. Re-read that phase's doc against what actually worked. Anything that diverges is a candidate for revision; list each divergence rather than batch-rewriting.
- A new phase's findings invalidate an assumption in an earlier phase (e.g. Phase 7 needs a UCI key that Phase 5 staging didn't set). Walk back through the earlier docs, list the affected sections, propose updates rather than making them silently.
- The README's "Critical insights" gain a new entry, or an existing entry needs nuance. Treat this as a deliberate edit, surfaced rather than tucked in.

Default behaviour when in doubt: **note the misalignment in the response, propose the smallest precise fix, ask for confirmation before editing the earlier doc.** Knowing where the docs are out of step is more valuable than a clean-looking diff that hides the drift.

## Project context Claude should carry into any technical change

- **Phase 6 is validated as a working procedure.** Direct GPON via BPI-R3 has been demonstrated end-to-end. The procedure is documented; specific instances may be in any state (active, rolled back, partially deployed).
- **Phase 7 (IPTV) has been characterised in depth.** The decoder activation chain has three layers — UPnP IGD (solvable with `miniupnpd`), Livebox-local Sysbus over TLS (effectively blocked by Orange PKI), Orange-cloud mTLS (likely depends on Sysbus succeeding). The Livebox's TLS cert chain has been verified: per-device leaf signed by `Orange Devices Generic4 CA` → `Orange Devices Root CA`. The decoder almost certainly has the Orange root burned into firmware. This means a fully-Livebox-free TV setup requires Livebox cert extraction (deep engineering project, uncertain per-line reusability). The realistic end state is the hybrid: BPI-R3 owns fibre, Livebox stays on LAN as TV+VoIP appliance.
- **Phase 8 (VoIP) folds into the Phase 7 hybrid.** The SIP credential extraction problem is effectively the same wall as decoder activation — Orange PKI mTLS. The pragmatic answer for both is to keep the Livebox in place.
- **Live infrastructure is at stake** in any real deployment. Any procedure change that risks the rollback path (fibre back to Livebox, restore the Phase 1 backup file, restart networking) needs the rollback called out explicitly.
- **gSerial (ME 256 Serial Number) is the single critical OMCI field.** Equipment ID and Version mismatches did not block Orange's BNG in testing. Don't restructure the guide in a way that buries this finding.
- **`config_onu` on the rooted MA5671A has two mangling bugs** (it overwrites `equipment_id` with `nSerial`, and converts `\0` escape pairs to ASCII '0'). The guide describes the bugs and notes they don't matter in practice for Orange. Don't "fix" the UCI snippets to work around bugs that aren't actually blocking.
- **Option 60 is `arcadyan`, not `sagemcom`**, despite the Sagemcom OUI — this is firmware-overriding OEM identity and is easy to "correct" by mistake.
- **DHCP Option 61 must use `option clientid`, not `sendopts '61:...'`** — netifd silently replaces sendopts-61 with a DUID.

## Author identity for commits

Commits should be authored under whatever identity the maintainer is using for this repository. Do not add `Co-Authored-By` trailers, and do not mention Claude in commit messages.
