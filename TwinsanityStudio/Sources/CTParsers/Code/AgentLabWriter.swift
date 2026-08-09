import Foundation
import CTCore

/// Encodes an AgentLab command's raw `uint32` arguments back to their
/// on-disk form — the inverse of `CustomAgentParser.readCommandChain`'s own
/// per-command argument read loop.
///
/// Argument *count* never changes here — that's fixed by
/// `AgentLabCommandCatalog.commandSize(forID:platform:)`, a property of the
/// command ID itself, not something this write path edits — so this is
/// always a same-size patch: `arguments.count * 4` bytes in, the same out,
/// meant to be written at `AgentLabCommand.fileOffset + 4` (the 4 bytes
/// right after that offset are `internalIndex` itself, which this write
/// path leaves untouched — editing a command's ID or its chain-continuation
/// bit would need real structural surgery this doesn't attempt, same
/// "patch only what's fixed-size and fixed-offset" discipline as every
/// other write path in this app).
public enum AgentLabWriter {
    public static func writeArguments(_ arguments: [UInt32]) -> Data {
        var writer = BinaryWriter()
        for value in arguments {
            writer.writeUInt32(value)
        }
        return writer.data
    }
}
