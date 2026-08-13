import Foundation
import CTCore
import CTModels

/// Decodes an Xbox `ModelX` record (`SectionType.modelX`) — Xbox models use a
/// different vertex format than PS2 models (no VU microcode), so this
/// implementation treats the data as raw vertex buffers since the exact
/// format is not verified. For now, we interpret the data as position-only
/// 32-bit float vertices to allow basic visualization, with the understanding
/// this may not be accurate for all Xbox models.
public enum ModelXParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> MeshAsset {
        // Xbox ModelX format is not VIF-encoded (no VU hardware), so it likely
        // uses standard vertex buffers. Without knowing the exact format,
        // we make a reasonable attempt to extract position data.

        // Save starting position to calculate how much data we consume
        let startPosition = cursor.position

        // We'll attempt to extract 32-bit float positions (X,Y,Z)
        // This is a heuristic - real Xbox format may differ
        var positions: [SIMD3<Float>] = []

        // Process data in chunks of 12 bytes (3 floats) while we have enough data
        while cursor.remaining >= 12 {
            do {
                let x = try cursor.readFloat32()
                let y = try cursor.readFloat32()
                let z = try cursor.readFloat32()
                positions.append(SIMD3(x, y, z))
            } catch {
                // If we can't read a float, stop processing
                break
            }
        }

        // If we found at least some position data, create a mesh
        if !positions.isEmpty {
            var vertices: [StaticVertex] = []
            vertices.reserveCapacity(positions.count)

            for position in positions {
                // Create a basic vertex with position only (default normal, UV, color)
                let vertex = StaticVertex(
                    position: position,
                    normal: SIMD3(0, 0, 1), // Default forward normal
                    uv: SIMD2(0, 0),
                    color: SIMD4(255, 255, 255, 255), // Default white
                    emissive: SIMD4(0, 0, 0, 0) // Default no emissive
                )
                vertices.append(vertex)
            }

            // Create a single submesh with all vertices
            let submesh = MeshSubmesh(
                vertices: vertices,
                connectivity: Array(repeating: false, count: vertices.count)
            )

            return MeshAsset(id: recordID, isSkinned: false, submeshes: [submesh])
        }

        // If we couldn't extract any valid position data, fall back to raw data approach
        // but still return a minimal valid mesh to satisfy the .mesh payload expectation
        // Reset cursor to start position and consume all remaining data
        try cursor.seek(to: startPosition)
        let _ = try? cursor.skip(cursor.remaining) // Consume remaining data

        return MeshAsset(id: recordID, isSkinned: false, submeshes: [])
    }
}

/// Parsing errors specific to ModelXParser
public enum ModelXParserError: LocalizedError {
    case insufficientData

    public var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "ModelX data is too small to contain valid geometry"
        }
    }
}