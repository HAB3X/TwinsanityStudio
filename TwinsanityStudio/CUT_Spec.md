# WoC `.CUT` (Cutscene) Format — Investigation Notes

Status: **investigated, not implemented**. Three files (`BLACK.CUT`,
`CORRIDOR.CUT`, `STATION.CUT`) have now been mapped. The first two are
complete, gap-free, field-level byte-verified maps; `STATION.CUT` (12,125
bytes, ~12-17x bigger) has a complete, gap-free **region-level** map (every
byte assigned to a region, verified programmatically to sum to exactly
12,125 bytes with zero gaps/overlaps) with full field-level detail only in
the shared/reused regions — its six large per-node "zone" interiors are
accounted for as regions but not fully field-mapped (see below). The
previously load-bearing blocker — the track-header `count`-to-pointer-count
arithmetic disagreement between `BLACK.CUT` and `CORRIDOR.CUT` — is now
**resolved with real cross-file evidence**, not a guess: see "Track-header
list length: resolved with a 3rd file" below. This makes a decoder
implementable in the sense described there, though several fields still
have placed-but-unexplained bytes — see "Why this isn't a parser yet".

## What `.CUT` is

Per-level, plain uncompressed loose files (18 exist on the disc, sizes
695 bytes to ~1.5MB). Names/strings found inside small samples
(`lower_ring`, `top_ring`, `station1`, `CSCoco_group`, `BigPurra_group`)
cross-reference sibling `.GHG` files byte-for-byte in the same folder
(`CSCOCO.GHG`, `BIGPURRA.GHG`) — real evidence this is scripted-sequence
data (camera/prop movement) referencing named actor rigs stored
separately, not dialogue and not an opcode/command script (no
opcode/command-ID structure was found anywhere — ruled out as an
AgentLab-style format).

Small files (under a few KB) are pure scene-graph data. The largest files
(hundreds of KB to 1.5MB) almost certainly carry embedded video/audio
payloads — not investigated.

## Confirmed: the pointer scheme

Every `.CUT` file uses **self-relative pointers**: a `UInt32LE` field
whose high 16 bits are a constant specific to that one file (e.g.
`0x5302` in `BLACK.CUT`, `0x29D6` in `CORRIDOR.CUT`) and whose low 16
bits are a real, valid byte offset within the file. Confirmed by finding
every field matching `(value >> 16) == fileConstant` and checking the low
16 bits land in-range — 24 such fields in `BLACK.CUT`, 42 in
`CORRIDOR.CUT`, forming a real reachable graph rooted at file offset 4.
(Re-derived independently for `CORRIDOR.CUT` in a follow-up session:
confirmed `0x29D6` and 42 fields exactly, matching this note.)

**List-terminator idiom**: a pointer whose low 16 bits equal (or land
just past, rounded to the next 16-byte boundary) the file's own total
size acts as an end-of-list sentinel. Confirmed in both `BLACK.CUT` and
`CORRIDOR.CUT`.

**Address aliasing, confirmed and pervasive**: pointers routinely target
the *middle* of an already-mapped structure rather than a fresh record
start — e.g. one pointer lands on row 2 of a transform block whose row 0
is reached by a different pointer elsewhere; another lands on just the
last float of a Vec4 that's also reached whole by a separate pointer.
This looks like the addressing scheme is genuinely byte/element-level,
not record-level — **a linear "walk records front to back" parser will
not work for this format; it needs a graph walker starting from the root
pointer.**

## Confirmed: shapes reused from elsewhere in this codebase

- **Root record** (32 bytes, offset 0x00): `kind:u32(=1)`,
  `ptr→0x20`, `duration:f32` (58.0 in `BLACK.CUT`, 200.0 in
  `CORRIDOR.CUT`), a sentinel/reserved slot, `ptr→root transform`, two
  `f32` zeros, `ptr` into a second sub-block. Identical shape in both
  files checked.
- **4×4 transform block** (64 bytes): row-major, translation in row 3,
  `w == 1.0` — the exact same shape already confirmed for
  `WOCContainerParser.Instance.matrix` (see that file). Found at least
  twice per file, in separately-headered node records — current evidence
  leans toward "one transform per node," not a per-node keyframe curve
  (checked: the float runs near a transform that aren't the transform
  itself don't normalize as quaternions — `sqrt(x²+y²+z²+w²)` ranged
  0.84–59.0, nowhere near 1.0 — so a compact quaternion-keyframe reading
  is ruled out for those specific runs).
- **"Track" header** (12 bytes): `duration:f32`, `u16`, `u16`,
  `count:u32`. Found twice in `BLACK.CUT` at offsets 0xA0 and 0x1C0, both
  times followed by exactly `count + 1` pointer-tagged fields rather than
  `count` — seen identically in two places in the same file, so this
  looks like a real convention (a fixed extra trailing pointer after a
  genuinely `count`-long array), not a fluke. **Now cross-checked against
  two more files** (`CORRIDOR.CUT`, `STATION.CUT`) — the `count+1` rule
  holds for *some* instances and not others, and the split is now
  understood: see "Track-header list length: resolved with a 3rd file"
  below.
