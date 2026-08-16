# Twinsanity Studio

A native macOS asset editor/IDE for *Crash Twinsanity*, ported from the community
[Twinsanity Editor](../twinsanity-editor-master) (C#/.NET, Smartkin/Neo_Kesha) to
Swift + SwiftUI. It reads `.BD`/`.BH` archives and `.RM2`/`.SM2` level/scenery
files directly, decodes textures, models, skins, skeletons, and animations,
cross-links a model to its own materials/textures/skeleton (rather than
showing them as unrelated files) with a Metal-based Model Viewer, and exports
to PNG/OBJ or a complete bundled asset (mesh + textures + animation data).

## Project layout

This is a **Swift Package**, not a hand-authored `.xcodeproj` — Xcode opens and
builds SPM packages natively (editing, running, testing, and even SwiftUI
Previews all work identically to a classic project), and it's the only
structure that could actually be verified end-to-end from the command line
while building this.

```
TwinsanityStudio/
  Package.swift
  Sources/
    CTCore/         Binary I/O primitives, endianness, the generic chunk header format
    CTModels/        Plain-data models: TextureAsset, MeshAsset, SkeletonAsset, AnimationAsset, MaterialInfo,
                     ChunkNode, and ResolvedModelAsset/AssetResolver (linked asset resolution)
    CTParsers/       BD/BH, RM2/SM2 chunk tree, Texture (PS2 + Xbox), VIF interpreter, Model/Skin,
                     Material/TwinsShader, GraphicsInfo/Animation
    CTExport/        PNG export, OBJ export (with .mtl linkage), archive repackaging
    CTStudioApp/     The SwiftUI app: sidebar / inspector / 3D viewport, drag-drop, search, type filter,
                     and the Metal-based Model Viewer (Sources/CTStudioApp/ModelViewer/)
  Tests/
    CTCoreTests/     BinaryCursor/BinaryWriter/ChunkHeader
    CTParsersTests/  BD/BH, RM2 chunk tree, Texture, VIF interpreter, Material, GraphicsInfo, Animation,
                     AssetResolver, mesh winding
    CTExportTests/   OBJ export (incl. mtllib linkage), PNG export, archive repackaging
```

`CTCore` → `CTModels` → `CTParsers` → `CTExport` → `CTStudioApp` is a strict
dependency chain (each only depends on the ones before it), so the parsing
engine is fully usable as a library without the app, and every layer has its
own test target.

## Setup & running in Xcode

1. **Requirements**: Xcode 15+ on macOS 14 (Sonoma) or later. The app targets
   macOS 14 (for `NavigationSplitView`'s three-column layout and
   `ContentUnavailableView`).
2. Open the package: `File ▸ Open…` and select `TwinsanityStudio/Package.swift`
   (or just double-click `Package.swift` in Finder — it opens directly in Xcode).
3. Xcode resolves the package graph automatically (there are no external
   dependencies — everything here is first-party) and creates a scheme per
   product: **TwinsanityStudio** (the app, `CTStudioApp`'s product name) plus
   the individual library schemes (`CTCore`, `CTModels`, `CTParsers`,
   `CTExport`).
4. In the scheme selector at the top of the window, choose **TwinsanityStudio**
   with **My Mac** as the run destination.
5. **Build**: `⌘B`. **Run**: `⌘R` — this launches the app window.
6. **Test**: `⌘U` runs every test target (`CTCoreTests`, `CTParsersTests`,
   `CTExportTests`). Use the Test navigator (`⌘6`) to run an individual suite
   or test.

### Using the app

- Drag a `.BH` archive, a loose `.RM2`/`.SM2`/`.RMX`/`.SMX` file, or a folder
  (e.g. an extracted disc image) onto the window — or `⌘O` to pick one.
- The sidebar shows the chunk tree; selecting an unparsed `.RM2`/`.SM2`
  archive entry parses it automatically. Type in the search field to filter
  by name, section type, or record ID (matches keep their ancestor chunks so
  the tree stays navigable), or use the **type filter** dropdown above the
  tree to jump straight to every decoded Texture/Model/Skeleton/Animation —
  click **Scan Archive** first so it can look inside files you haven't opened
  yet (a full archive can be hundreds of files; scanning runs in the
  background and only needs to happen once per session).
- Selecting a texture, mesh, skeleton, or animation record shows a
  type-specific inspector in the center panel; meshes also render live
  (untextured) in the SceneKit viewport on the right.
- **Model Viewer**: a `RigidModel` or `GraphicsInfo` (skeleton) record's
  inspector has an **Open in Model Viewer** button. This resolves the record
  against its file's Graphics/Code sections — mesh, per-submesh materials,
  textures, and (for rigged records) the skeleton and every animation in the
  same file — and opens a dedicated Metal-rendered window showing the model
  *fully textured*, with drag-to-orbit/scroll-to-zoom, an animation
  search/scrub panel, and an **Export Complete Asset…** button that bundles
  the mesh (OBJ + MTL), every resolved texture (PNG), and decoded animation
  data (JSON) into one folder in a single click.
- Textures export to PNG (base + every mip level) and meshes export to
  Wavefront OBJ via the **Export…** button in their own inspector too, if you
  just want the raw geometry/texture rather than the bundled asset.

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
framework. Xcode itself doesn't care about this (it always uses its own
bundled toolchain when you build/test from inside the app), but for the
command line, either point that one invocation at Xcode's toolchain without
changing anything system-wide:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

or switch the system default (affects every `swift`/`xcodebuild` invocation
system-wide until changed back, needs your password):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Format notes & known limitations

This port is grounded directly in the original C# source
(`twinsanity-editor-master/Twinsanity/`), not reverse-engineered from
scratch — see the doc comments on `BDArchiveParser`, `RM2Parser`,
`TextureParser`, `VIFInterpreter`, `ModelParser`/`SkinParser`, and
`GraphicsInfoParser`/`AnimationParser` for exact line-level provenance. A few
things are deliberately out of scope rather than guessed at:

- **Endianness**: PS2 (MIPS) and Xbox (x86) Twinsanity data are *both*
  little-endian in practice — the original tool never byte-swaps structural
  fields. `BinaryCursor`/`BinaryWriter` are still genuinely endian-aware, but
  every parser here reads `.little`. The real PS2/Xbox split shows up in
  *pixel/vertex layout* (GS-swizzled paletted textures vs. DXT5, PS2 VU
  microcode vs. presumably-plain Xbox vertex buffers), not byte order.
- **Fully decoded**: `.BD`/`.BH` archives (read + rebuild), the full RM2/SM2
  chunk tree (all section types are at least browsable), PS2 `Texture`
  (PSMCT32 + PSMT8/palette/swizzle) and Xbox `TextureX` (raw + DXT5), PS2
  `Model` (rigid) and `Skin` (skinned) geometry via a from-scratch VIF/VU
  unpack interpreter, `RigidModel` links, `GraphicsInfo` skeletons, and
  `Animation` curves.
- **Browsable but not deep-decoded**: Xbox `ModelX`/`SkinX` (Xbox has no VU
  hardware, so it almost certainly isn't VIF-encoded — rather than guess at
  an unverified layout, these stay raw), `BlendSkin` morph-target blobs,
  and the `Object`/`Script`/`Instance` component system (a large, separate
  subsystem in the original tool). All of these still appear in the tree with
  correct byte ranges and can be extracted as raw bytes.
- **Animation playback** (both the inspector and the Model Viewer) scrubs
  through *decoded per-frame channel values*, not a live-deformed skinned
  mesh — turning `JointSettings.Flags`/`TransformationChoice` into a final
  joint matrix isn't fully pinned down even in the reference tool's own
  viewer code, so this stops at exposing the real decoded numbers rather than
  guessing at a possibly-wrong skinning result. The Model Viewer's optional
  "Show Skeleton Overlay" is the same kind of best-effort: it draws bind-pose
  joint positions from `Joint.matrix[3].xyz`, a plausible but unconfirmed
  reading of that 5-row matrix layout — treat its shape as approximate.
- **Animation-to-model linking**: the format has no stored link from a
  specific `Animation` record to the skeleton it animates (that association
  lives in the undecoded `Object`/`Script` game-logic layer) — the Model
  Viewer offers every animation decoded in the *same file* as a preview
  candidate, which is a reasonable heuristic but not a guaranteed-correct one.
- **Demo-format RM2/SM2 variants** aren't auto-detected (there's no on-disk
  flag to detect them by) — files are parsed as retail-format by default,
  which matches the actual Crash Twinsanity retail disc.

