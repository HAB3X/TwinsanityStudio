# Twinsanity Studio

A native macOS asset editor/IDE for *Crash Twinsanity*, ported from the community
[Twinsanity Editor](../twinsanity-editor-master) (C#/.NET, Smartkin/Neo_Kesha) to
Swift + SwiftUI. It reads `.BD`/`.BH` archives and `.RM2`/`.SM2` level/scenery
files directly, decodes textures, models, skins, skeletons, and animations, and
exports to PNG/OBJ.

This package is wired into the sibling **`Crash Twinsanity.xcodeproj`** (your
SceneKit game project) as a local Swift Package dependency, so opening that
`.xcodeproj` gives you both the game and the editor as separate schemes in one
Xcode window — see "Setup & running in Xcode" below. It's also a fully
standalone package on its own (`swift build`/`swift test` work from this
directory with no other project involved), which is what made it possible to
verify everything end-to-end from the command line while building it.

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
    CTModels/        Plain-data models: TextureAsset, MeshAsset, SkeletonAsset, AnimationAsset, ChunkNode
    CTParsers/       BD/BH, RM2/SM2 chunk tree, Texture (PS2 + Xbox), VIF interpreter, Model/Skin, GraphicsInfo/Animation
    CTExport/        PNG export, OBJ export, archive repackaging
    CTStudioApp/     The SwiftUI app itself (sidebar / inspector / 3D viewport, drag-drop, search)
  Tests/
    CTCoreTests/     BinaryCursor/BinaryWriter/ChunkHeader
    CTParsersTests/  BD/BH, RM2 chunk tree, Texture, VIF interpreter, GraphicsInfo, Animation, mesh winding
    CTExportTests/   OBJ export, PNG export, archive repackaging
```

`CTCore` → `CTModels` → `CTParsers` → `CTExport` → `CTStudioApp` is a strict
dependency chain (each only depends on the ones before it), so the parsing
engine is fully usable as a library without the app, and every layer has its
own test target.

## Setup & running in Xcode

1. **Requirements**: Xcode 15+ on macOS 14 (Sonoma) or later. The app targets
   macOS 14 (for `NavigationSplitView`'s three-column layout and
   `ContentUnavailableView`).
2. Open **`Crash Twinsanity.xcodeproj`** (the repo root, one level up from this
   package) — not `Package.swift` directly. Xcode resolves the local package
   graph automatically on open (there are no external dependencies —
   everything here is first-party) and adds a scheme per product.
3. In the scheme selector at the top of the window you'll now see both
   **Crash Twinsanity** (the game) and **TwinsanityStudio** (this editor, the
   `CTStudioApp` executable product's scheme name) alongside the individual
   library schemes (`CTCore`, `CTModels`, `CTParsers`, `CTExport`). Pick
   **TwinsanityStudio** with **My Mac** as the run destination.
4. **Build**: `⌘B`. **Run**: `⌘R` — this launches the editor's app window,
   independent of the game.
5. **Test**: `⌘U` while the TwinsanityStudio scheme is selected runs every
   test target (`CTCoreTests`, `CTParsersTests`, `CTExportTests`). Use the
   Test navigator (`⌘6`) to run an individual suite or test.

(You can still open `TwinsanityStudio/Package.swift` directly for a
standalone window scoped to just this package — useful if you don't want the
game project loaded at all — but opening the `.xcodeproj` is the normal path
since it gives you both in one window.)

### Using the app

- Drag a `.BH` archive, a loose `.RM2`/`.SM2`/`.RMX`/`.SMX` file, or a folder
  (e.g. an extracted disc image) onto the window — or `⌘O` to pick one.
- The sidebar shows the chunk tree; type in the search field to filter by
  name, section type, or record ID (matches keep their ancestor chunks so the
  tree stays navigable).
- Archive entries that look like chunk files (by extension) show a **Parse**
  button to drill into their contents without a separate manual extract step.
- Selecting a texture, mesh, skeleton, or animation record shows a
  type-specific inspector in the center panel; meshes also render live in the
  3D viewport on the right (orbit/zoom/pan via trackpad or mouse).
- Textures export to PNG (base + every mip level) and meshes export to
  Wavefront OBJ via the **Export…** button in their inspector.

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
- **Animation playback** in the inspector scrubs through *decoded per-frame
  channel values*, not a live-deformed skinned mesh — turning
  `JointSettings.Flags`/`TransformationChoice` into a final joint matrix isn't
  fully pinned down even in the reference tool's own viewer code, so this
  stops at exposing the real decoded numbers rather than guessing at a
  possibly-wrong skinning result.
- **Demo-format RM2/SM2 variants** aren't auto-detected (there's no on-disk
  flag to detect them by) — files are parsed as retail-format by default,
  which matches the actual Crash Twinsanity retail disc.

For higher-fidelity validation beyond the synthetic test fixtures, the next
step would be running the parsers against real extracted files from a
`.BD`/`.BH` pair (e.g. from the ISO already in this repo) — the synthetic
fixtures in `Tests/` pin the tricky bit-level logic (VIF unpack, PS2 GS
swizzle addressing, chunk offset resolution) but are hand-built, not
game-authored, data.
