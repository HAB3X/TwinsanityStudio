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

## Update: real decompiled source found (`OpenCrashWOC-main`), partial confirmation

`CrashWOC-PS2-Decomp-master` (this doc's original lead) turned out to be a
Ghidra symbol-table export only -- `edlightAdd`/`edlightcbSaveLightData`
have an address and a size, no body, no struct fields. But
`OpenCrashWOC-main/code/src/gamecode/lights.c:41-103` (`LoadLights()`,
annotated `//94% NGC` -- an alpha GameCube-port reconstruction, not raw
PS2, so not gospel) has real, load-bearing source, independently
corroborated by real DWARF debug info in the same tree
(`code/src/dump_alphaNGCport_DWARF.txt:4187-4204`, typedef `Ed_Light`,
compiler-verified field offsets):
```
type:Int32 pos.xyz:Float32x3 radius_pos.xyz:Float32x3 radius:Float32
r,g,b:UInt8x3 colour.rgb:Float32x3
[if type==1 || type==2: direction.xyz:Float32x3]   -- +12 bytes
globalflag:UInt8(stored as Int32) brightness:UInt8(stored as Int32)
```
This is exactly 55 bytes in the base case and 67 (55+12) in the
`type==1`/`2` case -- matching this doc's own confirmed 55-byte base and
`K`-costs-12-extra-bytes finding precisely, from an independent source.

**Directly re-verified against the real `AIRSHIP.LGT` on disk (not just
trusting the agent report)**: applying this field order to light **1**
(absolute file offset 83) decodes cleanly and self-consistently --
`radius=2.311786`, `colour=(0.749,0.749,0.749)` matching `191/255` (the
byte triple) to full float precision, and `radius_pos` equal to `pos`
except on one axis offset by ≈`radius` (a real, redundant, internally-
consistent encoding, not coincidence). **This independently confirms
this doc's "normal shape" field layout is exactly right.**

**But light 0 (offset 28) still does NOT decode cleanly** under this same
field order -- `type` reads as a nonsense ~1.1 billion, `radius` as
~-2.5e38 -- and since `K=0` for this file, it can't simply be "light 0 is
the type-1/2 extended variant" (that would need 12 extra bytes this file's
size doesn't have room for). **The original "second shape" problem is
therefore still open, but now with a concrete new hypothesis, not just a
statistical anomaly**: `LoadLights()` reads four leading counts --
`LIGHTCOUNT, AMBIENTCOUNT, DIRECTCOUNT, POINTCOUNT` -- but the function
body shown only ever loops `LIGHTCOUNT` times with a flat, inline
`type`-tag read; the other three counts are read and never used again in
what's shown. That's suspicious for a `//94%`-confidence reconstruction
of an alpha port -- the real retail algorithm may bucket records by type
(ambient records without a `pos`/`direction`, say) rather than a single
uniform loop, which would explain why record 0 specifically (not a random
middle record) fails to fit -- entry order may not be "N identical
records" but "N1 ambient + N2 directional + N3 point", each with a
genuinely different width, and this file's header fields (relative offset
0/4/8/12, previously observed as `(1,1,0,1)` in this same file) may
BE `LIGHTCOUNT`/`AMBIENTCOUNT`/`DIRECTCOUNT`/`POINTCOUNT` directly rather
than an unrelated 4-int header -- worth checking directly: `AIRSHIP.LGT`'s
own header is literally `(1,1,0,1)`, i.e. plausible small counts, not
previously read that way.

## Suggested next steps for a future session

- **Test the bucketed-count hypothesis directly**: check whether
  `AIRSHIP.LGT`'s header `(1,1,0,1)` really means 1 ambient-type light (no
  `pos`/`direction`, narrower record) + 1 directional/point light (the
  already-confirmed 55-byte "normal" shape, matching light index 1) --
  i.e. try decoding light 0 as a *narrower* ambient-specific record rather
  than assuming it's the same 55-byte shape gone wrong. This is a much
  more promising lead than continuing to search for a type tag inside a
  uniform record.
- If that doesn't resolve it, the PS2-native (not NGC-port) disassembly,
  if `OpenCrashWOC-main`'s `PS2_Version/` directory has anything
  equivalent to `lights.c`, would be worth checking specifically --
  `lights.c` itself is explicitly flagged 94% confidence, alpha-port, not
  retail PS2.
