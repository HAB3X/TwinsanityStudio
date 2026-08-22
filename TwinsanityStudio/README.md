# Twinsanity Studio

A native macOS editor for *Crash Twinsanity* (PS2/Xbox) and *Crash Bandicoot:
The Wrath of Cortex* (PS2) game files, built in Swift + SwiftUI. It reads
`.BD`/`.BH` archives and `.RM2`/`.SM2` level/scenery files directly, decodes
textures, models, skins, skeletons, and animations, cross-links a model to
its own materials/textures/skeleton instead of showing them as unrelated
files, and gives you a full 3D Level Viewer — walk a level, place new
objects from a palette, drag gizmos to move/rotate things, and save your
changes back out. Wrath of Cortex support layers on top of that: mount a
disc image, browse levels/textures/sounds/AI/scenery, and view real
per-object mesh geometry decoded straight from the PS2 disc format.

The Twinsanity side of this is a port of the community
[Twinsanity Editor](https://github.com/Smartkin/twinsanity-editor) (C#/.NET)
to Swift — see [Acknowledgments](#acknowledgments) below. The Wrath of
Cortex side is reverse-engineered from scratch; nothing like it existed
before.

**macOS only, for now.**

## Features

- Full `.BD`/`.BH` archive browsing, with a real chunk tree, search, and a
  type filter that jumps straight to every decoded texture/model/skeleton/
  animation across a whole archive.
- Textures (PS2 PSMCT32/PSMT8 swizzle+palette, Xbox DXT5), rigid and skinned
  models (a from-scratch PS2 VIF/VU microcode interpreter), skeletons, and
  animation curves, all fully decoded — not just browsable.
- A Metal-based Model Viewer: fully textured, orbit/zoom, animation
  scrubbing, one-click export to OBJ+MTL+PNG+animation JSON.
- A full 3D Level Viewer: walk a real level, see placed objects/triggers/
  cameras/AI waypoints/collision geometry together in one viewport, drag
  gizmos to edit, place new objects from a searchable palette with live
  thumbnails, and save your edits back out (byte-exact patches, never a
  blind overwrite — the original file is never touched).
- Mount a real `.iso`/`.bin`+`.cue` disc image and browse it like any other
  archive; rebuild a patched `.iso` with a file replaced, or build a
  brand-new bootable-shaped `.iso` from scratch out of a folder tree
  (**Image Maker** — a real, from-scratch ECMA-119 image builder, verified
  byte-for-byte through this app's own disc reader; not hardware-tested).
- Export edits as a `.crate`, installable through
  [CrateModLoader](https://github.com/DorratzOG/CrateModLoader).
- Real add/remove/duplicate for `Position`/`GameObject`/AI waypoint/AI path
  records (not just editing existing ones), a full variable-length
  `Instance` record editor (every child-ID list, not just the transform),
  and a generic ID Editor for reassigning any record's ID within its
  section — the same real, narrow behavior (and same limitation: nothing
  else that references an ID by value gets updated) the reference editor's
  own tools have.
- Browse standalone `.ptc`/`.psm`/`.psf` font/particle-sprite sheets —
  real embedded texture+material decode and PNG export; no write-back yet
  (would need a from-scratch PS2 texture encoder this build doesn't have).
- **Wrath of Cortex**: RNC ProPack decompression, full container format
  decode, real per-object mesh geometry (positions + triangle connectivity,
  reverse-engineered from the raw PS2 chunk data), texture decode, a
  centralized sound archive decoder (PS-ADPCM), AI/scenery/animation/path
  data, and chunk-stitching that pulls in a neighboring chunk's real
  actors/triggers/cameras, not just its terrain.

## Project layout

This is a **Swift Package**, not a hand-authored `.xcodeproj` — Xcode opens
and builds SPM packages natively (editing, running, testing, and even
SwiftUI Previews all work identically to a classic project), and it's the
only structure that could actually be verified end-to-end from the command
line while building this.

```
TwinsanityStudio/
  Package.swift
  Sources/
    CTCore/       Binary I/O primitives, endianness, the generic chunk header format
    CTModels/     Plain-data models: TextureAsset, MeshAsset, SkeletonAsset, AnimationAsset, MaterialInfo,
                  ChunkNode, and ResolvedModelAsset/AssetResolver (linked asset resolution)
    CTParsers/    BD/BH, RM2/SM2 chunk tree, Texture (PS2 + Xbox), VIF interpreter, Model/Skin,
                  Material/TwinsShader, GraphicsInfo/Animation, disc image (ISO-9660) support,
                  and the Wrath of Cortex format family (CrossEngine/)
    CTExport/     PNG export, OBJ export (with .mtl linkage), archive repackaging
    CTStudioApp/  The SwiftUI app: sidebar / inspector / 3D viewport, drag-drop, search, type filter,
                  the Metal-based Model Viewer and Level Viewer (ModelViewer/), and the
                  Wrath of Cortex level/sound browser (WOCViewer/)
  Tests/
    CTCoreTests/     BinaryCursor/BinaryWriter/ChunkHeader
    CTParsersTests/  Every parser and writer above, plus the Wrath of Cortex format decoders
    CTExportTests/   OBJ export (incl. mtllib linkage), PNG export, archive repackaging
```

`CTCore` → `CTModels` → `CTParsers` → `CTExport` → `CTStudioApp` is a strict
dependency chain (each only depends on the ones before it), so the parsing
engine is fully usable as a library without the app, and every layer has its
own test target.

## Setup & running in Xcode

1. **Requirements**: Xcode 15+ on macOS 14 (Sonoma) or later.
2. Open the package: `File ▸ Open…` and select `TwinsanityStudio/Package.swift`
   (or just double-click `Package.swift` in Finder — it opens directly in Xcode).
3. Xcode resolves the package graph automatically (no external dependencies —
   everything here is first-party) and creates a scheme per product:
   **TwinsanityStudio** (the app) plus the individual library schemes
   (`CTCore`, `CTModels`, `CTParsers`, `CTExport`).
4. In the scheme selector, choose **TwinsanityStudio** with **My Mac** as the
   run destination.
5. **Build**: `⌘B`. **Run**: `⌘R`. **Test**: `⌘U`.

### Using the app

- Drag a `.BH` archive, a loose `.RM2`/`.SM2`/`.RMX`/`.SMX` file, a `.iso`
  disc image, or a folder onto the window — or `⌘O` to pick one.
- The sidebar shows the chunk tree; selecting an unparsed entry parses it
  automatically. Search by name/section/record ID, or use the type filter to
  jump straight to every decoded asset of one kind — click **Scan Archive**
  first so it can look inside files you haven't opened yet.
- A texture/mesh/skeleton/animation record's inspector has an **Open in
  Model Viewer** button — fully textured, with animation scrub and one-click
  export.
- A level's Scenery record opens the **Level Viewer**: walk the level,
  select/edit placed objects, triggers, cameras, and AI waypoints, place new
  ones from the Forge Palette, and save your changes.
- **Library ▸ Wrath of Cortex Levels / Wrath of Cortex Sounds** browses a
  mounted WoC disc — real levels, textures, and playable sound clips.

## Command-line build & test

```bash
cd TwinsanityStudio
swift build
swift test
```

If your Mac's active developer directory is the standalone Command Line
Tools rather than Xcode (`xcode-select -p` prints
`/Library/Developer/CommandLineTools`), `swift test` will fail with
`no such module 'XCTest'` — the CLT package doesn't ship the XCTest
framework. Xcode itself doesn't care about this, but for the command line,
either point that one invocation at Xcode's toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

or switch the system default (needs your password, affects every
`swift`/`xcodebuild` invocation system-wide until changed back):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Format notes & known limitations

The Twinsanity side of this port is grounded directly in the original C#
source, not reverse-engineered from scratch — see the doc comments on
`BDArchiveParser`, `RM2Parser`, `TextureParser`, `VIFInterpreter`,
`ModelParser`/`SkinParser`, and `GraphicsInfoParser`/`AnimationParser` for
exact provenance. The Wrath of Cortex side (`CrossEngine/`) *is*
reverse-engineered from scratch against the real PS2 disc format, with
every doc comment stating plainly what's confirmed, what's a working
hypothesis, and what's still unsolved — nothing here claims more certainty
than the evidence supports.

A few things are deliberately out of scope rather than guessed at:

- **Endianness**: PS2 (MIPS) and Xbox (x86) Twinsanity data are *both*
  little-endian in practice — the real PS2/Xbox split shows up in
  *pixel/vertex layout* (GS-swizzled paletted textures vs. DXT5), not byte
  order.
- **Browsable but not deep-decoded**: Xbox `ModelX`/`SkinX` (no VU hardware
  on Xbox, so it isn't VIF-encoded, and there's no verified layout to
  decode it against), `BlendSkin` morph-target blobs, and the WoC `OBJ0`
  format's per-chunk trailing data block (real vertex positions and
  triangle connectivity decode; UV coordinates don't yet).
- **Animation playback** scrubs through decoded per-frame channel values,
  not a live-deformed skinned mesh — the joint-matrix math isn't fully
  pinned down even in the reference tool's own viewer code.
- **Demo-format RM2/SM2 variants** aren't auto-detected (no on-disk flag to
  detect them by) — files are parsed as retail-format by default, matching
  the actual retail disc.

## Saving edits & getting them onto real hardware

Every edit path in this app writes to a **new file or folder**, never in
place — the original archive/disc image on disk is never modified.

- **Save Chunk Overrides… / Save Edited Copy…**: patches only the bytes of
  the specific record(s) you changed into a full copy of the original file.
  Every writer has a round-trip test proving `parse(write(parse(x))) ==
  parse(x)`.
- **Export as Mod Crate…**: packages the same patched bytes into a real
  `.crate`, installable through
  [CrateModLoader](https://github.com/DorratzOG/CrateModLoader).
- **Replace in Disc Image…**: rebuilds a complete new `.iso` with one file's
  contents replaced via a real ISO-9660 directory-record patch, not a raw
  byte splice. `.bin`/`.cue` raw-sector images aren't rebuildable yet.
- **Archive Repackager** (`.BH`/`.BD`): rebuilds a complete new archive pair
  with entries replaced, streaming untouched entries straight through.

**What "verified" means here, honestly**: every writer's output round-trips
correctly back through this app's own parser. What hasn't been verified,
because doing so needs hardware this project has no access to, is whether
an edited file actually **boots and runs correctly on a real PS2** or in an
emulator — no claim here should be read as hardware-tested. If you try
something on real hardware or an emulator, that's the actual verification
step, and issues found there are genuinely useful to report.

## Acknowledgments

This wouldn't exist without the people who reverse-engineered Twinsanity's
formats first and published real, working tools and documentation:

- [**Twinsanity Editor**](https://github.com/Smartkin/twinsanity-editor)
  (Vladislav "Smartkin" Smyshlyaev, Artem "NeoKesha" Yashin, BetaM) — the
  primary reference this whole project is built on. The `.BD`/`.BH`/`.RM2`/
  `.SM2` parsing engine is a direct Swift port of their C# source.
- [**CrateModLoader**](https://github.com/DorratzOG/CrateModLoader) — the
  `.crate` mod format this app exports to, and the reference source for
  Wrath of Cortex's `.CRT`/`.WMP` file formats.
- The wider Crash Twinsanity modding community's format documentation and
  research, without which the Wrath of Cortex reverse-engineering in this
  project would have had a much higher bar to clear.

## License

MIT for everything in this repository — see [LICENSE](LICENSE), which also
preserves Twinsanity Editor's own copyright notice for the ported parsing
engine.
