import CryptoKit
import Foundation

struct LocalVectorBlobStore {
    static let quantization = "float16-sidecar-v1"
    static let shardQuantization = "float16-shard-v1"

    private let root: URL
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            self.root = try FileStorageService.applicationSupportDirectory()
                .appending(path: "knowledge", directoryHint: .isDirectory)
                .appending(path: "vectors", directoryHint: .isDirectory)
        }
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func storageKey(model: String, chunkId: UUID, contentHash: String) -> String {
        let digest = SHA256.hash(data: Data("\(model)|\(chunkId.uuidString)|\(contentHash)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(chunkId.uuidString)-\(digest)"
    }

    func shardStorageKey(model: String, workspaceId: String, fingerprint: String) -> String {
        SHA256.hash(data: Data("\(model)|\(workspaceId)|\(fingerprint)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func writeVector(_ vector: [Double], storageKey: String, cryptor: LocalDataCryptor) throws {
        let url = fileURL(for: storageKey)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = Self.encodeFloat16(vector)
        let encrypted = try cryptor.encryptData(encoded, context: encryptionContext(for: storageKey))
        try encrypted.write(to: url, options: [.atomic])
    }

    func readVector(storageKey: String, dimensions: Int, cryptor: LocalDataCryptor) throws -> [Double] {
        let url = fileURL(for: storageKey)
        let encrypted = try Data(contentsOf: url, options: [.mappedIfSafe])
        let encoded = try cryptor.decryptData(encrypted, context: encryptionContext(for: storageKey))
        return Self.decodeFloat16(encoded, dimensions: dimensions)
    }

    func deleteVector(storageKey: String) {
        try? fileManager.removeItem(at: fileURL(for: storageKey))
    }

    func writeShard(_ vectors: [(chunkId: UUID, vector: [Double])], storageKey: String, cryptor: LocalDataCryptor) throws {
        guard let dimensions = vectors.first?.vector.count, dimensions > 0 else { return }
        guard vectors.allSatisfy({ $0.vector.count == dimensions }) else { return }

        var data = Self.shardMagic
        Self.appendUInt32(UInt32(vectors.count), to: &data)
        Self.appendUInt32(UInt32(dimensions), to: &data)

        for item in vectors.sorted(by: { $0.chunkId.uuidString < $1.chunkId.uuidString }) {
            data.append(contentsOf: Self.uuidBytes(item.chunkId))
            data.append(Self.encodeFloat16(item.vector))
        }

        let url = shardFileURL(for: storageKey)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encrypted = try cryptor.encryptData(data, context: shardEncryptionContext(for: storageKey))
        try encrypted.write(to: url, options: [.atomic])
    }

    func readShard(storageKey: String, cryptor: LocalDataCryptor) throws -> [UUID: [Double]] {
        let encrypted = try Data(contentsOf: shardFileURL(for: storageKey), options: [.mappedIfSafe])
        let data = try cryptor.decryptData(encrypted, context: shardEncryptionContext(for: storageKey))
        return try Self.decodeShard(data)
    }

    func deleteAllShards() {
        try? fileManager.removeItem(at: shardRoot)
    }

    private func fileURL(for storageKey: String) -> URL {
        let prefix = String(storageKey.prefix(2))
        return root
            .appending(path: prefix.isEmpty ? "00" : prefix, directoryHint: .isDirectory)
            .appending(path: "\(storageKey).ncv")
    }

    private var shardRoot: URL {
        root.appending(path: "shards", directoryHint: .isDirectory)
    }

    private func shardFileURL(for storageKey: String) -> URL {
        let prefix = String(storageKey.prefix(2))
        return shardRoot
            .appending(path: prefix.isEmpty ? "00" : prefix, directoryHint: .isDirectory)
            .appending(path: "\(storageKey).ncvs")
    }

    private func encryptionContext(for storageKey: String) -> String {
        "LocalVectorBlobStore.vector.\(storageKey).v1"
    }

    private func shardEncryptionContext(for storageKey: String) -> String {
        "LocalVectorBlobStore.shard.\(storageKey).v1"
    }

    private static let shardMagic = Data("NCVSHRD1".utf8)

    private static func encodeFloat16(_ vector: [Double]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt16>.size)
        for value in vector {
            var bits = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decodeFloat16(_ data: Data, dimensions: Int) -> [Double] {
        let count = min(dimensions, data.count / MemoryLayout<UInt16>.size)
        var vector: [Double] = []
        vector.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * MemoryLayout<UInt16>.size
            var bits: UInt16 = 0
            for byteIndex in 0..<MemoryLayout<UInt16>.size {
                bits |= UInt16(data[offset + byteIndex]) << UInt16(byteIndex * 8)
            }
            vector.append(Double(Float16(bitPattern: UInt16(littleEndian: bits))))
        }
        return vector
    }

    private static func decodeShard(_ data: Data) throws -> [UUID: [Double]] {
        var offset = 0
        guard data.count >= shardMagic.count + 8,
              data.prefix(shardMagic.count).elementsEqual(shardMagic) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        offset += shardMagic.count
        guard let count = readUInt32(data, offset: &offset),
              let dimensions = readUInt32(data, offset: &offset),
              count > 0,
              dimensions > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let vectorByteCount = Int(dimensions) * MemoryLayout<UInt16>.size
        var vectors: [UUID: [Double]] = [:]
        vectors.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard offset + 16 + vectorByteCount <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let chunkId = uuid(from: data, offset: offset)
            offset += 16
            let vectorData = data.subdata(in: offset..<(offset + vectorByteCount))
            offset += vectorByteCount
            vectors[chunkId] = decodeFloat16(vectorData, dimensions: Int(dimensions))
        }
        return vectors
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, offset: inout Int) -> UInt32? {
        guard offset + MemoryLayout<UInt32>.size <= data.count else { return nil }
        var value: UInt32 = 0
        for byteIndex in 0..<MemoryLayout<UInt32>.size {
            value |= UInt32(data[offset + byteIndex]) << UInt32(byteIndex * 8)
        }
        offset += MemoryLayout<UInt32>.size
        return UInt32(littleEndian: value)
    }

    private static func uuidBytes(_ id: UUID) -> [UInt8] {
        let uuid = id.uuid
        return [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15
        ]
    }

    private static func uuid(from data: Data, offset: Int) -> UUID {
        UUID(uuid: (
            data[offset], data[offset + 1], data[offset + 2], data[offset + 3],
            data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7],
            data[offset + 8], data[offset + 9], data[offset + 10], data[offset + 11],
            data[offset + 12], data[offset + 13], data[offset + 14], data[offset + 15]
        ))
    }
}