- **Named asset/effect reference**: a node record (16 bytes) with 3
  pointers, one of which resolves to a null-terminated ASCII name (e.g.
  `"STARS2\0"`) immediately followed by 7 `float32` tuning parameters —
  a particle/effect reference with real parameters, not a rig node.
- **Trailing string pool**: in `STATION.CUT`, a pointer resolves exactly
  to a packed, null-terminated string table sitting at the very end of
  the file (`"lower_ring\0top_ring\0station1\0"`).

## Complete byte-accounting: `BLACK.CUT` only

`/Volumes/CRASH/LEVELS/B/INTRO2/BLACK.CUT`, 695 bytes. Every byte has
been assigned to a specific field, verified programmatically to sum to
exactly 695 bytes with zero gaps and zero overlaps. Byte *placement* is
high-confidence throughout; a handful of ranges have their bytes placed
but their semantic *purpose* still only guessed at (noted below).

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x000–0x01F | 32 | Root record: kind=1, ptr→0x020, f32 dur=58.0, ptr-sentinel→0x2D0, ptr→0x050(xform1), f32=0, f32=0, ptr→0x160(mid-xform2) | High |
| 0x020–0x02F | 16 | Zero padding/reserved | High (value), low (purpose) |
| 0x030–0x03F | 16 | Node B header: kind=1, ptr→0x070, ptr→0x0C0, ptr→0x130 | High |
| 0x040–0x04F | 16 | Reserved, non-zero (`00 00 FF×9 00×5`) — mirrors 0x020's slot but filled differently | Bytes high, purpose low |
| 0x050–0x08F | 64 | Transform #1: identity rotation, translation (0,0,-0.843991,1.0) | High |
| 0x090–0x09F | 16 | u32=1, then 12 zero bytes | Medium |
| 0x0A0–0x0AB | 12 | Track header #1: f32 dur=58.0, u16=1, u16=9, u32 count=2 | High |
| 0x0AC–0x0B7 | 12 | 3 pointers (count+1 list): →0x0E0, →0x110, →0x120 | High |
| 0x0B8–0x0BF | 8 | u32=1, f32=0 | Medium |
| 0x0C0–0x0DF | 32 | Two Vec4s: (0,0,0.843991,0), (0,0,1,1) | Bytes high, semantics medium |
| 0x0E0–0x10F | 48 | Record C: f32=1.0, ptr→0x160, u32=0, ptr→0x13C, 32B zero | High |
| 0x110–0x11F | 16 | Record D: u32=1, ptr→0x140, ptr→0x150, f32=0 | High |
| 0x120–0x12F | 16 | Vec4: (0, 0.843991, 0, 0) | High |
| 0x130–0x13F | 16 | Vec4: (0,1,1,1) | High |
| 0x140–0x147 | 8 | 2 pointers: →0x170, →sentinel 0x2C0 | High |
| 0x148–0x14F | 8 | `01 01 00 00`, u32=9 | Low |
| 0x150–0x18F | 64 | Transform #2: identity rotation, translation (0,0,0.968515,1.0) | High |
| 0x190–0x19F | 16 | f32×4: (0, 0, -0.0, 3.028125) | Medium |
| 0x1A0–0x1A3 | 4 | ptr→0x1E0 | High |
| 0x1A4–0x1B3 | 16 | u32=0, u32=8, f32=0.017241 (**= 1/58**, matches the 58.0 duration seen elsewhere), u32=0 | Medium |
| 0x1B4–0x1BF | 12 | f32 dur=59.0, u32=0, u32=2 | Low |
| 0x1C0–0x1CB | 12 | Track header #2: f32 dur=59.0, u16=1, u16=8, u32 count=2 | High |
| 0x1CC–0x1D7 | 12 | 3 pointers (count+1 list): →0x200, →0x220, →0x230 | High |
| 0x1D8–0x1DF | 8 | Zero | High |
| 0x1E0–0x1FF | 32 | 24B zero, ptr→0x240, f32=1.0 | Bytes high, semantics medium |
| 0x200–0x21F | 32 | u32=0, u16(0,1), u32=8, 16B zero | Medium |
| 0x220–0x22F | 16 | STARS2 node record: ptr→0x2B0("STARS2"), ptr→0x2A0, ptr→0x250(mid-block alias), u32=0 | High |
| 0x230–0x29F | 112 | STARS2 parameter blob (7 Vec4s): includes known params 0.2, 3.0, 5.0, 0.05, 3.0, -0.15, 25.0 plus 0.030303, -0.070755, and recurring 58.0/59.0 | Bytes high, full field semantics not exhaustive |
| 0x2A0–0x2AF | 16 | u32=1, u16(1,255), 8B zero | Medium |
| 0x2B0–0x2B6 | 7 | ASCII `"STARS2\0"` | High |

## Complete byte-accounting: `CORRIDOR.CUT`

