import Foundation
import CTCore
import CTModels

/// "Backend Requirement: safely inject this new record into the .RM2 file
/// structure without corrupting the chunk" (Part 4D) — the one piece of
/// real structural surgery nothing else in this build attempts.
/// `WorkspaceViewModel.patchedFileBytes(replacing:with:)` and its siblings
/// only ever overwrite an existing, already-sized region in place (safe
/// specifically *because* nothing else in the file has to move); adding a
/// brand-new record instead grows one section, which grows every section
/// enclosing it, all the way up to the file itself.
///
/// The layout this mirrors is ported exactly from `TwinsSection.cs`'s own
/// `Save`/`GetSize` (verified by reading that source, not guessed from the
/// reader alone):
/// ```
/// uint32 Magic
/// int32  RecordCount
/// uint32 ContentSize          // sum of every record's own byte size —
///                              // NOT the section's total byte size
/// ChunkIndexEntry[RecordCount] // { offset, size, id }, 12 bytes each —
///                              // offset is relative to this section's own
///                              // Magic, starting right after the index
///                              // table (RecordCount * 12 + 12) and
///                              // incrementing by each record's own Size —
///                              // tightly packed, no padding between records
/// <record bytes, tightly packed, in the same order as the index table>
/// ```
/// Rather than trying to shift bytes/offsets in place (error-prone once a
/// section's own size — and therefore *every* enclosing section's size —
/// changes), this reconstructs each level fresh: the target section gets
/// the new record appended and every index offset recomputed from
/// scratch; each ancestor above it gets its one changed child's bytes
/// swapped in and its own index table likewise recomputed from scratch,
/// with every *other* child copied byte-for-byte, verbatim, from the
/// original file at that child's own already-known `(fileOffset,
/// byteSize)`. A sibling this build doesn't touch is never re-encoded,
/// only ever copied — so nothing about it can be silently reinterpreted
/// wrong.
public enum ChunkSectionInserter {
    /// Produces a full replacement for `originalFileBytes` with one new
    /// record `(id, encoded)` appended to `targetSection`. `nil` if
    /// `targetSection` isn't actually reachable from `fileRoot`, if any
    /// section along the way doesn't parse as a valid chunk header, or if
    /// `targetSection` carries trailing bytes beyond what its own index
    /// table accounts for (`.se`-family sound banks' `ExtraData` — this
    /// function doesn't know how to preserve that safely, so it refuses
    /// rather than silently drop it; this build only ever calls it for
    /// `.objectInstance` collections, which don't have any).
    public static func insertingRecord(id: UInt32, encoded: Data, into targetSection: ChunkNode, fileRoot: ChunkNode, originalFileBytes: Data) -> Data? {
        insertingRecords([(id, encoded)], into: targetSection, fileRoot: fileRoot, originalFileBytes: originalFileBytes)
    }

    /// Same as `insertingRecord(id:encoded:into:fileRoot:originalFileBytes:)`,
    /// but appends every record in `records` to `targetSection` in one
    /// pass — the "Save Level Overrides" flow can place several new
    /// objects in one session before saving, and inserting them one at a
    /// time would mean re-parsing the whole file's freshly-patched bytes
    /// between each insert just to get an up-to-date `ChunkNode` tree to
    /// target the next one with. Batching sidesteps that entirely: every
    /// record lands in the same rebuild of `targetSection`, so this only
    /// ever walks up to the file root once.
    public static func insertingRecords(_ records: [(id: UInt32, encoded: Data)], into targetSection: ChunkNode, fileRoot: ChunkNode, originalFileBytes: Data) -> Data? {
        guard !records.isEmpty else { return originalFileBytes }
        guard let path = nodePath(from: fileRoot, to: targetSection) else { return nil }
        guard var rebuiltBytes = appendingRecords(records, to: targetSection, originalFileBytes: originalFileBytes) else { return nil }
        var rebuiltNode = targetSection

        for ancestor in path.dropLast().reversed() {
            guard let rebuiltAncestorBytes = replacingChild(rebuiltNode, in: ancestor, with: rebuiltBytes, originalFileBytes: originalFileBytes) else { return nil }
            rebuiltBytes = rebuiltAncestorBytes
            rebuiltNode = ancestor
        }
        return rebuiltBytes
    }

