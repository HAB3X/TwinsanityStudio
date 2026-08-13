import Foundation
import CTCore
import CTModels

/// Decodes an Xbox `SkinX` record (`SectionType.skinX`) — Xbox skins use a
/// different vertex format than PS2 skins (no VU microcode), so this
/// implementation treats the data as raw vertex buffers since the exact
/// format is not verified. For now, we interpret the data as position-only
/// 32-bit float vertices with basic joint data to allow basic visualization,
/// with the understanding this may not be accurate for all Xbox skins.
public enum SkinXParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> MeshAsset {
        // Xbox SkinX format is not VIF-encoded (no VU hardware), so it likely
        // uses standard vertex buffers. Without knowing the exact format,
        // we make a reasonable attempt to extract position and joint data.

        // Save starting position to calculate how much data we consume
        let startPosition = cursor.position

        // We'll attempt to extract vertices with position and basic joint data
        // This is a heuristic - real Xbox format may differ
        var vertices: [StaticVertex] = []
        var jointIndices: [SIMD4<UInt16>] = []
        var jointWeights: [SIMD4<Float>] = []

        // Process data while we have enough for a basic vertex+joint data
        // Assuming: position (3 floats) + normal (3 floats) + uv (2 floats)
        // + color (4 bytes) + joint indices (4 shorts) + joint weights (4 floats)
        // = 3*4 + 3*4 + 2*4 + 4*1 + 4*2 + 4*4 = 12+12+8+4+8+16 = 60 bytes per vertex
        while cursor.remaining >= 60 {
            do {
                // Read position (x, y, z)
                let posX = try cursor.readFloat32()
                let posY = try cursor.readFloat32()
                let posZ = try cursor.readFloat32()

                // Read normal (x, y, z) - using zero as default since we don't have this data
                let normX: Float = 0
                let normY: Float = 0
                let normZ: Float = 1

                // Read UV (u, v)
                let uvU = try cursor.readFloat32()
                let uvV = try cursor.readFloat32()

                // Read color (r, g, b, a) as bytes
                let colorR = try cursor.readUInt8()
                let colorG = try cursor.readUInt8()
                let colorB = try cursor.readUInt8()
                let colorA = try cursor.readUInt8()

                // Read joint indices (4 shorts)
                let jointIndex1 = try cursor.readUInt16()
                let jointIndex2 = try cursor.readUInt16()
                let jointIndex3 = try cursor.readUInt16()
                let jointIndex4 = try cursor.readUInt16()

                // Read joint weights (4 floats)
                let weight1 = try cursor.readFloat32()
                let weight2 = try cursor.readFloat32()
                let weight3 = try cursor.readFloat32()
                let weight4 = try cursor.readFloat32()

                // Create vertex
                let vertex = StaticVertex(
                    position: SIMD3(posX, posY, posZ),
                    normal: SIMD3(normX, normY, normZ),
                    uv: SIMD2(uvU, uvV),
                    color: SIMD4(colorR, colorG, colorB, colorA)
                )

                vertices.append(vertex)
                jointIndices.append(SIMD4(jointIndex1, jointIndex2, jointIndex3, jointIndex4))
                jointWeights.append(SIMD4(weight1, weight2, weight3, weight4))
            } catch {
                // If we can't read a complete vertex, stop processing
                break
            }
        }

        // If we found vertex data, create a mesh with skinning data
        if !vertices.isEmpty {
            // Create submeshes - for simplicity, put all vertices in one submesh
            var submeshes: [MeshSubmesh] = []

            // Ensure joint data arrays match vertex count
            while jointIndices.count < vertices.count {
                jointIndices.append(SIMD4(0, 0, 0, 0))
                jointWeights.append(SIMD4(0, 0, 0, 0))
            }
            jointIndices.removeLast(jointIndices.count - vertices.count)
            jointWeights.removeLast(jointWeights.count - vertices.count)

            let submesh = MeshSubmesh(
                vertices: vertices,
                connectivity: Array(repeating: false, count: vertices.count),
                jointIndices: jointIndices,
                jointWeights: jointWeights
            )

            submeshes.append(submesh)

            return MeshAsset(id: recordID, isSkinned: true, submeshes: submeshes)
        }

        // If we couldn't extract any valid vertex data, fall back to raw data approach
        // Reset cursor to start position and consume all remaining data
        try cursor.seek(to: startPosition)
        let _ = try? cursor.skip(cursor.remaining) // Consume remaining data

        return MeshAsset(id: recordID, isSkinned: true, submeshes: [])
    }
}

/// Parsing errors specific to SkinXParser
public enum SkinXParserError: LocalizedError {
    case insufficientData

    public var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "SkinX data is too small to contain valid geometry"
        }
    }
}