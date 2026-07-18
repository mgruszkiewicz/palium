import Foundation

// MARK: - FlexValue

nonisolated enum FlexValue: Sendable {
    case null
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case blob(Data)
    case bool(Bool)
    case vector([FlexValue])
    case map([String: FlexValue])

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var uintValue: UInt64? {
        switch self {
        case .uint(let u): return u
        case .int(let i) where i >= 0: return UInt64(i)
        default: return nil
        }
    }

    var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .uint(let u) where u <= UInt64(Int64.max): return Int64(u)
        default: return nil
        }
    }

    var floatValue: Double? {
        if case .float(let f) = self { return f }
        return nil
    }

    var blobValue: Data? {
        if case .blob(let d) = self { return d }
        return nil
    }

    var vectorValue: [FlexValue]? {
        if case .vector(let v) = self { return v }
        return nil
    }

    var mapValue: [String: FlexValue]? {
        if case .map(let m) = self { return m }
        return nil
    }

    subscript(_ key: String) -> FlexValue? {
        mapValue?[key]
    }

    subscript(_ index: Int) -> FlexValue? {
        guard let v = vectorValue, index >= 0, index < v.count else { return nil }
        return v[index]
    }
}

// MARK: - Parser

nonisolated enum FlexBuffersParser {

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Decode an entire buffer into an eager FlexValue tree.
    /// For large documents prefer `root(_:)` and walking the lazy FlexRef,
    /// which only decodes the values actually visited.
    static func decode(_ data: Data) throws -> FlexValue {
        try root(data).materialized()
    }

    /// Entry point for lazy traversal: returns a reference to the root value.
    static func root(_ data: Data) throws -> FlexRef {
        guard data.count >= 3 else {
            throw ParseError(message: "Buffer too small for FlexBuffers")
        }
        let bytes = [UInt8](data)
        let rootByteWidth = Int(bytes[bytes.count - 1])
        let rootPackedType = bytes[bytes.count - 2]
        let rootOffset = bytes.count - 2 - rootByteWidth
        guard rootByteWidth >= 1, rootOffset >= 0 else {
            throw ParseError(message: "Invalid FlexBuffers root byte width")
        }
        return FlexRef(bytes: bytes, offset: rootOffset, slotWidth: rootByteWidth, packedType: rootPackedType)
    }
}

// MARK: - FlexRef

