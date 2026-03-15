import Foundation

struct ManifestChunk: Sendable {
    let offset: UInt64
    let size: UInt64
    let hash: Data
}

struct ManifestFile: Sendable, Identifiable {
    var id: String { path }
    let path: String
    let size: UInt64
    let hash: Data
    let chunks: [ManifestChunk]
}

struct UpdateManifest: Sendable {
    let bundle: String
    let version: String
    let platform: String
    let files: [ManifestFile]
    let totalSize: UInt64
}
