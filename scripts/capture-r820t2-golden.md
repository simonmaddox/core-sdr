# Capturing golden R820T2 PLL/gain register-write vectors

This document describes, reproducibly, how the fixture
`Tests/CoreSDRTests/Fixtures/r820t2_golden.json` was generated.

The fixture is **ground truth** for the from-scratch Swift port of the R820T2
tuner (Tasks 14–15): it maps an input (a tune frequency, or a gain setting) to
the exact sequence of `(register, value)` I2C writes that the **reference
librtlsdr driver** emits for that input. The Swift port must reproduce these
byte-for-byte.

The reference is used **only** as a fixture generator. It is **not** a
dependency of CoreSDR and is **not** referenced from `Package.swift`.

## Source

Reference: <https://github.com/librtlsdr/librtlsdr>, file `src/tuner_r82xx.c`
(with headers `include/tuner_r82xx.h`, `include/rtlsdr_i2c.h`).

For this capture a local read-only clone was used. The only file compiled from
the reference is `src/tuner_r82xx.c` — **unmodified**. All logging is done from
a separate harness via the driver's existing I2C callbacks; no `fprintf` was
added to the reference source.

## How the driver emits writes

`r82xx_write_arr()` fills `priv->buf[0] = reg`, `priv->buf[1..] = values`, then
calls `rtlsdr_i2c_write_fn(rtl_dev, i2c_addr, buf, size + 1)`. Single-register
writes (all of `r82xx_set_freq` / `r82xx_set_gain` use `r82xx_write_reg` /
`r82xx_write_reg_mask`) therefore arrive as `buf = [reg, value]`, `len = 2`.

`r82xx_read()` bit-reverses every byte returned by `rtlsdr_i2c_read_fn()`
(see `r82xx_bitrev`), so the harness returns `bitrev(desired)` to make the
driver observe a chosen value.

## The harness

`scripts/capture-r820t2-golden/harness.c` (committed in this repo — it is the
exact file compiled to produce the committed fixture) provides:

- `rtlsdr_i2c_write_fn` — records each `(buf[0]+k, buf[1+k])` pair into a log
  when capture is enabled.
- `rtlsdr_i2c_read_fn` — returns a **deterministic chip-read image** (see
  below), bit-reversed so the driver decodes it back to the intended value.
- `rtlsdr_check_dongle_model` — returns `0` (device is *not* an RTL-SDR Blog V4,
  so no HF up-conversion / input-switch writes are taken).

### Deterministic chip-read model

Because there is no real chip, the harness returns a fixed register-0 read
image (values are **post** bit-reverse, i.e. what the driver sees):

| reg | value | effect |
|-----|-------|--------|
| 2   | 0x40  | PLL "locked" bit set → `r82xx_set_pll` reports `has_lock = 1` and emits the full sequence including the final `0x1a` autotune-8kHz write |
| 4   | 0x20  | `vco_fine_tune = (0x20 & 0x30) >> 4 = 2 = vco_power_ref` (R820T) → `div_num` is **not** nudged, so the divider comes purely from the documented `mix_div` search; also `(0x20 & 0x0f) = 0` → filter-cal code is 0 |
| all others | 0x00 | — |

This is the "ideal centred, locked VCO" model. It is the read behaviour the
Swift port must mirror to reproduce these vectors. (On real hardware
`vco_fine_tune` is a convergence feedback signal; modelling it as centred makes
the divider deterministic and exactly matches the documented PLL formula.)

### Config (`struct r82xx_config`)

Mirrors what `librtlsdr.c` sets for an R820T dongle:

| field | value | source |
|-------|-------|--------|
| `i2c_addr` | `0x34` | `R820T_I2C_ADDR` |
| `rafael_chip` | `CHIP_R820T` | librtlsdr.c |
| `xtal` | `28_800_000` | default RTL xtal |
| `max_i2c_msg_len` | `8` | librtlsdr.c |
| `use_predetect` | `0` | librtlsdr.c |
| `harmonic` | `0` | librtlsdr.c (`DEFAULT_HARMONIC` applied internally) |
| `vco_curr_min` / `vco_curr_max` | `0xff` / `0xff` | default |
| `vco_algo` | `0x00` | default divider algorithm |
| `verbose` | `0` | — |

`override_mask` / `override_data` are zeroed (memset of the whole `priv`).

### Capture protocol

Each vector is captured from a **freshly-initialised** tuner so the vectors are
independent of each other and of ordering:

1. `memset(&priv, 0, ...)`, `priv.cfg = &cfg`.
2. Call `r82xx_init(&priv)` with logging **off** (init writes are discarded).
3. Turn logging **on**, reset the log.
4. Call the target entry point once and record the writes.

Entry points (mirroring `librtlsdr.c`):

- **setFreq**: `r82xx_set_freq(&priv, hz)` for
  `hz ∈ {100_000_000, 173_225_000, 433_920_000, 868_000_000, 1_090_000_000}`.
- **setGain (manual)**: `r820t_set_gain` →
  `r82xx_set_gain(&priv, 1, tenthsDb, 0, 0, 0, 0, &ctrl)` for
  `tenthsDb ∈ {0, 166, 328}`.
- **setGain (auto)**: `r820t_set_gain_mode(dev, 0)` →
  `r82xx_set_gain(&priv, 0, 0, 0, 0, 0, 0, &ctrl)`.

The harness prints the fixture JSON directly to stdout, so every byte in the
fixture comes from the actual reference run.

## Build & run

The harness (`scripts/capture-r820t2-golden/harness.c`) is committed in this
repo; the librtlsdr reference is **not** vendored — set `$REF` to your local
read-only reference clone. Run from the repository root:

```sh
REF=/path/to/librtlsdr        # external reference clone, NOT vendored here

clang -O0 -g -std=c11 -Wall -Wno-unused-function \
  -I"$REF/include" -I"$REF/src" \
  scripts/capture-r820t2-golden/harness.c "$REF/src/tuner_r82xx.c" \
  -o /tmp/capture-r820t2

/tmp/capture-r820t2 > Tests/CoreSDRTests/Fixtures/r820t2_golden.json
```

Compiles with no warnings and runs with no stderr diagnostics. Its stdout **is**
the fixture `Tests/CoreSDRTests/Fixtures/r820t2_golden.json` — so every byte in
the fixture comes directly from the reference run.

## Output schema

```json
{
  "setFreq": [ { "hz": 100000000, "writes": [ { "reg": 23, "value": 48 }, ... ] } ],
  "setGain": [
    { "tenthsDb": 0, "mode": "manual", "writes": [ ... ] },
    { "mode": "auto", "writes": [ ... ] }
  ]
}
```

`reg` and `value` are decimal. `setGain` entries carry a `mode` field
(`"manual"` / `"auto"`); manual entries also carry `tenthsDb`, the automatic
entry does not.

## Reproducing / extending

To add inputs, edit the `freqs` / `gains` arrays in
`scripts/capture-r820t2-golden/harness.c`, then rerun the build & run command
above (which writes straight to the fixture path). Do not hand-edit register
values in the fixture — always regenerate from the reference.
