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

    // MARK: - FlexBuffers Type Constants

    private static let FBT_NULL: UInt8 = 0
    private static let FBT_INT: UInt8 = 1
    private static let FBT_UINT: UInt8 = 2
    private static let FBT_FLOAT: UInt8 = 3
    private static let FBT_KEY: UInt8 = 4
    private static let FBT_STRING: UInt8 = 5
    private static let FBT_INDIRECT_INT: UInt8 = 6
    private static let FBT_INDIRECT_UINT: UInt8 = 7
    private static let FBT_INDIRECT_FLOAT: UInt8 = 8
    private static let FBT_MAP: UInt8 = 9
    private static let FBT_VECTOR: UInt8 = 10
    private static let FBT_VECTOR_INT: UInt8 = 11
    private static let FBT_VECTOR_UINT: UInt8 = 12
    private static let FBT_VECTOR_FLOAT: UInt8 = 13
    private static let FBT_VECTOR_KEY: UInt8 = 14
    private static let FBT_VECTOR_STRING: UInt8 = 15
    private static let FBT_VECTOR_INT2: UInt8 = 16
    private static let FBT_VECTOR_UINT2: UInt8 = 17
    private static let FBT_VECTOR_FLOAT2: UInt8 = 18
    private static let FBT_VECTOR_INT3: UInt8 = 19
    private static let FBT_VECTOR_UINT3: UInt8 = 20
    private static let FBT_VECTOR_FLOAT3: UInt8 = 21
    private static let FBT_VECTOR_INT4: UInt8 = 22
    private static let FBT_VECTOR_UINT4: UInt8 = 23
    private static let FBT_VECTOR_FLOAT4: UInt8 = 24
    private static let FBT_BLOB: UInt8 = 25
    private static let FBT_BOOL: UInt8 = 26

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func decode(_ data: Data) throws -> FlexValue {
        guard data.count >= 3 else {
            throw ParseError(message: "Buffer too small for FlexBuffers")
        }
        let rootByteWidth = Int(data[data.count - 1])
        let rootPackedType = data[data.count - 2]
        let rootOffset = data.count - 2 - rootByteWidth
        return decodeValue(data, offset: rootOffset, parentByteWidth: rootByteWidth, packedType: rootPackedType)
    }

    // MARK: - Primitive Reads

    private static func readUInt(_ data: Data, offset: Int, byteWidth: Int) -> UInt64 {
        switch byteWidth {
        case 1: return UInt64(data[offset])
        case 2:
            return data.withUnsafeBytes { ptr in
                UInt64(ptr.load(fromByteOffset: offset, as: UInt16.self).littleEndian)
            }
        case 4:
            return data.withUnsafeBytes { ptr in
                UInt64(ptr.load(fromByteOffset: offset, as: UInt32.self).littleEndian)
            }
        case 8:
            return data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset, as: UInt64.self).littleEndian
            }
        default: return 0
        }
    }

    private static func readInt(_ data: Data, offset: Int, byteWidth: Int) -> Int64 {
        switch byteWidth {
        case 1: return Int64(Int8(bitPattern: data[offset]))
        case 2:
            return data.withUnsafeBytes { ptr in
                Int64(Int16(bitPattern: ptr.load(fromByteOffset: offset, as: UInt16.self).littleEndian))
            }
        case 4:
            return data.withUnsafeBytes { ptr in
                Int64(Int32(bitPattern: ptr.load(fromByteOffset: offset, as: UInt32.self).littleEndian))
            }
        case 8:
            return data.withUnsafeBytes { ptr in
                Int64(bitPattern: ptr.load(fromByteOffset: offset, as: UInt64.self).littleEndian)
            }
        default: return 0
        }
    }

    private static func readFloat(_ data: Data, offset: Int, byteWidth: Int) -> Double {
        switch byteWidth {
        case 4:
            return data.withUnsafeBytes { ptr in
                Double(ptr.load(fromByteOffset: offset, as: Float.self))
            }
        case 8:
            return data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset, as: Double.self)
            }
        default: return 0
        }
    }

    private static func readString(_ data: Data, offset: Int) -> String {
        var end = offset
        while end < data.count && data[end] != 0 {
            end += 1
        }
        return String(data: data[offset..<end], encoding: .utf8) ?? ""
    }

    // MARK: - Value Decoding

    private static func decodeValue(_ data: Data, offset: Int, parentByteWidth: Int, packedType: UInt8) -> FlexValue {
        let bitWidth = Int(packedType & 0x03)
        let typeId = packedType >> 2
        let childByteWidth = 1 << bitWidth
        return decodeTypedValue(data, offset: offset, parentByteWidth: parentByteWidth,
                                childByteWidth: childByteWidth, typeId: typeId)
    }

    private static func decodeTypedValue(_ data: Data, offset: Int, parentByteWidth: Int,
                                          childByteWidth: Int, typeId: UInt8) -> FlexValue {
        switch typeId {
        case FBT_NULL:
            return .null

        case FBT_BOOL:
            return .bool(readUInt(data, offset: offset, byteWidth: parentByteWidth) != 0)

        case FBT_INT:
            return .int(readInt(data, offset: offset, byteWidth: parentByteWidth))

        case FBT_UINT:
            return .uint(readUInt(data, offset: offset, byteWidth: parentByteWidth))

        case FBT_FLOAT:
            return .float(readFloat(data, offset: offset, byteWidth: parentByteWidth))

        case FBT_STRING:
            let strOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
            return .string(readString(data, offset: strOffset))

        case FBT_KEY:
            let keyOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
            return .string(readString(data, offset: keyOffset))

        case FBT_BLOB:
            let blobOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
            let size = Int(readUInt(data, offset: blobOffset - childByteWidth, byteWidth: childByteWidth))
            return .blob(data[blobOffset..<(blobOffset + size)])

        case FBT_INDIRECT_INT:
            let indirectOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
            return .int(readInt(data, offset: indirectOffset, byteWidth: childByteWidth))

        case FBT_INDIRECT_UINT:
            let indirectOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
            return .uint(readUInt(data, offset: indirectOffset, byteWidth: childByteWidth))

        case FBT_INDIRECT_FLOAT:
            let indirectOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
            return .float(readFloat(data, offset: indirectOffset, byteWidth: childByteWidth))

        case FBT_MAP:
            return decodeMap(data, offset: offset, parentByteWidth: parentByteWidth, byteWidth: childByteWidth)

        case FBT_VECTOR:
            return decodeVector(data, offset: offset, parentByteWidth: parentByteWidth, byteWidth: childByteWidth)

        case FBT_VECTOR_INT, FBT_VECTOR_UINT, FBT_VECTOR_FLOAT,
             FBT_VECTOR_KEY, FBT_VECTOR_STRING, FBT_BOOL:
            return decodeTypedVector(data, offset: offset, parentByteWidth: parentByteWidth,
                                     byteWidth: childByteWidth, typeId: typeId)

        case FBT_VECTOR_INT2, FBT_VECTOR_UINT2, FBT_VECTOR_FLOAT2,
             FBT_VECTOR_INT3, FBT_VECTOR_UINT3, FBT_VECTOR_FLOAT3,
             FBT_VECTOR_INT4, FBT_VECTOR_UINT4, FBT_VECTOR_FLOAT4:
            return decodeFixedTypedVector(data, offset: offset, parentByteWidth: parentByteWidth,
                                          byteWidth: childByteWidth, typeId: typeId)

        default:
            return .null
        }
    }

    // MARK: - Composite Decoding

    private static func decodeVector(_ data: Data, offset: Int, parentByteWidth: Int, byteWidth: Int) -> FlexValue {
        let vecOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
        let size = Int(readUInt(data, offset: vecOffset - byteWidth, byteWidth: byteWidth))
        let typeVecOffset = vecOffset + size * byteWidth

        var result: [FlexValue] = []
        result.reserveCapacity(size)
        for i in 0..<size {
            let elemOffset = vecOffset + i * byteWidth
            let packedType = data[typeVecOffset + i]
            result.append(decodeValue(data, offset: elemOffset, parentByteWidth: byteWidth, packedType: packedType))
        }
        return .vector(result)
    }

    private static func decodeTypedVector(_ data: Data, offset: Int, parentByteWidth: Int,
                                           byteWidth: Int, typeId: UInt8) -> FlexValue {
        let vecOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
        let size = Int(readUInt(data, offset: vecOffset - byteWidth, byteWidth: byteWidth))

        let elemTypeMap: [UInt8: UInt8] = [
            FBT_VECTOR_INT: FBT_INT,
            FBT_VECTOR_UINT: FBT_UINT,
            FBT_VECTOR_FLOAT: FBT_FLOAT,
            FBT_VECTOR_KEY: FBT_KEY,
            FBT_VECTOR_STRING: FBT_STRING,
            FBT_BOOL: FBT_BOOL,
        ]
        let elemType = elemTypeMap[typeId] ?? FBT_NULL

        var result: [FlexValue] = []
        result.reserveCapacity(size)
        for i in 0..<size {
            let elemOffset = vecOffset + i * byteWidth
            result.append(decodeTypedValue(data, offset: elemOffset, parentByteWidth: byteWidth,
                                           childByteWidth: byteWidth, typeId: elemType))
        }
        return .vector(result)
    }

    private static func decodeFixedTypedVector(_ data: Data, offset: Int, parentByteWidth: Int,
                                                byteWidth: Int, typeId: UInt8) -> FlexValue {
        let vecOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))

        let count: Int
        switch typeId {
        case FBT_VECTOR_INT2, FBT_VECTOR_UINT2, FBT_VECTOR_FLOAT2: count = 2
        case FBT_VECTOR_INT3, FBT_VECTOR_UINT3, FBT_VECTOR_FLOAT3: count = 3
        default: count = 4
        }

        let elemType: UInt8
        switch typeId {
        case FBT_VECTOR_INT2, FBT_VECTOR_INT3, FBT_VECTOR_INT4: elemType = FBT_INT
        case FBT_VECTOR_UINT2, FBT_VECTOR_UINT3, FBT_VECTOR_UINT4: elemType = FBT_UINT
        default: elemType = FBT_FLOAT
        }

        var result: [FlexValue] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let elemOffset = vecOffset + i * byteWidth
            result.append(decodeTypedValue(data, offset: elemOffset, parentByteWidth: byteWidth,
                                           childByteWidth: byteWidth, typeId: elemType))
        }
        return .vector(result)
    }

    private static func decodeMap(_ data: Data, offset: Int, parentByteWidth: Int, byteWidth: Int) -> FlexValue {
        let vecOffset = offset - Int(readUInt(data, offset: offset, byteWidth: parentByteWidth))
        let size = Int(readUInt(data, offset: vecOffset - byteWidth, byteWidth: byteWidth))

        // Keys metadata is stored before the size field
        let keysOffsetPos = vecOffset - byteWidth * 3
        let keysOffsetVal = Int(readUInt(data, offset: keysOffsetPos, byteWidth: byteWidth))
        let keysByteWidth = Int(readUInt(data, offset: keysOffsetPos + byteWidth, byteWidth: byteWidth))
        let keysVecOffset = keysOffsetPos - keysOffsetVal

        let typeVecOffset = vecOffset + size * byteWidth

        var result: [String: FlexValue] = [:]
        result.reserveCapacity(size)
        for i in 0..<size {
            // Decode key
            let keyOffset = keysVecOffset + i * keysByteWidth
            let key: String
            if case .string(let s) = decodeTypedValue(data, offset: keyOffset,
                                                       parentByteWidth: keysByteWidth,
                                                       childByteWidth: keysByteWidth,
                                                       typeId: FBT_KEY) {
                key = s
            } else {
                key = "unknown_\(i)"
            }

            // Decode value
            let valOffset = vecOffset + i * byteWidth
            let packedType = data[typeVecOffset + i]
            let val = decodeValue(data, offset: valOffset, parentByteWidth: byteWidth, packedType: packedType)
            result[key] = val
        }
        return .map(result)
    }
}