/// A lazy, bounds-checked reference into a FlexBuffers document.
/// Accessors return nil instead of crashing on malformed or truncated input,
/// and children are decoded on demand rather than materializing the full tree.
nonisolated struct FlexRef: Sendable {

    // FlexBuffers type ids
    private static let tNull: UInt8 = 0
    private static let tInt: UInt8 = 1
    private static let tUInt: UInt8 = 2
    private static let tFloat: UInt8 = 3
    private static let tKey: UInt8 = 4
    private static let tString: UInt8 = 5
    private static let tIndirectInt: UInt8 = 6
    private static let tIndirectUInt: UInt8 = 7
    private static let tIndirectFloat: UInt8 = 8
    private static let tMap: UInt8 = 9
    private static let tVector: UInt8 = 10
    private static let tVectorInt: UInt8 = 11
    private static let tVectorUInt: UInt8 = 12
    private static let tVectorFloat: UInt8 = 13
    private static let tVectorKey: UInt8 = 14
    private static let tVectorString: UInt8 = 15
    private static let tVectorInt2: UInt8 = 16
    private static let tVectorFloat4: UInt8 = 24
    private static let tBlob: UInt8 = 25
    private static let tBool: UInt8 = 26

    fileprivate let bytes: [UInt8]
    /// Position of this value's slot within `bytes`.
    fileprivate let offset: Int
    /// Byte width of the slot (the enclosing container's element width).
    fileprivate let slotWidth: Int
    fileprivate let packedType: UInt8

    private var typeId: UInt8 { packedType >> 2 }
    private var childWidth: Int { 1 << Int(packedType & 0x03) }

    // MARK: Bounds-checked primitive reads

    private func readUInt(at offset: Int, width: Int) -> UInt64? {
        guard offset >= 0, width >= 1, offset <= bytes.count - width else { return nil }
        return bytes.withUnsafeBytes { ptr in
            switch width {
            case 1: return UInt64(ptr.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
            case 2: return UInt64(UInt16(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            case 4: return UInt64(UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            case 8: return UInt64(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            default: return nil
            }
        }
    }

    private func readInt(at offset: Int, width: Int) -> Int64? {
        guard let raw = readUInt(at: offset, width: width) else { return nil }
        switch width {
        case 1: return Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
        case 2: return Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case 4: return Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case 8: return Int64(bitPattern: raw)
        default: return nil
        }
    }

    private func readFloat(at offset: Int, width: Int) -> Double? {
        guard let raw = readUInt(at: offset, width: width) else { return nil }
        switch width {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case 8: return Double(bitPattern: raw)
        default: return nil
        }
    }

    private func readCString(at offset: Int) -> String? {
        guard offset >= 0, offset < bytes.count else { return nil }
        var end = offset
        while end < bytes.count && bytes[end] != 0 {
            end += 1
        }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    /// Resolve the slot's relative offset to the position it points at.
    private var indirectTarget: Int? {
        guard let rel = readUInt(at: offset, width: slotWidth), rel <= UInt64(offset) else { return nil }
        return offset - Int(rel)
    }

    // MARK: Scalar accessors

    var boolValue: Bool? {
        guard typeId == Self.tBool else { return nil }
        return readUInt(at: offset, width: slotWidth).map { $0 != 0 }
    }

    var intValue: Int64? {
        switch typeId {
        case Self.tInt: return readInt(at: offset, width: slotWidth)
        case Self.tIndirectInt: return indirectTarget.flatMap { readInt(at: $0, width: childWidth) }
        case Self.tUInt, Self.tIndirectUInt:
            return uintValue.flatMap { $0 <= UInt64(Int64.max) ? Int64($0) : nil }
        default: return nil
        }
    }

    var uintValue: UInt64? {
        switch typeId {
        case Self.tUInt: return readUInt(at: offset, width: slotWidth)
        case Self.tIndirectUInt: return indirectTarget.flatMap { readUInt(at: $0, width: childWidth) }
        case Self.tInt, Self.tIndirectInt:
            return intValue.flatMap { $0 >= 0 ? UInt64($0) : nil }
        default: return nil
        }
    }

    var floatValue: Double? {
        switch typeId {
        case Self.tFloat: return readFloat(at: offset, width: slotWidth)
        case Self.tIndirectFloat: return indirectTarget.flatMap { readFloat(at: $0, width: childWidth) }
        default: return nil
        }
    }

    var stringValue: String? {
        guard typeId == Self.tString || typeId == Self.tKey else { return nil }
        return indirectTarget.flatMap { readCString(at: $0) }
    }

    /// Blob contents, copied out so the result does not pin the whole document.
    var blobValue: Data? {
        guard typeId == Self.tBlob,
              let target = indirectTarget,
              let size64 = readUInt(at: target - childWidth, width: childWidth),
              let size = Int(exactly: size64),
              size >= 0, target <= bytes.count - size else { return nil }
        return Data(bytes[target..<(target + size)])
    }

    // MARK: Composite accessors

    var isNull: Bool { typeId == Self.tNull }
    var isMap: Bool { typeId == Self.tMap }

    var isVector: Bool {
        typeId == Self.tVector || isTypedVector || isFixedTypedVector
    }

    private var isTypedVector: Bool {
        typeId >= Self.tVectorInt && typeId <= Self.tVectorString
    }

    private var isFixedTypedVector: Bool {
        typeId >= Self.tVectorInt2 && typeId <= Self.tVectorFloat4
    }

    /// Element count for vectors, key/value pair count for maps.
    var count: Int {
        if typeId == Self.tMap || typeId == Self.tVector || isTypedVector {
            guard let base = indirectTarget,
                  let n = readUInt(at: base - childWidth, width: childWidth),
                  let c = Int(exactly: n),
                  c >= 0, c <= (bytes.count - base) / childWidth else { return 0 }
            return c
        }
        if isFixedTypedVector {
            // Fixed vectors encode the length in the type: INT2/UINT2/FLOAT2, INT3/..., INT4/...
            return 2 + Int(typeId - Self.tVectorInt2) / 3
        }
        return 0
    }

    private var typedElementType: UInt8 {
        switch typeId {
        case Self.tVectorUInt: return Self.tUInt
        case Self.tVectorFloat: return Self.tFloat
        case Self.tVectorKey: return Self.tKey
        case Self.tVectorString: return Self.tString
        case Self.tVectorInt: return Self.tInt
        default:
            // Fixed typed vectors cycle INT, UINT, FLOAT
            switch Int(typeId - Self.tVectorInt2) % 3 {
            case 0: return Self.tInt
            case 1: return Self.tUInt
            default: return Self.tFloat
            }
        }
    }

    subscript(index: Int) -> FlexRef? {
        let n = count
        guard index >= 0, index < n, let base = indirectTarget else { return nil }
        let elemOffset = base + index * childWidth

        if typeId == Self.tVector || typeId == Self.tMap {
            let typePos = base + n * childWidth + index
            guard typePos < bytes.count else { return nil }
            return FlexRef(bytes: bytes, offset: elemOffset, slotWidth: childWidth, packedType: bytes[typePos])
        }
        if isTypedVector || isFixedTypedVector {
            let widthBits = UInt8(childWidth.trailingZeroBitCount)
            return FlexRef(bytes: bytes, offset: elemOffset, slotWidth: childWidth,
                           packedType: (typedElementType << 2) | widthBits)
        }
        return nil
    }

    func key(at index: Int) -> String? {
        guard typeId == Self.tMap, index >= 0, index < count, let base = indirectTarget else { return nil }
        let w = childWidth
        // The keys vector descriptor (offset + byte width) sits before the size field.
        let keysOffsetPos = base - w * 3
        guard let rel = readUInt(at: keysOffsetPos, width: w),
              rel <= UInt64(keysOffsetPos),
              let keysWidth64 = readUInt(at: keysOffsetPos + w, width: w),
              let keysWidth = Int(exactly: keysWidth64),
              keysWidth >= 1 else { return nil }
        let keySlot = (keysOffsetPos - Int(rel)) + index * keysWidth
        guard let keyRel = readUInt(at: keySlot, width: keysWidth), keyRel <= UInt64(keySlot) else { return nil }
        return readCString(at: keySlot - Int(keyRel))
    }

    subscript(key: String) -> FlexRef? {
        guard typeId == Self.tMap else { return nil }
        for i in 0..<count where self.key(at: i) == key {
            return self[i]
        }
        return nil
    }

    // MARK: Materialization

    /// Eagerly decode this value (and all children) into a FlexValue tree.
    func materialized() -> FlexValue {
        switch typeId {
        case Self.tNull:
            return .null
        case Self.tBool:
            return boolValue.map(FlexValue.bool) ?? .null
        case Self.tInt, Self.tIndirectInt:
            return intValue.map(FlexValue.int) ?? .null
        case Self.tUInt, Self.tIndirectUInt:
            return uintValue.map(FlexValue.uint) ?? .null
        case Self.tFloat, Self.tIndirectFloat:
            return floatValue.map(FlexValue.float) ?? .null
        case Self.tString, Self.tKey:
            return stringValue.map(FlexValue.string) ?? .null
        case Self.tBlob:
            return blobValue.map(FlexValue.blob) ?? .null
        case Self.tMap:
            let n = count
            var result: [String: FlexValue] = [:]
            result.reserveCapacity(n)
            for i in 0..<n {
                result[key(at: i) ?? "unknown_\(i)"] = self[i]?.materialized() ?? .null
            }
            return .map(result)
        default:
            guard isVector else { return .null }
            let n = count
            var result: [FlexValue] = []
            result.reserveCapacity(n)
            for i in 0..<n {
                result.append(self[i]?.materialized() ?? .null)
            }
            return .vector(result)
        }
    }
}
