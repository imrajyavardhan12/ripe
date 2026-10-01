import Foundation
import Security

/// Who signed a bundle.
public struct SigningIdentity: Sendable, Hashable {
    /// The Apple Developer Team ID; `nil` for ad-hoc and unsigned code.
    public var teamID: String?
    public var isAdHoc: Bool
}

/// The checks that make a direct install safe. Behind a protocol so the install pipeline can be
/// tested with unsigned throwaway bundles; the live checker is tested against real signed apps.
public protocol CodeSignatureChecking: Sendable {
    /// Reads the signer without judging validity: an installed app can drift from its seal
    /// over the years and still tell us who made it.
    func identity(of bundle: URL) throws -> SigningIdentity
    /// Strict validation of every architecture and all nested code, then the signer.
    func validatedIdentity(of bundle: URL) throws -> SigningIdentity
    /// Whether Gatekeeper would let this bundle run (notarization, revocation).
    func passesGatekeeper(_ bundle: URL) async -> Bool
}

public struct LiveCodeSignatureChecker: CodeSignatureChecking {
    let runner: any ProcessRunner

    public init(runner: any ProcessRunner = LiveProcessRunner()) {
        self.runner = runner
    }

    public func identity(of bundle: URL) throws -> SigningIdentity {
        try Self.signingIdentity(of: try Self.staticCode(bundle))
    }

    public func validatedIdentity(of bundle: URL) throws -> SigningIdentity {
        let code = try Self.staticCode(bundle)
        let flags = SecCSFlags(
            rawValue: SecCSFlags.Element.RawValue(
                kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status == errSecSuccess else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "OSStatus \(status)"
            throw InstallError(.verify, "the download's code signature is invalid (\(reason))")
        }
        return try Self.signingIdentity(of: code)
    }

    public func passesGatekeeper(_ bundle: URL) async -> Bool {
        let result = try? await runner.run(
            URL(filePath: "/usr/sbin/spctl"), ["--assess", "--type", "execute", bundle.path])
        return result?.succeeded == true
    }

    private static func staticCode(_ bundle: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw InstallError(
                .verify, "couldn't read the code signature of \(bundle.lastPathComponent) (OSStatus \(status))")
        }
        return code
    }

    private static func signingIdentity(of code: SecStaticCode) throws -> SigningIdentity {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            throw InstallError(.verify, "couldn't read signing information (OSStatus \(status))")
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return SigningIdentity(
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        )
    }
}
