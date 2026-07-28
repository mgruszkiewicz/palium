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
    /// SHA-256 digest over every file's (path, size, hash), computed locally from `files`
    /// rather than trusted from the manifest's own "contents.hash" field. Lets us detect
    /// content changes the CDN ships without bumping the channel version.
    let contentsHash: Data
}