`/Volumes/CRASH/LEVELS/B/INTRO2/CORRIDOR.CUT`, 976 bytes. Every byte
assigned to a specific field, verified programmatically to sum to exactly
976 bytes with zero gaps and zero overlaps. Pointer constant confirmed as
`0x29D6` (42 pointer-tagged fields found, matching the prior session's
count exactly). Root transform's translation is
`(-10.105168, 0.027334, -0.719901, 1.0)` with a **real, non-identity**
rotation matrix — matches the value predicted before re-derivation and
confirms the transform-block shape holds even when the content (identity
vs. real rotation) differs from `BLACK.CUT`.

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x000–0x01F | 32 | Root record: kind=1, ptr→0x020, f32 dur=200.0, u32=0 (zero — no sentinel ptr here, unlike `BLACK.CUT`), ptr→0x050 (root xform), f32=0, f32=0, u32=0 (zero — no sub-block ptr here, unlike `BLACK.CUT`) | High |
| 0x020–0x02F | 16 | Zero padding/reserved — identical role to `BLACK.CUT` | High (value), low (purpose) |
| 0x030–0x03F | 16 | Node B header: kind=1, ptr→0x070, ptr→0x0C0, ptr-sentinel→0x3D0 (=EOF, exact) | High |
| 0x040–0x04F | 16 | Reserved non-zero blob, **byte-for-byte identical** to `BLACK.CUT`'s blob at the same offset (`00 00 FF×9 00×5`) — cross-file confirmation this is a fixed constant, not per-file data | High (bytes, now cross-file confirmed), low (purpose) |
| 0x050–0x08F | 64 | Root transform: real (non-identity) rotation + translation (-10.105168, 0.027334, -0.719901, 1.0) | High |
| 0x090–0x09F | 16 | u32=1, then 12 zero bytes — same shape as `BLACK.CUT`'s analogous field | High (bytes), medium (purpose) |
| 0x0A0–0x0AB | 12 | Track header #1: f32 dur=200.0 (global dur), u16=1, u16=9, u32 count=7 — the `(1,9)` u16 pair is byte-identical to `BLACK.CUT`'s Track header #1 | High |
| 0x0AC–0x0D7 | 44 | 11 pointers: 4 "fixed-position" (→0x0E0 Record C, →0x110 Record D, →0x120 quad#1, →0x11C alias into Record D's own body) followed by 7 "counted" (→0x134 alias into quad#2, →0x130 quad#2, →0x1A0, →0x210, →0x280, →0x2F0, →0x360 — the 5 periodic node units below). The trailing 7 exactly match `count`; **not** `count+1`. See "Track-header list length" below. | High (bytes), medium (rule) |
| 0x0D8–0x0DF | 8 | f32=1.0, f32=1.0 (`BLACK.CUT`'s analogous slot holds u32=1, f32=0 — different values, same 8-byte size class) | Medium |
| 0x0E0–0x10F | 48 | Record C: f32=1.0, u32=1, u32=0, ptr→0x118 (alias into Record D), u32=0x01010101, u32=257, ptr→0x300, u32=1, u32=1, ptr→0x130, u32=0, u32=0 — different internal field layout from `BLACK.CUT`'s Record C, same 48-byte size class/role | High (bytes), low (purpose) |
| 0x110–0x11F | 16 | Record D: **four** pointers →0x180, →0x170, →0x140, →0x148 (`BLACK.CUT`'s Record D is u32=1, ptr, ptr, f32=0 — a real shape difference, not just values) | High |
| 0x120–0x12F | 16 | Channel-quad #1: (1.0, 0.012658, -10.105168, 0.005487) — 3rd float duplicates the root transform's X-translation | High (bytes), medium (purpose) |
| 0x130–0x13F | 16 | Channel-quad #2: (80.0, 0.008333, -9.584925, 0.011274) | High (bytes), medium (purpose) |
| 0x140–0x14F | 16 | Channel-quad #3: (200.0, 0, -7.861617, 0.021710) — first float matches the global duration. **Not present** in `BLACK.CUT`'s analogous region (`BLACK.CUT` goes straight to Transform #2 at this point) — a real extra field | High (bytes), medium (purpose) |
| 0x150–0x15F | 16 | Int-list quad: u16 pairs (0,1)(1,2)(2,2)(2,0) — a pattern absent anywhere in `BLACK.CUT`'s map; recurs (with minor variants) 6 more times later in this same file | High (bytes), low (purpose) |
| 0x160–0x38F | 560 | Five repeating 112-byte "track node" units at 0x160, 0x1D0, 0x240, 0x2B0, 0x320 — see breakdown below. This entire periodic structure is absent from `BLACK.CUT`; it's the main reason `CORRIDOR.CUT` is bigger (more nodes/tracks, not a differently-shaped format) | High (bytes/periodicity), medium (purpose) |
| 0x390–0x3CF | 64 | Final (6th, truncated-by-EOF) unit: same 48-byte header shape, but its first pointer-array slot is u32=2 (a real count, not the 1.0/80.0 filler value seen in the other five units), followed by u32=1, ptr→0x3DC (past EOF), ptr→0x3E0 (past EOF) — both are end-of-list sentinels — then u32=0, then a 16-byte partial channel-quad-shaped tail cut off by the file boundary: f32=0.719894, f32=80.0, uninterpreted u32=0x1BC819A0 (looks like leftover/non-zeroed data, not text), f32=-0.040676 | High (bytes), medium (purpose) |

**Breakdown of the repeating 112-byte "track node" unit** (5 full instances
at 0x160/0x1D0/0x240/0x2B0/0x320, byte-shape confirmed identical at every
instance):

| Sub-offset | Len | Contents |
|---|---|---|
| +0x00 | 28 | Fixed header: u32=1, u32=0, u32=0x8000, u32=0, u32=0, u32=0, u32=0x80 — byte-identical across all 5 instances |
| +0x1C | 20 | 5-slot pointer array. Slot count actually *used* as real pointers varies per instance (5, 3, 3, 3, 3 respectively) — unused slots hold filler values (seen: 1.0f, 80.0f, u32=1, u32=2), never zero. This is real, confirmed per-instance variation, not noise |
| +0x30 | 16 | Channel-quad "A": f32≈1.0, f32≈0.012658 (constant across all 5), f32, f32 |
| +0x40 | 16 | Channel-quad "B": f32=80.0 (constant), f32≈0.008333 (constant), f32, f32 |
| +0x50 | 16 | Channel-quad "C": f32=200.0 (constant = global duration), f32=0 (constant), f32, f32 |
| +0x60 | 16 | Int-list quad: u16 pairs (0,1)(1,2)(2,2)(2,0) in 4 of 5 instances; the 5th and 6th (truncated) instances show minor variation in the last pair |

No string pool and no named asset/effect reference (the `STARS2`-style
16-byte-header + 112-byte-parameter-blob + name string pattern from
`BLACK.CUT`) were found anywhere in `CORRIDOR.CUT` — a targeted scan for
printable-ASCII runs found only coincidental bytes from recurring float
constants (e.g. `0x3C4F6475` = 0.012658f prints as `"udO<"`), no real
strings. This pattern from `BLACK.CUT` does **not** generalize to every
`.CUT` file; `CORRIDOR.CUT` appears to be pure transform/animation-channel
data with no named-asset references.

### Track-header list length: `count+1` does not generalize

`BLACK.CUT`'s two track headers were each followed by exactly `count + 1`
pointers, with no unaccounted-for pointers before or after. `CORRIDOR.CUT`
breaks that formula: its one track header has `count = 7`, but is followed
by **11** pointers, not 8. Splitting those 11 by target-shape (4 pointers
land on fixed always-present structures — Record C, Record D, and two
values inside/adjacent to them — while the remaining 7 land exactly on the
7 "track node" pointers: the two 16-byte channel-quads at 0x130/0x134 plus
the 5 periodic 112-byte nodes) makes `count` (not `count + 1`) match the
back 7 exactly. But this can't be fully disambiguated against `BLACK.CUT`,
whose small track headers (count=2, 3 total pointers) are equally
consistent with "0 fixed + count+1" or "1 fixed + count" — both single
samples are compatible with more than one rule. **Honest conclusion: the
`count`-to-pointer-count relationship is real and reproducible in shape
(a header, then a run of pointers) but its exact arithmetic is still
unresolved after 2 files** — do not hard-code `count+1` in a decoder.

*(Superseded below — a 3rd file, `STATION.CUT`, resolves this. Left
in place as the honest record of the 2-file state.)*

## Complete byte-accounting: `STATION.CUT` (region-level)

`/Volumes/CRASH/LEVELS/B/INTRO2/STATION.CUT`, 12,125 bytes (~12-17x bigger
than the first two files). Pointer constant confirmed as `0x297A` (77
pointer-tagged fields found). The shared/reused shapes from `BLACK.CUT`/
`CORRIDOR.CUT` — root record, zero-padding block, Node B header, the
`0x040` reserved constant, 4×4 transform, `u32=1`+12-zero block, 12-byte
track header, Record C (48B), Record D (16B), 16-byte channel-quads — all
confirmed present again, byte-for-byte-identical in shape (and in one case,
the `0x040` reserved blob, **byte-for-byte identical in value too**, now
confirmed 3/3 files). What's new: past offset 0x140 the file is dominated
by **six large periodic "zone" regions** (1824-2544 bytes each, 11,776
bytes total), each terminated by a distinctive 16-byte all-bits-set
sentinel (`FF×13, 0x7F, 0x00, 0x00`) — the same *role* as `CORRIDOR.CUT`'s
periodic 112-byte "track node" array (a repeating per-node/per-channel
region), just at a much larger per-unit size reflecting richer per-node
data. Verified programmatically: the region table below sums to exactly
12,125 bytes with zero gaps and zero overlaps.

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x000–0x01F | 32 | Root record: kind=1, ptr→0x020, f32 dur=110.0, ptr→0x2F60 (a **real** pointer here, unlike `CORRIDOR.CUT`'s zero — closer to `BLACK.CUT`'s populated sentinel slot, but landing well inside the file, not near EOF), ptr→0x050 (root xform), ptr→0x2A0 (a pointer where `BLACK.CUT`/`CORRIDOR.CUT` hold an `f32` zero — a genuine 3rd variant of this dword's population), f32=0, f32=0 | High (bytes), medium (which dwords are pointers vs. zero varies per file — the 8-dword skeleton itself is confirmed, its exact population is not) |
| 0x020–0x02F | 16 | Zero padding/reserved — same role, 3rd file confirming it | High |
| 0x030–0x03F | 16 | Node B header: kind=1, ptr→0x070, ptr→0x0C0, ptr→0x280 — **3 real pointers**, matching `BLACK.CUT`'s shape (not `CORRIDOR.CUT`'s sentinel-in-3rd-slot variant) | High |
| 0x040–0x04F | 16 | Reserved blob `00 00 FF×9 00×5` — **byte-for-byte identical** to both other files; now confirmed 3/3, the strongest constant in this format | High |
| 0x050–0x08F | 64 | Root transform: real non-identity rotation, translation (34.833, -3.738, -36.755, 1.0) | High |
| 0x090–0x09F | 16 | u32=1, then 12 zero bytes — identical shape/value to both other files, 3/3 confirmed | High |
| 0x0A0–0x0AB | 12 | **Root/fan-out track header**: f32 dur=110.0 (matches root record's dur), u16=(1,9) (identical pair to `BLACK.CUT` header #1 and `CORRIDOR.CUT`'s only header), u32 count=4 | High |
| 0x0AC–0x0CB | 32 | 8 pointers: →0x0E0 (Record C), →0x110 (Record D), →0x120 (quad#1), →0x110 (**exact duplicate** of the 2nd pointer — a variant of `CORRIDOR.CUT`'s "alias into Record D's body," here aliasing to Record D's own start instead of mid-body), then 4 "counted" pointers →0x128, →0x130, →0x1B0, →0x200 — count(4) matches the last 4 exactly, same "4 fixed + count" rule as `CORRIDOR.CUT`. See resolved discussion below | High (bytes), high (rule, see below) |
| 0x0CC–0x0DF | 20 | f32≈245.038, f32≈-1350.03 (a recurring 8-byte constant pair, also found again at 0x248), then u32=0, f32=1.0, f32=1.0 | Bytes high, purpose low |
| 0x0E0–0x10F | 48 | Record C: f32=1.0, u32=0, u32=0, ptr→0x228, packed bytes `00 01 01 01`, u32=0, ptr→0x100, u32=0, u32=1, ptr→0x310, u32=1, u32=0 — complex non-zero internal layout, matching `CORRIDOR.CUT`'s Record C variant, not `BLACK.CUT`'s mostly-zero one | High (bytes), low (field purposes) |
| 0x110–0x11F | 16 | Record D: **four** pointers →0x1A0, →0x190, →0x140, →0x438 — matches `CORRIDOR.CUT`'s 4-pointer Record D shape, not `BLACK.CUT`'s `[u32=1,ptr,ptr,f32=0]` shape | High |
| 0x120–0x12F | 16 | Channel-quad #1: (0.0, 0.011236, 34.853, -0.020620) | High (bytes), medium (purpose) |
| 0x130–0x13F | 16 | Channel-quad #2: (89.0, 1.0, 33.018, -0.020620) | High (bytes), medium (purpose) |
| 0x140–0xB2F | 2544 | **Zone 1**: local Record-C/Record-D-analog pair (at 0x3E0/0x410) feeding a **secondary track header at 0x3A0** (dur=111.0, u16=(1,9), count=4, 5 trailing pointers — see below), plus further undecoded per-channel float data; terminated at 0xB20 by the 16-byte `FF×13,7F,00,00` sentinel | High (boundaries, header sub-record), low (bulk interior) |
| 0xB30–0x124F | 1824 | **Zone 2**: opens with a Record-C/Record-D-analog pair at 0x1250 (4 pointers, one of which — confirmed by exact-match search — targets 0x1970, i.e. **into Zone 4**, a real cross-zone reference) plus undecoded interior; terminated at 0x1240 by the sentinel | Medium (boundaries, entry record), low (bulk interior) |
| 0x1250–0x196F | 1824 | **Zone 3**: undecoded interior (its lead-in record at 0x1250 is counted above as part of Zone 2's byte range per the marker-boundary convention used here — see caveat below); terminated at 0x1960 by the sentinel | Medium (boundary), low (interior) |
| 0x1970–0x20FF | 1936 | **Zone 4**: opens directly with a **secondary track header at 0x1970** (dur=111.0, u16=(1,9), count=4, 5 trailing pointers, pointed to explicitly by a pointer at 0x1254 — the only track header of the three that's reached *by pointer* rather than positionally), feeding a local Record-C/Record-D-analog pair at 0x19B0/0x19E0, plus undecoded interior; terminated at 0x20F0 by the sentinel | High (boundaries, header sub-record), low (bulk interior) |
| 0x2100–0x281F | 1824 | **Zone 5**: undecoded interior; terminated at 0x2810 by the sentinel | Medium (boundary), low (interior) |
| 0x2820–0x2F3F | 1824 | **Zone 6**: undecoded interior; terminated at 0x2F30 by the sentinel | Medium (boundary), low (interior) |
| 0x2F40–0x2F5C | 29 | Trailing string pool: `"lower_ring\0top_ring\0station1\0"` — the exact pool already referenced (but not located byte-for-byte) in the "Confirmed" section above | High |

Caveat on the zone table: the "6 zones bounded by the FF-sentinel" division
is a real, verified partition of the bytes (boundaries found by an exact
16-byte pattern search, not inferred), but zone *content* attribution near
each boundary (e.g., whether a lead-in record belongs to the zone before
or after its sentinel) is a modeling choice, not independently confirmed —
flagged medium confidence for that reason. The zone interiors themselves
(the bulk of ~11,776 of the file's 12,125 bytes) are **not** field-mapped;
each zone almost certainly contains many more 16-byte channel-quads and
possibly further nested pointer records (the two zones with a located
track header show the same Record-C/Record-D/quad vocabulary already
confirmed at the root level, just repeated locally), but this session did
not push that far — analogous to `CORRIDOR.CUT`'s periodic track-node
region, just untyped at the sub-field level here for time reasons, not
because the bytes resisted decoding.

### Track-header list length: resolved with a 3rd file

`STATION.CUT` contains **three** real instances of the 12-byte track
header shape (found by an exhaustive scan of every 4-byte-aligned offset
in the file for `u16 pair == (1,9)` immediately following a plausible
`f32` duration — this is exhaustive, not a sample: no other instance of
this exact header exists anywhere in the file). All three instances share
the **identical** `(u16,u16)=(1,9)` pair and the **identical** `count=4`,
yet split cleanly into two different pointer-count outcomes:

| File | Header offset | Role | count | actual trailing ptrs | delta |
|---|---|---|---|---|---|
| `BLACK.CUT` | 0x0A0 | only node in the file | 2 | 3 | **+1** |
| `BLACK.CUT` | 0x1C0 | only node in the file | 2 | 3 | **+1** |
| `CORRIDOR.CUT` | 0x0A0 | root/fan-out (feeds 5 periodic nodes) | 7 | 11 | **+4** |
| `STATION.CUT` | 0x0A0 | root/fan-out (feeds the 6 zones) | 4 | 8 | **+4** |
| `STATION.CUT` | 0x03A0 | per-node, inside Zone 1 | 4 | 5 | **+1** |
| `STATION.CUT` | 0x1970 | per-node, inside Zone 4 | 4 | 5 | **+1** |

This is decisive, real evidence, not a guess: **the delta is determined by
the header's structural role, not by `count` or by the header's own bytes**
(`STATION.CUT`'s three headers are byte-identical in their `(u16,u16)` and
`count` fields and still split 4/1/1). Two roles, confirmed with zero
exceptions across 6 total instances in 3 files:

- **Root/fan-out track header**: found exactly once per file, always
  reached *positionally* (immediately after the fixed prologue: root
  record → zero-padding → Node B header → root transform → `u32=1`+12-zero
  block), never targeted by any pointer. Its trailing pointers =
  **4 fixed** (→Record C, →Record D, →quad#1, →an alias back into Record
  D — the exact alias target varies: `CORRIDOR.CUT` aliases to
  Record D + 0xC, `STATION.CUT` aliases to Record D + 0x0, i.e. an exact
  duplicate of the 2nd pointer) followed by **`count`** further pointers,
  one per fanned-out node/channel. Confirmed identically in `CORRIDOR.CUT`
  (count=7 → 11) and `STATION.CUT` (count=4 → 8) — 2/2 files that have
  this kind of header agree exactly.
- **Per-node/secondary track header**: found once per animated node,
  reached either positionally (after that node's own local lead-in
  structure, as in `STATION.CUT` Zone 1's header at 0x3A0) or via a direct
  pointer from elsewhere (as in `STATION.CUT` Zone 4's header at 0x1970,
  pointed to explicitly by the pointer at 0x1254). Its trailing pointers =
  **`count + 1`**. Confirmed in `BLACK.CUT` (both headers) and
  `STATION.CUT` (both secondary headers) — 4/4 instances across 2 files
  agree exactly.

**Why this isn't a contradiction with the old 2-file finding**:
`CORRIDOR.CUT`'s single header and `BLACK.CUT`'s two headers were never
testing the same rule — `CORRIDOR.CUT`'s happened to be the root/fan-out
variant, `BLACK.CUT`'s were both the per-node variant. `BLACK.CUT` (695
bytes, apparently a single-node file) simply has no periodic multi-node
array to fan out to, so it never exercises the root/fan-out header shape
at all — its lone track header goes straight to the per-node form. This
isn't fully airtight (a root/fan-out header with `count=1` would be
byte-indistinguishable from a per-node header with `count=1` using only
this rule — role, not count, is still the real discriminant, and role
currently has to be inferred from parse order: is this the file's *first*
track header, reached without following any pointer?), but it is a real,
falsifiable, cross-file-confirmed pattern with zero counterexamples in 6
instances across 3 files, which is a meaningfully stronger evidentiary bar
than the 2-file state this section previously described.

**Practical takeaway for a decoder**: when parsing the fixed positional
prologue and encountering the *first* track header (the one reached
without following a pointer), read `4 + count` trailing pointers. Every
subsequent track header encountered while walking the graph (reached via
pointer or positionally after a node's own lead-in) should read
`count + 1` trailing pointers. This is implementable — parse order tells
you which rule applies, no header-byte heuristic is needed.

## Side-by-side comparison: `BLACK.CUT` vs. `CORRIDOR.CUT`

**Identical in shape (confirmed cross-file):**
- Self-relative pointer scheme (`(value>>16)==fileConstant`, low 16 bits
  = in-range offset) — same mechanism, different per-file constant.
- List-terminator idiom (pointer whose low 16 bits land at/past EOF) —
  confirmed in both, though `CORRIDOR.CUT`'s two sentinels (`0x3DC`,
  `0x3E0`) overshoot EOF by 12 and 16 bytes rather than landing exactly on
  it, so "rounds to a 16-byte boundary" is not quite right either — both
  are just "past EOF," full stop.
- Zero-padding block at 0x020 (16 bytes).
- The reserved blob at 0x040 — **byte-for-byte identical**, the strongest
  single piece of cross-file evidence in this investigation: this 16-byte
  sequence is a genuine fixed constant, not incidentally-similar per-file
  data.
- 4×4 transform block (64 bytes, row-major, translation in row 3, w=1.0)
  — same shape confirmed with *different* content: `BLACK.CUT`'s is
  identity rotation, `CORRIDOR.CUT`'s is a real non-identity rotation —
  good evidence the shape, not just the zero-filled special case, holds.
- 12-byte track header (`f32 dur, u16, u16, u32 count`) — same shape, and
  `CORRIDOR.CUT`'s `(u16,u16)=(1,9)` is literally identical to
  `BLACK.CUT`'s Track header #1.
- Root record's 32-byte, 8-dword skeleton (kind/ptr/dur/slot/ptr/f32/f32/
  slot) — same positions and field *types*, but not the same population
  (see differences).

**Real, confirmed differences (not just "bigger"):**
- Root record: `BLACK.CUT` populates the 4th dword as a sentinel pointer
  and the 8th dword as a pointer to a second sub-block; `CORRIDOR.CUT`
  leaves both zero. `CORRIDOR.CUT` apparently has no second root-level
  sub-block.
- Node B header's 3rd field: a real pointer to further structure in
  `BLACK.CUT`, an end-of-list sentinel in `CORRIDOR.CUT`.
- Record C and Record D reuse the same *size classes* (48 and 16 bytes)
  in both files but have **different internal field layouts** (different
  pointer counts and positions) — these are not fixed formats, they're
  count/context-dependent chunks that happen to share a size class.
- `CORRIDOR.CUT` has a third channel-quad (0x140, prefix 200.0) that
  `BLACK.CUT`'s analogous region does not have.
- The big structural difference: `CORRIDOR.CUT` has a **periodic run of
  five (plus one truncated) 112-byte "track node" units** (0x160–0x3CF,
  600 of the file's 976 bytes) that has no counterpart anywhere in
  `BLACK.CUT`. This — not a different record vocabulary — is why
  `CORRIDOR.CUT` has 42 pointers against `BLACK.CUT`'s 24: one track
  header fanning out into many more same-shaped nodes, not new record
  types.
- `BLACK.CUT` has a named `STARS2` effect reference (16-byte header + 112-
  byte parameter blob + null-terminated name). `CORRIDOR.CUT` has **no**
  named asset/effect reference and **no** string pool anywhere in the
  file — this pattern is confirmed present in at least one `.CUT` file
  and confirmed absent in another; it's optional/content-dependent, not
  universal.

## Why this isn't a parser yet

1. **Three files now have byte-accounting** (`BLACK.CUT`, `CORRIDOR.CUT`
   field-level gap-free; `STATION.CUT` region-level gap-free, field-level
   within the shared/reused regions only). The track-header list-length
   arithmetic that blocked this before is now resolved with real cross-file
   evidence (see "Track-header list length: resolved with a 3rd file"
   above) — that specific blocker is gone. What's left before this
   codebase's own "confirmed" bar (see `WOCAIParser.swift`'s doc comment:
   "confirmed by exact byte consumption") is fully met: `STATION.CUT`'s six
   large per-node zones (11,776 of its 12,125 bytes) are accounted for as
   regions but not decoded field-by-field, so several record shapes that
   likely repeat inside them (channel-quads, possibly further nested
   Record-C/D pairs) are only confirmed at the two zones that happen to
   contain a track header, not all six. A 4th file, or a deeper pass over
   `STATION.CUT`'s own zone interiors, would still add confidence.
2. **It's a graph, not a pure record stream — but not a pure graph
   either.** Several structures (the root record's own dwords, the
   zero-padding block, Node B's header) are reached purely positionally
   (nothing points at file offset 0x030 in either file — it's read
   because it immediately follows the 16-byte padding block, not because
   a pointer names it). The variable/large content (transforms, track
   nodes, effect blobs) *is* reached by pointer-following, with confirmed
   address-aliasing (pointers landing mid-structure). A real decoder needs
   a **hybrid**: a small fixed positional prologue, then a pointer-
   following graph walker for everything reachable from it — not a purely
   linear scanner and not a purely address-driven graph walk either.
3. **Several fields are "bytes placed, purpose guessed"** in both files.
   Implementing against a guessed purpose (rather than an open/undecoded
   field) risks presenting a wrong interpretation as settled fact —
   exactly what this codebase's decoders elsewhere are careful never to do
   (see `SpecRecord`'s own doc comment for the pattern: expose confirmed
   fields typed, leave the rest raw and explicitly flagged as open).

## Decoder design sketch (not implemented — for a future session)

1. **Constant derivation**: read the dword at file offset 4; its high 16
   bits are this file's pointer constant. (Confirmed convention in both
   files — offset 4 is always the root record's 2nd dword, always a valid
   pointer.)
2. **Fixed positional prologue** (confirmed identical across both files,
   read without following any pointer):
   - 0x000–0x01F: root record (32 bytes, 8 dwords).
   - 0x020–0x02F: zero-padding block (16 bytes).
   - 0x030–0x03F: Node B header (16 bytes) — reached positionally, not by
     pointer.
3. **Graph walk from there**, following every dword matching
   `(value >> 16) == fileConstant` and `(value & 0xFFFF) < fileSize`:
   - Maintain a **visited-offsets** set keyed by exact byte offset (not
     record start), since aliasing means two different pointers can
     legitimately target different bytes inside the same record.
   - Maintain a separate **record-start** map (offset → inferred type) so
     a second pointer landing mid-record can be resolved as "byte N into
     record X" rather than misread as a new record.
   - A pointer whose target's low 16 bits are ≥ file size is a
     terminator/no-op, not a decode error.
4. **Record-type dispatch cannot be pure byte-sniffing.** A 16-byte
   channel-quad (`f32, f32, f32, f32`) and the first 16 bytes of a 12-byte
   track header padded to 16 are not reliably distinguishable by content
   alone (both are 4 arbitrary-looking dwords). Dispatch must primarily
   use **which field pointed here** (the referencing record's own type +
   slot index tells you what's expected at the target) with byte-shape
   validation (size-class match, known-constant recognition like the
   `0x40` reserved blob or the `(1,0,0x8000,0,...,0x80)` 28-byte node
   header) as a secondary check, not the primary signal.
5. **List vs. single record**: detected two ways so far, and a decoder
   should support both rather than assuming one: (a) an explicit
   `u32 count` in a preceding track header — now resolved (see
   "Track-header list length: resolved with a 3rd file" above): the
   *first* track header reached in the graph (positionally, before any
   pointer is followed) takes `4 + count`; every subsequent one takes
   `count + 1`; (b) scanning a run of consecutive pointer-tagged dwords
   starting right after a known anchor until hitting either a non-pointer
   value or an EOF-sentinel.

## Suggested next steps for a future session

- The track-header arithmetic blocker is resolved (3 files, 6 instances,
  zero exceptions — see above). Implement the hybrid positional-prologue +
  pointer-graph-walker sketched above, producing a real node tree/graph
  rather than a flat record list; use the `4+count` / `count+1` split by
  parse order as described in point 5 below.
- `STATION.CUT`'s six per-node "zones" (bounded by the `FF×13,7F,00,00`
  sentinel) are still only region-mapped, not field-mapped, for ~11.8KB of
  the file's 12.1KB. Two of the six zones are partially decoded (they
  contain the located secondary track headers and their local
  Record-C/Record-D pairs); the other four are wholly undecoded interiors.
  Pushing those to field-level — likely more channel-quads and possibly a
  `CORRIDOR.CUT`-style periodic sub-array per zone — is the natural next
  target, and doesn't require a new file, just more time on this one.
- A 4th file (a different size class again, and ideally one *without* a
  string pool, to further test which patterns are universal vs.
  content-dependent) would still strengthen confidence before calling any
  of this "confirmed" by this codebase's own bar.
- The "channel-quad" triple (prefixes 1.0 / 80.0 / 200.0, with 0.012658
  and 0.008333 recurring as small near-constant seconds fields) and the
  `(0,1)(1,2)(2,2)(2,0)` int-list quad found throughout `CORRIDOR.CUT`'s
  periodic track-node region are new, reproducible patterns with no
  semantic reading yet — worth deliberately hunting for in a 3rd file
  before guessing at their meaning.
