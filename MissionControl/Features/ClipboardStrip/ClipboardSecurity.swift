import CryptoKit
import Foundation
import Security

enum ClipboardStorageError: LocalizedError {
    case keyUnavailable(OSStatus)
    case missingKeyForExistingHistory
    case invalidEncryptedData
    case locked(String)

    var errorDescription: String? {
        switch self {
        case let .keyUnavailable(status):
            return "The clipboard encryption key is unavailable (\(status))."
        case .missingKeyForExistingHistory:
            return "Encrypted clipboard history exists, but its Keychain key is missing."
        case .invalidEncryptedData:
            return "Clipboard history could not be authenticated or decoded."
        case let .locked(message):
            return message
        }
    }
}

protocol ClipboardCrypting {
    func seal(_ data: Data, authenticating additionalData: Data) throws -> Data
    func open(_ data: Data, authenticating additionalData: Data) throws -> Data
}

struct AESClipboardCryptor: ClipboardCrypting {
    let key: SymmetricKey

    func seal(_ data: Data, authenticating additionalData: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: additionalData)
        guard let combined = box.combined else {
            throw ClipboardStorageError.invalidEncryptedData
        }
        return combined
    }

    func open(_ data: Data, authenticating additionalData: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key, authenticating: additionalData)
    }
}

struct KeychainClipboardKeyStore {
    private let service = "com.ranveer.droppy.clipboard"
    private let account = "history-key-v1"

    func loadOrCreateKey(historyExists: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }

        guard status == errSecItemNotFound else {
            throw ClipboardStorageError.keyUnavailable(status)
        }
        guard !historyExists else {
            throw ClipboardStorageError.missingKeyForExistingHistory
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: keyData,
        ]
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw ClipboardStorageError.keyUnavailable(insertStatus)
        }

        return key
    }
}