## Saving edits & getting them onto real hardware

Every edit path in this app writes to a **new file or folder**, never in
place — the original archive/disc image on disk is never modified. What you
get out, and how "real" each path is, differs:

- **Save Chunk Overrides… / Save Edited Copy…** (per-record inspectors, the
  Level Viewer's Instance/Trigger/Camera/AI-waypoint edits): patches only the
  bytes of the specific record(s) you changed into a full copy of the
  original file, leaving everything else byte-for-byte untouched. This is
  the highest-confidence path — every writer here has a round-trip test
  (`Tests/CTParsersTests/*WriterTests.swift`) proving `parse(write(parse(x)))
  == parse(x)`, so the *file format* is verified correct.
- **Export as Mod Crate…**: packages the same patched bytes into a real
  `.crate` file, installable through
  [CrateModLoader](https://github.com/DorratzOG/CrateModLoader) alongside
  other Twinsanity mods, rather than a loose file you'd have to manually
  place.
- **Replace in Disc Image…** (for a file mounted from a `.iso`): rebuilds a
  *complete new `.iso`* with that one file's contents replaced, via a real
  ISO-9660 directory-record patch (`ISO9660Writer`) — not just a raw byte
  splice. `.bin`/`.cue` raw-sector images aren't rebuildable yet, only a
  plain `.iso`.
- **Archive Repackager** (`.BH`/`.BD`): rebuilds a complete new archive pair
  with one or more entries replaced, streaming every untouched entry straight
  through from the original rather than requiring a full re-extract.

**What "verified" means here, honestly**: every writer's output round-trips
correctly back through this app's own parser, and several (the `.iso`
rebuild, the `.BH`/`.BD` repack) preserve the exact container structure a
real disc/archive needs. What hasn't been verified, because doing so needs
hardware this project has no access to, is whether an edited file actually
**boots and runs correctly on a real PS2** (or in an emulator like PCSX2) —
no claim here should be read as "hardware-tested." If you build something
with this tool and try it on real hardware or an emulator, that's the actual
verification step; issues found there are genuinely useful to report; this
tool's own test suite can only confirm the bytes are structured correctly,
not that the game accepts them.

For higher-fidelity validation beyond the synthetic test fixtures, the next
step would be running the parsers against real extracted files from a
`.BD`/`.BH` pair (e.g. from the ISO already in this repo) — the synthetic
fixtures in `Tests/` pin the tricky bit-level logic (VIF unpack, PS2 GS
swizzle addressing, chunk offset resolution) but are hand-built, not
game-authored, data.
