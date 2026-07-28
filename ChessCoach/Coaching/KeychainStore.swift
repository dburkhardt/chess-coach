import Foundation
import LocalAuthentication
import Security

enum CredentialPersistenceAvailability: Equatable, Sendable {
    case persistent
    case sessionOnly
}

protocol KeychainStoring: Sendable {
    var persistenceAvailability: CredentialPersistenceAvailability { get }
    func read(account: String) throws -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String) throws
}

extension KeychainStoring {
    var persistenceAvailability: CredentialPersistenceAvailability {
        .persistent
    }
}

struct InstalledAppRuntimeIdentity: Equatable, Sendable {
    let bundlePath: String
    let bundleIdentifier: String?
    let signingIdentifier: String?
    let teamIdentifier: String?
    let signatureIsValid: Bool
}

struct InstalledAppKeychainAuthorization: Sendable {
    let teamIdentifier: String

    fileprivate init(teamIdentifier: String) {
        self.teamIdentifier = teamIdentifier
    }
}

enum InstalledAppIdentityGate {
    static let requiredBundlePath = "/Applications/Chess Coach.app"
    static let requiredBundleIdentifier = "com.dburkhardt.chesscoach"

    private static let developerIDRequirement =
        #"identifier "com.dburkhardt.chesscoach" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#

    static func authorize(
        _ identity: InstalledAppRuntimeIdentity
    ) throws -> InstalledAppKeychainAuthorization {
        let teamIdentifier = identity.teamIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard identity.bundlePath == requiredBundlePath,
              identity.bundleIdentifier == requiredBundleIdentifier,
              identity.signingIdentifier == requiredBundleIdentifier,
              !teamIdentifier.isEmpty,
              identity.signatureIsValid
        else {
            throw KeychainError.installedSignedAppRequired
        }
        return InstalledAppKeychainAuthorization(
            teamIdentifier: teamIdentifier
        )
    }

#if !DEBUG
    static func authorizeCurrentProcess(
        bundle: Bundle = .main
    ) throws -> InstalledAppKeychainAuthorization {
        try authorize(try currentIdentity(bundle: bundle))
    }

    private static func currentIdentity(
        bundle: Bundle
    ) throws -> InstalledAppRuntimeIdentity {
        let bundlePath = bundle.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
                == errSecSuccess,
              let code
        else {
            throw KeychainError.installedSignedAppRequired
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            developerIDRequirement as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(
                  code,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess
        else {
            throw KeychainError.installedSignedAppRequired
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            code,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess,
              let staticCode
        else {
            throw KeychainError.installedSignedAppRequired
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let signingInformation = information as? [String: Any]
        else {
            throw KeychainError.installedSignedAppRequired
        }

        return InstalledAppRuntimeIdentity(
            bundlePath: bundlePath,
            bundleIdentifier: bundle.bundleIdentifier,
            signingIdentifier:
                signingInformation[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier:
                signingInformation[kSecCodeInfoTeamIdentifier as String] as? String,
            signatureIsValid: true
        )
    }
#endif
}

struct KeychainStore: KeychainStoring, Sendable {
    static let productionService =
        "com.dburkhardt.chesscoach.inference.v2"

    private static let operationLock = NSLock()

    let service: String
    let itemLabel: String
    let itemDescription: String

    init(
        service: String = Self.productionService,
        itemLabel: String = "Chess Coach inference key",
        itemDescription: String =
            "Inference credential used only by Chess Coach"
    ) {
        self.service = service
        self.itemLabel = itemLabel
        self.itemDescription = itemDescription
    }

    var persistenceAvailability: CredentialPersistenceAvailability {
#if DEBUG
        .sessionOnly
#else
        (try? InstalledAppIdentityGate.authorizeCurrentProcess()) == nil
            ? .sessionOnly
            : .persistent
#endif
    }

    func read(account: String) throws -> String? {
        try authorizePersistentAccess()
        return try Self.withSerializedAccess {
            var valueQuery = query(account: account)
            valueQuery[kSecReturnData as String] = true
            valueQuery[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: AnyObject?
            let status = SecItemCopyMatching(
                valueQuery as CFDictionary,
                &result
            )
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError.status(status)
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidValue
            }
            return value
        }
    }

    func save(_ value: String, account: String) throws {
        try authorizePersistentAccess()
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidValue
        }

        try Self.withSerializedAccess {
            let updateStatus = SecItemUpdate(
                query(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecItemNotFound {
                let item: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecValueData as String: data,
                    kSecAttrAccessible as String:
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecAttrLabel as String: itemLabel,
                    kSecAttrDescription as String: itemDescription,
                ]
                let status = SecItemAdd(item as CFDictionary, nil)
                guard status == errSecSuccess else {
                    throw KeychainError.status(status)
                }
            } else if updateStatus != errSecSuccess {
                throw KeychainError.status(updateStatus)
            }
        }
    }

    func delete(account: String) throws {
        try authorizePersistentAccess()
        try Self.withSerializedAccess {
            let status = SecItemDelete(
                query(account: account) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.status(status)
            }
        }
    }

    func query(account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private func authorizePersistentAccess() throws {
#if DEBUG
        throw KeychainError.installedSignedAppRequired
#else
        _ = try InstalledAppIdentityGate.authorizeCurrentProcess()
#endif
    }

    private static func withSerializedAccess<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try operation()
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidValue
    case installedSignedAppRequired

    var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        case .invalidValue:
            "The inference key could not be stored."
        case .installedSignedAppRequired:
            "Persistent inference keys are available only to the signed Chess Coach app installed in Applications."
        }
    }
}
