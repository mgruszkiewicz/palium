import Foundation

nonisolated enum CDNClient {

    static let baseURL = "https://dl.palia.com"
    static let bundle = "Palia"
    static let channel = "live"
    static let platform = "windows"

    // MARK: - JSON Response Types

    private struct CDNEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
        let ok: Bool
        let `as`: String
        let v: T
    }

    struct ChannelInfo: Decodable, Sendable {
        let version: String
        let is_public: Bool
        let bundle: String
        let channel: String
    }

    private struct CDNError: Decodable {
        let message: String
    }

    // MARK: - API

    static func fetchVersion() async throws -> ChannelInfo {
        let url = URL(string: "\(baseURL)/bundle/\(bundle)/channel/\(channel)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let envelope = try JSONDecoder().decode(CDNEnvelope<ChannelInfo>.self, from: data)
        guard envelope.ok else {
            throw PaliumError.cdnError("Channel request failed")
        }
        return envelope.v
    }

    static func downloadManifest(version: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/bundle/\(bundle)/v/\(version)/\(platform)/manifest")!
        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw PaliumError.cdnError("Manifest download failed with status \(httpResponse.statusCode)")
        }
        return data
    }

    static func fileURL(version: String, path: String) -> URL {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(baseURL)/bundle/\(bundle)/v/\(version)/\(platform)/file/\(encodedPath)") else {
            // Fallback: percent-encode the entire path component to handle edge cases
            let safeEncoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
            return URL(string: "\(baseURL)/bundle/\(bundle)/v/\(version)/\(platform)/file/\(safeEncoded)")!
        }
        return url
    }

    // MARK: - Manifest Parsing

    static func parseManifest(_ data: Data) throws -> UpdateManifest {
        let root = try FlexBuffersParser.decode(data)

        guard let rootMap = root.mapValue else {
            throw PaliumError.manifestParseFailed("Root is not a map")
        }

        let bundleName = rootMap["bundle"]?.stringValue ?? ""
        let version = rootMap["version"]?.stringValue ?? ""
        let platformName = rootMap["platform"]?.stringValue ?? ""

        guard let contents = rootMap["contents"]?.mapValue else {
            throw PaliumError.manifestParseFailed("No 'contents' in manifest")
        }

        let totalSize = contents["size"]?.uintValue ?? 0
        var files: [ManifestFile] = []
        collectFiles(from: contents, into: &files)

        return UpdateManifest(
            bundle: bundleName,
            version: version,
            platform: platformName,
            files: files,
            totalSize: totalSize
        )
    }

    private static func collectFiles(from node: [String: FlexValue], into files: inout [ManifestFile]) {
        guard let children = node["files"]?.vectorValue else { return }

        for child in children {
            guard let childMap = child.mapValue else { continue }
            let path = childMap["path"]?.stringValue ?? ""
            let size = childMap["size"]?.uintValue ?? 0
            let hash = childMap["hash"]?.blobValue ?? Data()

            if let chunksVec = childMap["chunks"]?.vectorValue, !chunksVec.isEmpty {
                // Leaf file with chunks
                let chunks = chunksVec.compactMap { chunkVal -> ManifestChunk? in
                    guard let arr = chunkVal.vectorValue, arr.count >= 3 else { return nil }
                    return ManifestChunk(
                        offset: arr[0].uintValue ?? 0,
                        size: arr[1].uintValue ?? 0,
                        hash: arr[2].blobValue ?? Data()
                    )
                }
                files.append(ManifestFile(path: path, size: size, hash: hash, chunks: chunks))
            } else if childMap["files"] != nil {
                // Directory — recurse
                collectFiles(from: childMap, into: &files)
            } else {
                // File with no chunks (possibly empty)
                files.append(ManifestFile(path: path, size: size, hash: hash, chunks: []))
            }
        }
    }
}
