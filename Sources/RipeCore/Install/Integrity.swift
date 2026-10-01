import CryptoKit
import Foundation

/// Proves a downloaded archive is the one its publisher released, before anything opens it.
enum Integrity {
    /// - Parameter publicKey: the installed app's `SUPublicEDKey` (base64), needed for `.edDSA`.
    static func verify(_ file: URL, against integrity: Download.Integrity, publicKey: String?) throws {
        switch integrity {
        case .sha256(let expected):
            let actual = try sha256(of: file)
            guard actual == expected.lowercased() else {
                throw InstallError(
                    .integrity,
                    "checksum mismatch: expected \(expected), got \(actual). The download may be corrupt or tampered with."
                )
            }
        case .edDSA(let signature):
            guard let publicKey, let keyData = Data(base64Encoded: publicKey),
                let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            else {
                throw InstallError(
                    .integrity, "the installed app has no usable Sparkle signing key, so the download can't be verified"
                )
            }
            guard let signatureData = Data(base64Encoded: signature) else {
                throw InstallError(.integrity, "the feed's EdDSA signature isn't valid base64")
            }
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            guard key.isValidSignature(signatureData, for: data) else {
                throw InstallError(
                    .integrity,
                    "EdDSA signature doesn't match the app's signing key. The download may be tampered with.")
            }
        }
    }

    /// Streams the file, so a 2 GB download doesn't need 2 GB of memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
