# SST0 Section Reverse Engineering Specification

Status: **solved and implemented** (`WOCSplineSetParser.swift`). The real
handler is `ReadNuIFFGSplineSet` (`SST0` = "Spline Set", not an unnamed
footer blob) -- found in real decompiled source and verified byte-exact
against the entire real corpus (41/41 files with a nonempty blob, zero
exceptions). See `WOCContainerParser.parseFooterHeader(_:)`'s doc comment
for the outer-shape investigation history this builds on.

## Confirmed structure

### Outer header (8 bytes) + blob

| Offset | Size | Type      | Description                                    |
|--------|------|-----------|-------------------------------------------------|
| 0x00   | 4    | uint32_le | `numSplines`                                     |
| 0x04   | 4    | uint32_le | `blobLength` (exact byte length of the blob below) |
| 0x08   | `blobLength` | bytes | The blob -- `numSplines` back-to-back spline records |

This part was already confirmed by an earlier investigation pass
(`WOCContainerParser.parseFooterHeader`) and is unchanged.

### Blob internals: `numSplines` inline spline records

**The real shape, found in `Games Files/Reference Files/OpenCrashWOC-main/
code/src/nu3dx/nuscene.c:132-159` (`ReadNuIFFGSplineSet`, marked `//MATCH
NGC`)**: not a separate header table (both earlier hypotheses below were
wrong), but `numSplines` records placed directly back-to-back, each an
8-byte inline header immediately followed by that spline's own point
data:

```
SplineRecord := len:Int16LE  pad:Int16LE(unused)  nameOffset:Int16LE  pad2:Int16LE(unused)
                Vec3(len)     -- len*12 bytes, immediately inline
```

`len` is the point count for this spline; `nameOffset` is a byte offset
into a name table populated elsewhere in the file (the C source reads
`gsc->nametable + nameOffset` -- not resolved by this parser, exposed as
a raw offset). The next record starts immediately after this spline's
own `len*12` bytes of points -- no padding, no alignment, self-describing
purely via each record's own `len`.

**One real correction to the decompiled source's exact byte offsets**:
the C source reads `len`/`nameOffset` via `*(s16*)(temp+2)` -- i.e. at
sub-offsets 2 and 6 within each 4-byte slot. Direct byte verification on
`FARM.GSC` (`blob.count=68`, `numSplines=1`, real bytes `05 00 00 00 8e
00 00 00 ...`) shows `len=5` actually sits at sub-offset **0**, not 2
(`5*12+8 == 68` exactly; reading at offset+2 instead gives `len=0`, which
cannot be right for a 68-byte single-spline blob). Trusting the real
bytes over that one pointer-arithmetic detail (plausibly a decompiler
artifact in this "reconstructed" source tree, not raw disassembly) is
what achieves the 41/41 exact-fit result.

**Verification, not sampling**: for every one of the 41 real files with a
nonempty `SST0` blob, decoding `numSplines` records this way and summing
`8 + len*12` per record lands on `blob.count` exactly -- zero leftover,
zero overrun, checked programmatically across the whole real corpus (see
`WOCSplineSetParserTests.testEveryRealSST0BlobConsumesExactly`).

### Trailer (variable size, unchanged from the outer-header investigation)

A minority of files (10/53 observed) echo the section's own total length
in the trailer's last 4 bytes; most don't. Not otherwise decoded.

## What this supersedes

This document originally guessed a **fixed-width record table**
(`RecordSize = BlobLength / RecordCount`, e.g. "4-byte records" for
`Farm.GSC`, "124-byte records" for `Castle_C.GSC`) and treated `FirstField`
as loosely correlated with record count. Both were wrong -- there is no
fixed record width; each spline record's length is `8 + len*12`, which
varies per spline, and `FirstField` is exactly `numSplines` (not a
loosely-correlated count). Two more targeted hypotheses tried in a later
investigation pass (an inline per-spline name between splines; a fixed
12-byte header table matching `nugspline_s`'s field order) were also
directly tested against real bytes and refuted -- see
`WOCContainerParser.swift`'s `SST0` doc comment for that history. The real
shape (found afterward, from real decompiled source rather than further
guessing at variations on `.VIS`'s already-solved shape) is the one
documented above.

## Still open

- What `nameOffset` resolves against -- which name table, and whether
  it's the same `NTBL` section this codebase already decodes elsewhere in
  `.GSC` files.
- Semantic meaning of each spline's point data beyond "a spline" (e.g.
  which gameplay/camera/AI system consumes these -- `.VIS`'s own solved
  camera-path data is a structurally unrelated section).
