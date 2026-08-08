import Foundation

public enum BinaryCursorError: Error, CustomStringConvertible, Equatable {
    case outOfBounds(requested: Int, position: Int, available: Int)
    case invalidSeek(target: Int, size: Int)
    case invalidString(position: Int)

    public var description: String {
        switch self {
        case .outOfBounds(let requested, let position, let available):
            return "BinaryCursor: attempted to read \(requested) byte(s) at position \(position), but only \(available) byte(s) remain."
        case .invalidSeek(let target, let size):
            return "BinaryCursor: seek target \(target) is outside the valid range 0...\(size)."
        case .invalidString(let position):
            return "BinaryCursor: could not decode ASCII string at position \(position)."
        }
    }
}

/// A forward- and random-access binary reader over an in-memory `Data` buffer.
///
/// Every read is bounds-checked and throws rather than trapping, which matters here:
/// Twinsanity's chunk offsets/sizes come directly from (sometimes hand-modded) game
/// files, so a corrupt or truncated archive must surface as a catchable error, not a
/// crash. Endianness is explicit per-cursor (see `Endianness`) — no reliance on host
/// byte order.
public struct BinaryCursor {
    public let data: Data
    public let endianness: Endianness
    public private(set) var position: Int

    public init(data: Data, endianness: Endianness = .little, startPosition: Int = 0) {
        self.data = data
        self.endianness = endianness
        self.position = startPosition
    }

    public var count: Int { data.count }
    public var remaining: Int { data.count - position }
    public var isAtEnd: Bool { position >= data.count }

    // MARK: - Positioning

    @discardableResult
    public mutating func seek(to newPosition: Int) throws -> Int {
        guard newPosition >= 0, newPosition <= data.count else {
            throw BinaryCursorError.invalidSeek(target: newPosition, size: data.count)
        }
        position = newPosition
        return position
    }

    @discardableResult
    public mutating func skip(_ byteCount: Int) throws -> Int {
        try seek(to: position + byteCount)
    }

    /// Runs `body` with the cursor temporarily seeked to `position`, restoring the
    /// original position afterwards. Mirrors the very common
    /// `var sk = reader.Position; reader.Position = x; ...; reader.Position = sk;`
    /// pattern used throughout the original C# parser.
    public mutating func withTemporarySeek<T>(to newPosition: Int, _ body: (inout BinaryCursor) throws -> T) rethrows -> T {
        let saved = position
        defer { position = saved }
        // Ignore the seek error path here deliberately would hide bugs, so this seek
        // is expected to succeed; callers pass offsets that already come from a
        // validated chunk index.
        position = min(max(newPosition, 0), data.count)
        return try body(&self)
    }

    // MARK: - Raw bytes

    private mutating func readRawBytes(_ byteCount: Int) throws -> [UInt8] {
        guard byteCount >= 0 else {
            throw BinaryCursorError.outOfBounds(requested: byteCount, position: position, available: remaining)
        }
        guard position + byteCount <= data.count else {
            throw BinaryCursorError.outOfBounds(requested: byteCount, position: position, available: remaining)
        }
        let start = data.startIndex + position
        let end = start + byteCount
        let bytes = [UInt8](data[start..<end])
        position += byteCount
        return bytes
    }

    public mutating func readBytes(_ byteCount: Int) throws -> Data {
        Data(try readRawBytes(byteCount))
    }

    public mutating func peekBytes(_ byteCount: Int) throws -> Data {
        var copy = self
        return try copy.readBytes(byteCount)
    }

    // MARK: - Integers

    private mutating func readUnsigned<T: UnsignedInteger & FixedWidthInteger>(_ type: T.Type) throws -> T {
        let byteCount = T.bitWidth / 8
        let bytes = try readRawBytes(byteCount)
        var value: T = 0
        switch endianness {
        case .little:
            for i in stride(from: byteCount - 1, through: 0, by: -1) {
                value = (value << 8) | T(bytes[i])
            }
        case .big:
            for i in 0..<byteCount {
                value = (value << 8) | T(bytes[i])
            }
        }
        return value
    }

    public mutating func readUInt8() throws -> UInt8 { try readUnsigned(UInt8.self) }
    public mutating func readUInt16() throws -> UInt16 { try readUnsigned(UInt16.self) }
    public mutating func readUInt32() throws -> UInt32 { try readUnsigned(UInt32.self) }
    public mutating func readUInt64() throws -> UInt64 { try readUnsigned(UInt64.self) }

    public mutating func readInt8() throws -> Int8 { Int8(bitPattern: try readUInt8()) }
    public mutating func readInt16() throws -> Int16 { Int16(bitPattern: try readUInt16()) }
    public mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }
    public mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readUInt64()) }

    public mutating func readBool() throws -> Bool { try readUInt8() != 0 }

    // MARK: - Floating point

    public mutating func readFloat32() throws -> Float { Float(bitPattern: try readUInt32()) }
    public mutating func readFloat64() throws -> Double { Double(bitPattern: try readUInt64()) }

    // MARK: - Strings

    public mutating func readASCIIString(length: Int) throws -> String {
        let bytes = try readRawBytes(length)
        guard let s = String(bytes: bytes, encoding: .ascii) else {
            throw BinaryCursorError.invalidString(position: position - length)
        }
        return s
    }

    /// Reads a null-terminated ASCII string, consuming the terminator, up to `maxLength`.
    public mutating func readCString(maxLength: Int) throws -> String {
        var bytes: [UInt8] = []
        for _ in 0..<maxLength {
            let b = try readUInt8()
            if b == 0 { break }
            bytes.append(b)
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    // MARK: - Vectors (used throughout: Pos/TwinsVector4/VIF Vector4 are all XYZW float32)

    public mutating func readVector4() throws -> SIMD4<Float> {
        SIMD4<Float>(try readFloat32(), try readFloat32(), try readFloat32(), try readFloat32())
    }

    public mutating func readVector3() throws -> SIMD3<Float> {
        SIMD3<Float>(try readFloat32(), try readFloat32(), try readFloat32())
    }

    /// A cursor scoped to a sub-range of this cursor's buffer, positioned at 0.
    /// Used to hand off e.g. a VIF microcode blob to a dedicated interpreter
    /// without letting it read past its own bounds.
    public func subCursor(offset: Int, length: Int) throws -> BinaryCursor {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw BinaryCursorError.outOfBounds(requested: length, position: offset, available: data.count - offset)
        }
        let start = data.startIndex + offset
        let end = start + length
        return BinaryCursor(data: data.subdata(in: start..<end), endianness: endianness)
    }
}
