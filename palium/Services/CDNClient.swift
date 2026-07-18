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
        // Walk the manifest lazily: only the fields we keep are ever decoded,
        // which avoids materializing the (large) per-chunk metadata.
        let root = try FlexBuffersParser.root(data)

        guard root.isMap else {
            throw PaliumError.manifestParseFailed("Root is not a map")
        }

        let bundleName = root["bundle"]?.stringValue ?? ""
        let version = root["version"]?.stringValue ?? ""
        let platformName = root["platform"]?.stringValue ?? ""

        guard let contents = root["contents"], contents.isMap else {
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

    private static func collectFiles(from node: FlexRef, into files: inout [ManifestFile]) {
        guard let children = node["files"], children.isVector else { return }

        for i in 0..<children.count {
            guard let child = children[i], child.isMap else { continue }

            if child["files"] != nil {
                // Directory — recurse
                collectFiles(from: child, into: &files)
                continue
            }

            // Leaf file. Per-chunk metadata is deliberately skipped: downloads
            // and verification operate on whole files.
            files.append(ManifestFile(
                path: child["path"]?.stringValue ?? "",
                size: child["size"]?.uintValue ?? 0,
                hash: child["hash"]?.blobValue ?? Data()
            ))
        }
    }
}
