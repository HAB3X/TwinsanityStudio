import Foundation
import simd

/// An `AIPosition` record — a single AI waypoint. Ported from
/// `Twinsanity/Items/Instances/AIPosition.cs`. `nodeType` matches that
/// file's own `NodeType` enum (`Ground`/`Air`/`WormPath`/`CortexPoint`) —
/// real, named values from the reference tool, not a guess.
public struct AIPositionMarker: Sendable, Identifiable, Codable {
    public enum NodeType: UInt16, Sendable, Codable {
        case ground = 0
        case air = 2
        case wormPath = 4
        case cortexPoint = 16

        public var displayName: String {
            switch self {
            case .ground: return "Ground"
            case .air: return "Air"
            case .wormPath: return "Worm Path"
            case .cortexPoint: return "Cortex Point"
            }
        }
    }

    public let id: UInt32
    /// `W` is annotated "node weight?" in the reference tool's own source
    /// — kept verbatim, not resolved into a confirmed meaning.
    public var position: SIMD4<Float>
    /// Raw on-disk value — `nodeType` is `nil` when it doesn't match any
    /// of the reference tool's own named `NodeType` cases (real data may
    /// use values that enum doesn't cover).
    public var rawNodeType: UInt16

    public var nodeType: NodeType? { NodeType(rawValue: rawNodeType) }

    public init(id: UInt32, position: SIMD4<Float>, rawNodeType: UInt16) {
        self.id = id
        self.position = position
        self.rawNodeType = rawNodeType
    }
}

/// An `AIPath` record. Ported from `Twinsanity/Items/Instances/AIPath.cs`
/// — 5 raw arguments, no position of its own. The reference tool's own
/// `AIPathController.GenText()` never interprets these beyond printing
/// them as "Argument0"..."Argument4", so this build doesn't either: no
/// confirmed evidence connects these to `AIPosition` IDs or any other
/// linkage, so presenting a connection graph here would be fabricating
/// topology this format doesn't document.
public struct AIPathRecord: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var args: [UInt16]

    public init(id: UInt32, args: [UInt16]) {
        self.id = id
        self.args = args
    }
}
