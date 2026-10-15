import CommonCrypto
import CryptoKit
import Foundation
import ProxyCore

/// The subscriptions built into the app are sealed (scripts/seal.py: PBKDF2-HMAC-SHA256 -> AES-256-GCM) with the
/// unlock password (repo secret PROXY_UNLOCK_PASSWORD), so the public repo's builds hold nothing readable. The app
/// asks for the password once, keeps it in this device's Keychain and opens the bundle on every launch.
/// `sealed.json`: {"v":1,"iter":N,"salt":b64,"nonce":b64,"ct":b64(ciphertext+tag)}; the plaintext is
/// {"liangxin_url","gulu_url","liangxin","gulu","cn"} (the last three: sing-box profiles as strings, or null).
struct Payload: Decodable {
    let liangxin_url: String?
    let gulu_url: String?
    let liangxin: String?
    let gulu: String?
    let cn: String?

    func url(_ a: Plan.Source) -> URL? {
        let s: String?
        switch a {
        case .liangxin: s = liangxin_url
        case .gulu: s = gulu_url
        case .cn: s = nil
        }
        return s.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    func snapshot(_ a: Plan.Source) -> Data? {
        let s: String?
        switch a {
        case .liangxin: s = liangxin
        case .gulu: s = gulu
        case .cn: s = cn
        }
        return s.map { Data($0.utf8) }
    }
}

enum VaultError: LocalizedError {
    case notInBuild, wrongPassword
    var errorDescription: String? {
        switch self {
        case .notInBuild: return "This build has no sealed subscriptions."
        case .wrongPassword: return "Wrong password."
        }
    }
}

enum Vault {
    private struct Sealed: Decodable { let v: Int; let iter: Int; let salt: String; let nonce: String; let ct: String }

    static func open(password: String) throws -> Payload {
        guard let url = Bundle.main.url(forResource: "sealed", withExtension: "json"),
              let raw = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Sealed.self, from: raw),
              let salt = Data(base64Encoded: s.salt), let nonce = Data(base64Encoded: s.nonce),
              let ct = Data(base64Encoded: s.ct), ct.count > 16 else { throw VaultError.notInBuild }
        let key = derive(password, salt: salt, rounds: s.iter)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct.dropLast(16), tag: ct.suffix(16))
            let plain = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(Payload.self, from: plain)
        } catch { throw VaultError.wrongPassword }
    }

    private static func derive(_ password: String, salt: Data, rounds: Int) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    // MARK: the password in the Keychain (this device only)

    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "dev.de0ch.proxy.unlock",
                                              kSecAttrAccount as String: "subscriptions"]

    static var savedPassword: String? {
        var q = item
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ password: String) {
        forget()
        var q = item
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func forget() { SecItemDelete(item as CFDictionary) }
}
