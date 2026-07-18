import Foundation

struct ManifestFile: Sendable, Identifiable {
    var id: String { path }
    let path: String
    let size: UInt64
    let hash: Data
}

struct UpdateManifest: Sendable {
    let bundle: String
    let version: String
    let platform: String
    let files: [ManifestFile]
    let totalSize: UInt64
}
