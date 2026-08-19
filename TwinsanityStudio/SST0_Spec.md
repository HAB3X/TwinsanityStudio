# SST0 Section Reverse Engineering Specification

## Overview
The SST0 section is always the last section in the PS2 GSC file (acts as a footer). It contains a small header, a blob of data, and a trailer. The structure varies slightly between files but follows a consistent pattern.

## Binary Structure

### Header (8 bytes)
| Offset | Size | Type        | Description                                  |
|--------|------|-------------|----------------------------------------------|
| 0x00   | 4    | uint32_le   | FirstField                                   |
| 0x04   | 4    | uint32_le   | BlobLength (size of the following blob data) |

### Blob Data (variable size, length = BlobLength)
The blob consists of N records of a fixed size, where:
- RecordSize = BlobLength / RecordCount
- RecordCount varies per file (observed: 17, 94, ...)
- Observed RecordSize values: 4 bytes (Farm.GSC), 124 bytes (Castle_C.GSC)

#### Farm.GSC Record Structure (4 bytes)
| Offset | Size | Type        | Description         | Example Value |
|--------|------|-------------|---------------------|---------------|
| 0x00   | 1    | uint8       | Byte 0              | 0xE0          |
| 0x01   | 1    | uint8       | Byte 1              | 0x09          |
| 0x02   | 1    | uint8       | Byte 2              | 0xCC          |
| 0x03   | 1    | uint8       | Byte 3              | 0x01          |

Interpretations of the 4-byte pattern:
- As little-endian uint32: 0x01CC09E0 (30,000,320 decimal)
- As little-endian float32: ~7.495×10⁻³⁸
- As big-endian uint32: 0xE009CC01
- As little-endian int32: 30,000,320

The pattern repeats identically for all records in Farm.GSC.

#### Castle_C.GSC Record Structure (124 bytes)
More complex structure; initial bytes match the 4-byte pattern above followed by varying data.
Further analysis needed to determine sub-fields.

### Trailer (variable size)
| Offset | Size | Type        | Description                                  |
|--------|------|-------------|----------------------------------------------|
| 0      | N    | uint8[ ]    | Trailer data                                 |
| N-4    | 4    | uint32_le   | EchoedSectionLength (optional, not universal) |

Trailer length varies:
- Farm.GSC: 12 bytes (last 4 bytes echo the SST0 section length = 0x60)
- Castle_C.GSC: 8 bytes (last 4 bytes = 0x08, does NOT echo section length)
- Airship.GSC: 0 bytes (degenerate case)

## Observed Patterns
1. **FirstField** correlates with record count or type:
   - Farm.GSC: FirstField = 0x01, RecordCount = 17
   - Castle_C.GSC: FirstField = 0x29 (41), RecordCount = 94
   - Relationship not yet determined (possibly FirstField = RecordCount mod 256 or similar).

2. **BlobData** often begins with a repeating 4-byte sequence (E0 09 CC 01) that may represent:
   - A GS (Graphics Synthesizer) packet header (NCYCLE + ADDR)
   - A constant value used as a base for subsequent data
   - A padding or alignment value

3. **Trailer Echo** (last 4 bytes = SST0 total section length) appears in a subset of files (exactly 10/53 observed in corpus) and is always correct when present.

## Parsing Algorithm
1. Read FirstField and BlobLength from header.
2. Read BlobLength bytes as blob data.
3. Determine record structure:
   - If BlobLength % 4 == 0 and all 4-byte chunks are identical → uniform 4-byte records.
   - Else if BlobLength % N == 0 for some N (e.g., 124) → treat as N-byte records.
   - Otherwise treat as opaque blob.
4. Read trailer as remaining bytes.
5. If trailer length >= 4, check if last 4 bytes equal (16 + BlobLength + trailer length) [i.e., total SST0 section length].

## Open Questions
- Exact meaning of FirstField (record count? version? flags?)
- Semantics of the 4-byte pattern (E0 09 CC 01) – GS command, constant, or something else?
- Structure of larger records (e.g., 124-byte records in Castle_C.GSC).
- Whether trailer echo is intentional or coincidental in files where it appears.