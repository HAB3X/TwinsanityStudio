import Foundation
import CTCore
import CTModels

/// Write-back for `Script` records — same "capture a fixed-offset field
/// once, patch a same-size range there" discipline as `WorldPlacementWriter`
/// and `AgentLabWriter`. Doesn't attempt a full re-encode of the whole
/// variable-length `Script` record (states/bodies/commands can already be
/// added/removed on the reference side in ways this build hasn't verified
/// a byte-exact `Save()` for) — only the specific fields real, verified
/// gameplay mods actually patch: a `ScriptState`'s `scriptIndexOrSlot`
/// (the "redirect this state to a different script/slot" operation
/// CrateModLoader's own cutscene-skip mods perform) and, via the existing
/// `AgentLabWriter`/`AgentLabCommand.fileOffset`, any command's raw
/// arguments — `ScriptStateBody.commands` is the exact same
/// `[AgentLabCommand]` type `CustomAgent` already has real write-back for,
/// so no new writer is needed there at all.
public enum ScriptWriter {
    /// Encodes a `ScriptState.scriptIndexOrSlot` back to its on-disk 2-byte
    /// form, meant to be patched at `ScriptState.scriptIndexOrSlotFileOffset`.
    public static func writeScriptIndexOrSlot(_ value: Int16) -> Data {
        var writer = BinaryWriter()
        writer.writeInt16(value)
        return writer.data
    }

    /// Encodes one `HeaderScript.Entry` back to its on-disk 8-byte form
    /// (`Int32` `mainScriptIndex` then `UInt32` `unkInt2`), meant to be
    /// patched at `HeaderScript.entriesFileOffset + index * 8`.
    public static func writeHeaderScriptEntry(mainScriptIndex: Int32, unkInt2: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.writeInt32(mainScriptIndex)
        writer.writeUInt32(unkInt2)
        return writer.data
    }

    /// Encodes `SupportType1.unkInt1Raw` back to its on-disk 4-byte form,
    /// meant to be patched at `SupportType1.unkInt1RawFileOffset` — makes
    /// every `resolved*`/flag accessor on that type (space, motion,
    /// continuous-rotate, translates/rotates/tracksDestination/etc.)
    /// writable without touching the variable-length `bytes`/`floats`
    /// lists that follow it in the same record.
    public static func writeSupportType1UnkInt1Raw(_ value: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(value)
        return writer.data
    }

    /// Encodes a full `ScriptCondition` back to its on-disk 16-byte form
    /// (`unkInt1Raw`, `interval`, `threshold`, `thresholdInverse`, 4 bytes
    /// each, in that exact sequential order), meant to be patched at
    /// `ScriptCondition.fileOffset` — one patch covers all four fields
    /// (including `vTableIndex`/`parameter`/`notGate`, which are just
    /// `unkInt1Raw`'s own packed bits) since they're already contiguous
    /// and always rewritten together.
    public static func writeCondition(_ condition: ScriptCondition) -> Data {
        var writer = BinaryWriter()
        writer.writeInt32(condition.unkInt1Raw)
        writer.writeFloat32(condition.interval)
        writer.writeFloat32(condition.threshold)
        writer.writeFloat32(condition.thresholdInverse)
        return writer.data
    }
}
