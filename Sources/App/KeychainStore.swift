//
//  KeychainStore.swift — 密钥的安全存储
//
//  为什么不能沿用 UserDefaults:
//  中转站的 apiId 是只读统计标识(发不了请求、也拿不到 API Key),所以明文存可以接受;
//  但那是**那一家的性质**,不是通用前提 —— EXT-003 为此建了 CredentialSensitivity,
//  并在 Config.apply 里加了守卫,把声明为 .secret 的适配器当场挡住。
//
//  tu-zi 的 sk- key 能发起真实 API 调用、能花钱,只能声明 .secret,于是那个守卫如期拦住了它。
//  它不是障碍 —— 它就是为这一刻建的。这个文件是它的出口(EXT-001 阶段 0)。
//
//  走**文件版钥匙串**,刻意不设 kSecUseDataProtectionKeychain:
//  数据保护版要求 keychain-access-groups 权限,而那随 provisioning profile 分发,
//  本项目是 ad-hoc 签名、没有 profile。文件版对 ad-hoc 签名的 app 可用,
//  代价是首次访问时系统会弹一次授权框。
//

import Foundation
import Security

// MARK: - 错误

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case malformedData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            // 把系统给的原因原样带出来 —— 钥匙串的失败原因千差万别(权限、锁定、
            // 签名变化),吞掉它等于让用户对着一句「保存失败」无从下手
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "未知原因"
            return "钥匙串操作失败:\(reason)(\(status))"
        case .malformedData:
            return "钥匙串里存的不是有效文本"
        }
    }
}

// MARK: - 存取

enum KeychainStore {

    /// 所有条目共用的服务名;具体哪一条由调用方给的 key 区分。
    private static let service = "CodaPace"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    /// 写入或覆盖。
    ///
    /// 先删再加,而不是 add 失败了再 update:后者要按「已存在」分一次支,
    /// 而这条分支只在极少数时候走到,恰恰最容易写错又最不容易被发现。
    static func set(_ secret: String, for key: String) throws {
        SecItemDelete(query(key) as CFDictionary)

        var attributes = query(key)
        attributes[kSecValueData as String] = Data(secret.utf8)
        // 只在本机、解锁之后可读,且**不参与 iCloud 钥匙串同步** ——
        // 这是一台机器上一个 app 的凭据,同步出去只是白白扩大暴露面。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// 读取。没有这一条时返回 nil,**不作为错误** —— 没配过是正常状态,不是故障。
    static func get(_ key: String) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }

        guard let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { throw KeychainError.malformedData }
        return text
    }

    /// 删除。本来就没有也算成功 —— 调用方要的是「删完之后它不在了」这个结果。
    static func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