    /// Generalizes `insertingRecords(_:into:fileRoot:originalFileBytes:)` to
    /// several *different* target sections in one pass — "AI Pathfinding &
    /// Navmesh Editor" (roadmap 5.1) needed this alongside "Backend
    /// Requirement: safely inject this new record" (Part 4D) once a single
    /// save could add both a new `Instance` and a new `AIPosition` in one
    /// go, and those two collections are siblings under the same
    /// `.instance` container: calling the single-target version twice in a
    /// row — each rebuilding its own ancestor chain from the *original*
    /// tree's offsets against a byte buffer the *other* call had already
    /// grown — desyncs the moment either insertion changes any shared
    /// ancestor's size. This does one single top-down rebuild instead:
    /// every directly-targeted section gets its own new bytes; every
    /// ancestor of any targeted section is rebuilt from its *real*
    /// children, substituting only whichever of those children actually
    /// changed; everything else is copied verbatim from the original
    /// file — so no node's offset is ever read against bytes it wasn't
    /// computed from.
    public static func insertingRecords(
        intoSections targets: [(section: ChunkNode, records: [(id: UInt32, encoded: Data)])],
        fileRoot: ChunkNode,
        originalFileBytes: Data
    ) -> Data? {
        let nonEmptyTargets = targets.filter { !$0.records.isEmpty }
        guard !nonEmptyTargets.isEmpty else { return originalFileBytes }

        var rebuiltBytesByNodeID: [ObjectIdentifier: Data] = [:]
        for target in nonEmptyTargets {
            guard rebuiltBytesByNodeID[ObjectIdentifier(target.section)] == nil else { continue }
            guard let bytes = appendingRecords(target.records, to: target.section, originalFileBytes: originalFileBytes) else { return nil }
            rebuiltBytesByNodeID[ObjectIdentifier(target.section)] = bytes
        }

        func rebuild(_ node: ChunkNode) -> Data? {
            if let direct = rebuiltBytesByNodeID[ObjectIdentifier(node)] { return direct }
            guard !node.children.isEmpty else { return nil }
            var childResults: [Data?] = []
            var anyChanged = false
            for child in node.children {
                let result = rebuild(child)
                if result != nil { anyChanged = true }
                childResults.append(result)
            }
            guard anyChanged else { return nil }
            return replacingChildren(node, newChildBytes: childResults, originalFileBytes: originalFileBytes)
        }

        return rebuild(fileRoot)
    }

    /// The node-identity path from `root` down to `target`, root first,
    /// `target` last — `ChunkNode` is a reference type, so `===` identity
    /// is exact, no risk of matching an equal-looking sibling instead.
    private static func nodePath(from root: ChunkNode, to target: ChunkNode) -> [ChunkNode]? {
        if root === target { return [root] }
        for child in root.children {
            if let subPath = nodePath(from: child, to: target) {
                return [root] + subPath
            }
        }
        return nil
    }

