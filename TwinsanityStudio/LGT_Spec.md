# WoC `.LGT` (Lighting) Format — Investigation Notes

Status: **investigated, not implemented**. The outer file/record framing
is solid and decoder-ready, but real per-record data comes in at least
two different internal shapes that aren't yet reliably distinguishable —
see "Why this isn't a parser yet" before reaching for this.

## What `.LGT` is

Per-level, plain uncompressed loose files (37 exist on the disc, sizes
138–6364 bytes). Real light-placement data for a level.

## Confirmed: file-level size formula

Checked against all 37 real files, zero exceptions:
```
fileSize = 4 (leading count) + 24 (header) + 55 * count + 12 * K
```
`count` is the leading `UInt32LE`. `K` is some number of "extended"
lights that cost 12 extra bytes each (e.g. `AIRSHIP.LGT` 138B/count=2 →
K=0; `FARM.LGT` 540B/count=8 → K=6; `CASTLE_C.LGT` 6364B/count=96 →
K=88). Header relative offset 12 (a `UInt32LE`) equals `K` exactly for
some files (`FARM`: 6=6, `HUB`: 37=37) but not others (`CASTLE_C`: 65 vs.
K=88) — so the header only partially tracks `K`, or more than one kind
of "extended" record is being aggregated into that one size delta.

## Confirmed: 24-byte header, 55-byte base record size

`AIRSHIP.LGT` (138 bytes, `count=2`, `K=0`) is fully byte-accounted:
`4(count) + 24(header) + 55 + 55 = 138` exactly, matching the formula
above. Header content: four `UInt32LE` at relative offsets 0/4/8/12 —
`(1, 1, 0, 1)` in `AIRSHIP.LGT` — recurs as a pattern across most `K=0`
files but isn't universal (`CASTLE_C.LGT`'s first two header words are
`(4, 24)`, not `(1, 1)`). Two more floats follow at header offset
16-23 whose purpose is unresolved.

## Confirmed: color and radius fields, for the "normal" record shape

Within a 55-byte record, when it's the "normal" shape (see the open
problem below):
- **Relative offset 16**: radius/falloff distance — a small positive
  float in every normal-shape sample checked.
- **Relative offset 20-22**: byte RGB, **no alpha** — confirmed via WoC's
  own decompiled symbol table (`Games Files/Reference Files/CrashWOC-
  PS2-Decomp-master/symbols/ALL_SYMBOLS.txt`): `edlightMakeNUCOLOUR3` and
  three independent slider symbols (`edlightcb_r_sliderval`/`g_`/`b_`) —
  a real `NUCOLOUR3` type, no alpha channel exists for it in the editor.
- **Relative offset 23-34**: the SAME color as the byte triple above, as
  three `Float32`s (0...1 range) — confirmed to match `byteValue/255` to
  3 decimal places when the record is the normal shape.
- **Relative offset 0/4/8/12**: four floats, plausibly a position triple
  plus one more value — real-world-range-plausible when cross-checked
  against that level's own `INST` coordinates, but the exact per-axis
  assignment (which of the four is X/Y/Z, and what the 4th represents)
  is NOT confirmed.
- **Relative offset 35-54** (20 bytes): tail, contains at least 2 small
  `UInt32` fields (one usually ~4-5, one variable: 1/5/6/7 observed) plus
  more floats — not decoded.

## Why this isn't a parser yet

**A second, structurally different record shape exists, and it isn't
reliably detectable.** Directly re-verified on `AIRSHIP.LGT` (the
smallest, `K=0` "simple" file): its light 0 fits the normal shape exactly
(radius `2.31`, `colorByte=[255,191,127]` matches
`colorFloat=(1.0,0.749,0.498)` almost exactly) — but light 1 in the SAME
file does not: computed "radius" comes out **negative** (`-11.35`), and
the "colorByte"/"colorFloat" pair don't match each other at all
(`colorFloat` evaluates to near-zero/garbage-looking values). This is a
real second internal record shape, not a bug in reading light 0's
layout — and critically, **it occurs even in a `K=0` file**, so "K=0
means every record is the simple shape" is false. The original
investigation flagged this same variant (a clean small integer — 0, 2,
or 3 — at relative offset 0, functioning as a plausible type tag, with
the color block shifted ~12 bytes later and a second XYZ triple in
between, consistent with a spot/directional light carrying an aim
vector) but could not pin down a reliable rule for detecting it up front
or for exactly when it costs the extra 12 `K` bytes vs. fitting in the
plain 55-byte slot.

Implementing a decoder against only the "normal" shape's field offsets,
without a reliable way to detect the variant first, would silently
misdecode an unknown fraction of real records as if they were valid —
producing plausible-looking-but-wrong radius/color/position data. That's
a worse failure mode than leaving the format undecoded, and is exactly
the kind of mistake this codebase's other decoders (see `WOCParticleParser`,
`WOCObjectParser`'s doc comments) are careful to avoid by only decoding
what's confirmed and stopping honestly at what isn't.

## Suggested next steps for a future session

- Nail down the type-tag hypothesis at record-relative offset 0: gather
  more real "variant" records (start from `WESTERN.LGT`'s 3rd light and
  `AIRSHIP.LGT`'s 2nd light, both already flagged) and check whether a
  small-integer read there reliably predicts the shift in the rest of the
  record, across many files.
- Once variant detection is reliable, a decoder can walk records
  correctly: read the type tag first, then dispatch to the right field
  layout for that record specifically (not per-file).
- The WoC PS2 decompilation project (`Games Files/Reference Files/
  CrashWOC-PS2-Decomp-master/`) has named but not decompiled symbols for
  `edlightAdd`/`edlightcbSaveLightData` — decompiling those specifically
  would likely resolve the variant question directly rather than through
  more statistical inference.
