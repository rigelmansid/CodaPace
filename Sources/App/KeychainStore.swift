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

    /// 文案走 L10n(OPT-018):从前写死中文,英文界面下设置窗口和面板里照样冒中文
    var errorDescription: String? {
        let language = Config.language
        switch self {
        case .unexpectedStatus(let status):
            // 把系统给的原因原样带出来 —— 钥匙串的失败原因千差万别(权限、锁定、
            // 签名变化),吞掉它等于让用户对着一句「保存失败」无从下手
            let reason = SecCopyErrorMessageString(status, nil) as String?
                ?? L10n.text(.errKeychainUnknownReason, language)
            return L10n.format(.errKeychainFormat, language, "\(reason)(\(status))")
        case .malformedData:
            return L10n.text(.errKeychainMalformed, language)
        }
    }
}

// MARK: - 存取

enum KeychainStore {

    /// 所有条目共用的服务名;具体哪一条由调用方给的 key 区分。
    private static let service = "CodaPace"

    /// 写入或覆盖。**失败时旧值原样保留**(OPT-031)。
    ///
    /// 从前是先删再加:删成功、加失败,旧密钥就没了,正在用的账户当场变成「缺少密钥」。
    /// 现在先写暂存、再撤旧值、最后改名,顺序和理由在 Core 的 SecretVault。那里也解释了
    /// 为什么不是「已存在就原地更新」—— 新建的条目才属于当前构建(坑 2)。
    static func set(_ secret: String, for key: String) throws {
        try Vault().write(secret, to: key)
    }

    /// 读取。没有这一条时返回 nil,**不作为错误** —— 没配过是正常状态,不是故障。
    static func get(_ key: String) throws -> String? {
        try Vault().read(key)
    }

    /// 删除,连覆盖中途留下的暂存一起。本来就没有也算成功 ——
    /// 调用方要的是「删完之后它不在了」这个结果。
    static func remove(_ key: String) throws {
        try Vault().remove(key)
    }

    /// SecItem* 的四个原子操作。**每个返回码都看**:从前删的那一步不看结果,
    /// 删不掉时接着加,报出来的是一句对不上的「条目已存在」。
    private struct Vault: SecretVault {

        private func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: KeychainStore.service,
             kSecAttrAccount as String: account]
        }

        func readItem(_ account: String) throws -> String? {
            var q = query(account)
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

        func addItem(_ secret: String, account: String) throws {
            var attributes = query(account)
            attributes[kSecValueData as String] = Data(secret.utf8)
            // 只在本机、解锁之后可读,且**不参与 iCloud 钥匙串同步** ——
            // 这是一台机器上一个 app 的凭据,同步出去只是白白扩大暴露面。
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }

        func deleteItem(_ account: String) throws {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }

        /// 只改名字,不碰内容和访问控制。暂存条目是当前构建刚建的,改它不会弹授权框
        func renameItem(_ account: String, to newAccount: String) throws {
            let status = SecItemUpdate(query(account) as CFDictionary,
                                       [kSecAttrAccount as String: newAccount] as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
    }
}
