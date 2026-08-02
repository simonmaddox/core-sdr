# RTL-SDR Blog V4 (R828D) support — feasibility investigation

*2026-08-02. Investigation only — no V4 hardware in hand; everything below is
derived from the CoreSDR source and the reference C drivers (rtl-sdr-blog fork
+ osmocom mainline, which upstreamed V4 support in commits `1261fbb285` and
`138cd052f5`, Aug–Sep 2023). Nothing ships as "V4 supported" until validated
on a real dongle.*

## Verdict

**Feasible, and smaller than expected.** The R828D is the same Rafael Micro
die family as the R820T2 — same chip ID (0x69), same init array, same gain
tables, same tracking-filter table, same 3.57 MHz IF. librtlsdr drives both
chips with one driver (`tuner_r82xx.c`) parameterised by chip. The entire
upstream V4 delta on top of pre-existing R828D support was ~104 lines of C.
CoreSDR's transport and mock layers need no changes at all. Recommended
shape: parameterise the existing `R820T2` driver into an `R82xx` driver with
a chip config, rather than writing a second driver or introducing a tuner
protocol.

## What the V4 actually requires (from the reference drivers)

1. **Chip selection, not chip detection.** Both chips answer chip-ID 0x69;
   they are distinguished purely by which I2C address ACKs — 0x34 (R820T2)
   vs 0x74 (R828D). CoreSDR's `verifySupportedTuner()` already probes both
   addresses in exactly this order; the change is that a 0x74 answer becomes
   a *success* that selects the R828D config instead of throwing
   `unsupportedTuner`.

2. **PLL: one constant.** `vco_power_ref = 1` for R828D vs `2` for R820T
   (CoreSDR: `vcoPowerRef` in `setPLL`, already commented as the divergence
   point). This also raises the `nint` overflow bound from 63 to 127. VCO
   range is identical (1.77–3.54 GHz). No dither handling exists in either
   reference tree — not a thing we're missing.

3. **Xtal: the V4 needs NO change.** Generic R828D sticks (Astrometa etc.)
   run the tuner from a 16 MHz crystal, but the V4's R828D runs off the
   RTL2832U's 28.8 MHz clock — which is CoreSDR's existing default
   everywhere. (This mismatch is exactly why old drivers tune V4s onto wrong
   frequencies.) If we ever want generic-R828D support, the 28.8 MHz default
   parameter spread across `setFrequency`/`resamplerRatio`/`setIFFrequency`
   becomes a per-tuner value; for V4-only support it stays untouched.

4. **V4 identification: USB string descriptors.** The driver knows a dongle
   is a V4 (vs any other R828D stick) by exact match on manufacturer
   `"RTLSDRBlog"` + product `"Blog V4"` from the EEPROM-backed USB strings.
   CoreSDR already reads string descriptors for `SDRDeviceInfo`, so this is
   a comparison, not new plumbing. (The V4 users guide warns users not to
   rewrite the EEPROM strings for exactly this reason.)

5. **HF coverage: an offset, not a mode.** The V4 has an always-inline
   28.8 MHz upconverter on its HF path. Tuning below 28.8 MHz just means
   `lo = freq + 28.8 MHz + IF` in the PLL math — no direct-sampling mode, no
   demod reconfiguration (the V3's Q-branch direct sampling is a different
   mechanism the V4 never uses). Result: frequency range extends down to
   ~500 kHz.

6. **Per-band routing, mostly via tuner registers.** On each tune the V4
   path selects HF (≤28.8 MHz, cable-2 input, reg 0x06), VHF (<250 MHz,
   cable-1, reg 0x05), or UHF (air-in, reg 0x05), and drives the onboard
   notch filters (AM / broadcast-FM / DAB) via reg 0x17 bit 0x08. All I2C
   writes through the existing masked-shadow-write machinery.

7. **One RTL2832U GPIO, and it's new code.** Newer V4 batches power the
   upconverter via **GPIO 5** (high = off, when out of HF band); early
   batches ignore the pin, so driving it unconditionally is safe. CoreSDR
   currently has zero GPIO code — needs small `sys`-block register helpers
   in `RTL2832U` (set-output + set-bit, ~20 lines, straight from the
   reference). The same helpers give us **bias tee on GPIO 0** (a 1.2
   roadmap item, works on V3 too) nearly for free. Note: GPIO writes are
   plain USB control writes, not I2C — they can happen mid-tune while the
   I2C repeater is open, but the op-serialisation queue should order them
   deliberately.

## What changes in CoreSDR, concretely

| Area | Change | Size |
|---|---|---|
| `R820T2.swift` → `R82xx` | chip config (i2c address, `vcoPowerRef`, per-chip capability range); V4 flag drives upconvert offset + band routing + notch in `setFrequency` | the bulk, but mostly parameter-threading |
| `verifySupportedTuner()` | 0x74 → select R828D config (keep rejecting when *neither* address answers) | tiny |
| `RTLSDRDevice` | tuner config chosen at `open()` after probe; `configureForR820T2()` renamed (contents unchanged — IF identical); per-device capabilities (V4: ~0.5–1766 MHz) | small |
| `RTL2832U` | GPIO helpers (sys block) | ~20 lines |
| Device info | V4 string match ("RTLSDRBlog"/"Blog V4") | trivial |
| Tests | `stubR828DPresent()` convenience + R828D/V4 golden vectors (init writes at 0x74, PLL with `vco_power_ref=1`, HF-offset LO math, band-routing writes, GPIO 5) | the real work, and fully mockable — `MockUSBTransport` is address-parameterised already |

Deliberately **out of scope** for the first pass: generic 16 MHz R828D sticks
(xtal parameterisation), the blog fork's non-essential extras (VCO-current
max hack, L-band drop-out hack, HF tracking-filter bypass, V4 Lite, forced
bias tee, auto direct sampling). Each is recorded here so it isn't
re-discovered: the tracking-filter bypass is the one most likely to matter
(HF sensitivity) and can be A/B'd on real hardware.

## Risks

- **No hardware = no ground truth.** Golden vectors will be derived from the
  reference C math, not captured from a real bus. The mock-driven suite
  proves we compute what librtlsdr computes; only a real V4 proves that's
  what the dongle needs. Validation gate stands. (~£30, and the probe path
  on a real R828D bus was already exercised once: Simon's earlier V3 probe
  verification covered the 0x34 leg live; 0x74 has only ever NAK'd.)
- **Early-vs-late V4 batches** differ on GPIO 5 — mitigated by driving it
  always (reference behaviour).
- **The app side is nearly free but not zero**: the "unsupported tuner
  (R828D)" empty state and the auto-connect skip-list for known-unsupported
  IDs both need to learn that R828D is now supported (megahertz-app, not
  CoreSDR).

## Recommendation

Green light. The work is a parameterisation of an existing, well-tested
driver plus one small GPIO helper — exactly the "if it lands cleanly,
promote to 1.1" case the roadmap anticipated. Suggested order: (1) chip
config + probe selection, TDD'd; (2) PLL `vcoPowerRef` + golden vectors;
(3) V4 `setFrequency` path (offset, routing, notch); (4) GPIO helpers +
GPIO 5 (+ bias tee opportunistically); (5) buy a V4, validate, then flip
the app's empty-state/skip-list. Reference sources are archived in the
session scratchpad (`v4/`: blog fork, osmocom mainline, both V4 patches).