    private static func sliceBytes(_ data: Data, offset: Int, size: Int) -> Data? {
        guard offset >= 0, size >= 0, offset + size <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + size))
    }

    /// Rebuilds `sectionNode`'s own on-disk span with every record in
    /// `records` appended after all of its existing ones, in the order
    /// given.
    private static func appendingRecords(_ records: [(id: UInt32, encoded: Data)], to sectionNode: ChunkNode, originalFileBytes: Data) -> Data? {
        guard sectionNode.byteSize >= 12,
              let sectionBytes = sliceBytes(originalFileBytes, offset: sectionNode.fileOffset, size: sectionNode.byteSize)
        else { return nil }
        var cursor = BinaryCursor(data: sectionBytes)
        guard let header = try? ChunkHeaderReader.readHeader(from: &cursor) else { return nil }

        let oldHeaderIndexLength = 12 + header.entries.count * 12
        guard let oldDataArea = sliceBytes(sectionBytes, offset: oldHeaderIndexLength, size: sectionBytes.count - oldHeaderIndexLength) else { return nil }
        // Every entry's own size must exactly tile the data area with
        // nothing left over — see this type's own doc comment on why a
        // mismatch (trailing `ExtraData`) means "refuse," not "guess."
        let declaredDataLength = header.entries.reduce(0) { $0 + Int($1.size) }
        guard declaredDataLength == oldDataArea.count else { return nil }

        let newRecordCount = header.entries.count + records.count
        let newHeaderIndexLength = 12 + newRecordCount * 12
        let indexGrowth = UInt32(newHeaderIndexLength - oldHeaderIndexLength)
        let newRecordsTotalSize = records.reduce(0) { $0 + $1.encoded.count }

        var writer = BinaryWriter()
        writer.writeUInt32(header.magic)
        writer.writeInt32(Int32(newRecordCount))
        writer.writeUInt32(UInt32(declaredDataLength + newRecordsTotalSize))

        for entry in header.entries {
            writer.writeUInt32(entry.offset + indexGrowth)
            writer.writeInt32(entry.size)
            writer.writeUInt32(entry.id)
        }
        var runningOffset = newHeaderIndexLength + oldDataArea.count
        for record in records {
            writer.writeUInt32(UInt32(runningOffset))
            writer.writeInt32(Int32(record.encoded.count))
            writer.writeUInt32(record.id)
            runningOffset += record.encoded.count
        }

        writer.writeBytes(oldDataArea)
        for record in records {
            writer.writeBytes(record.encoded)
        }
        return writer.data
    }

    /// Rebuilds `ancestor`'s own on-disk span with whichever child matches
    /// `childNode`'s identity replaced by `newChildBytes`; every other
    /// child is copied verbatim from `originalFileBytes` at its own
    /// already-known `(fileOffset, byteSize)`. Thin wrapper over
    /// `replacingChildren` — the general form `insertingRecords(
    /// intoSections:fileRoot:originalFileBytes:)` needs, since more than
    /// one of `ancestor`'s children can change at once when two different
    /// target sections share this same parent.
    private static func replacingChild(_ childNode: ChunkNode, in ancestor: ChunkNode, with newChildBytes: Data, originalFileBytes: Data) -> Data? {
        let overrides = ancestor.children.map { $0 === childNode ? newChildBytes : nil }
        return replacingChildren(ancestor, newChildBytes: overrides, originalFileBytes: originalFileBytes)
    }

    /// Rebuilds `node`'s own on-disk span with `newChildBytes[i]` (when
    /// non-nil) substituted for the on-disk bytes of `node.children[i]`;
    /// every `nil` entry is copied verbatim from `originalFileBytes` at
    /// that child's own already-known `(fileOffset, byteSize)`. The whole
    /// span is re-tiled tightly-packed from scratch either way — matching
    /// the reference writer's own layout exactly (see this type's
    /// top-level doc comment), not merely "shifted" from the old one.
    private static func replacingChildren(_ node: ChunkNode, newChildBytes: [Data?], originalFileBytes: Data) -> Data? {
        guard node.byteSize >= 12,
              let nodeBytes = sliceBytes(originalFileBytes, offset: node.fileOffset, size: node.byteSize)
        else { return nil }
        var cursor = BinaryCursor(data: nodeBytes)
        guard let header = try? ChunkHeaderReader.readHeader(from: &cursor) else { return nil }
        // The decoded tree's children and this section's own index table
        // must correspond 1:1, in order — true by construction for every
        // section kind this build actually calls this on (see the doc
        // comment above), checked rather than assumed so a parser edge
        // case fails this save instead of silently misattributing bytes.
        guard header.entries.count == node.children.count, header.entries.count == newChildBytes.count else { return nil }

        var childSlices: [Data] = []
        var childIDs: [UInt32] = []
        for (index, entry) in header.entries.enumerated() {
            if let override = newChildBytes[index] {
                childSlices.append(override)
            } else {
                guard let slice = sliceBytes(nodeBytes, offset: Int(entry.offset), size: Int(entry.size)) else { return nil }
                childSlices.append(slice)
            }
            childIDs.append(entry.id)
        }

        var writer = BinaryWriter()
        writer.writeUInt32(header.magic)
        writer.writeInt32(Int32(childSlices.count))
        writer.writeUInt32(UInt32(childSlices.reduce(0) { $0 + $1.count }))

        let headerIndexLength = 12 + childSlices.count * 12
        var runningOffset = headerIndexLength
        for (slice, id) in zip(childSlices, childIDs) {
            writer.writeUInt32(UInt32(runningOffset))
            writer.writeInt32(Int32(slice.count))
            writer.writeUInt32(id)
            runningOffset += slice.count
        }
        for slice in childSlices {
            writer.writeBytes(slice)
        }
        return writer.data
    }
}
