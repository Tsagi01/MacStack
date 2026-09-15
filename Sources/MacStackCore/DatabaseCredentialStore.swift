import Foundation
import Security
import LocalAuthentication

public struct DatabaseCredentials: Equatable, Sendable {
    public let username: String
    public let password: String
}

public enum DatabaseCredentialError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidStoredValue
    case randomGeneration(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): "无法访问 macOS 钥匙串（状态码 \(status)）。"
        case .invalidStoredValue: "钥匙串中的 MacStack 数据库凭据格式无效。"
        case .randomGeneration(let status): "无法生成数据库随机密码（状态码 \(status)）。"
        }
    }
}

public struct DatabaseCredentialStore: Sendable {
    private let service: String
    private let account: String
    public init() {
        service = "local.macstack.app.database.v1"
        account = "macstack"
    }

    init(testService: String, account: String = "macstack") {
        service = testService
        self.account = account
    }

    public func loadOrCreate() throws -> DatabaseCredentials {
        if let existing = try load() { return existing }
        var random = [UInt8](repeating: 0, count: 24)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        guard randomStatus == errSecSuccess else {
            throw DatabaseCredentialError.randomGeneration(randomStatus)
        }
        let password = random.map { String(format: "%02x", $0) }.joined()
        let data = Data(password.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "MacStack local MariaDB",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else { throw DatabaseCredentialError.keychain(status) }
        return DatabaseCredentials(username: account, password: password)
    }

    public func load() throws -> DatabaseCredentials? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DatabaseCredentialError.keychain(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw DatabaseCredentialError.invalidStoredValue
        }
        return DatabaseCredentials(username: account, password: password)
    }

    func deleteTestItem() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DatabaseCredentialError.keychain(status)
        }
    }
}
