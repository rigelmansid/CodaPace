//
//  Decoding.swift — 严格解码的通用机制
//
//  **不属于任何一家供应商。** 这里只有两件事:怎么判定一个字段「坏了」,
//  以及坏了之后怎么把字段名带出去。各家的线上格式各自住在自己的适配器旁边
//  (中转站的在 RelayModels.swift,tu-zi 的在 TuziProvider.swift)。
//
//  策略是**容忍缺失,拒绝无效**。这两件事从前混在一起,都退回 0:
//
//  · 缺失(没这个键)或 null —— 容忍。对方加减字段不该让整份响应解码失败。
//  · 存在但类型不对(数字位置上是字符串、对象位置上是数组…)—— 拒绝整份响应。
//    这不是「没有」,是数据坏了;给它填 0 会被下游当成真实的「花了 0 块钱」。
//
//  容忍缺失本身也有代价:0 和「不知道」在历史里是两件完全不同的事。
//  所以要进历史的那几个数值会另外记一笔「这次是不是真的观测到了」。
//

import Foundation

// MARK: - 请求失败

/// 一次抓取失败时给用户看的东西。两个适配器都用它 —— 失败的**形状**是通用的,
/// 失败的**原因**才是各家自己的。
public struct APIError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - 无效字段

/// 响应里某个字段**存在但类型不对**。
///
/// 单独立一个错误类型,是为了能在错误信息里点出是哪个字段坏了 ——
/// 笼统的「响应格式无法解析」对着一个自建中转站根本没法排查。
public struct InvalidFieldError: Error, Equatable {
    public let field: String
    public init(field: String) { self.field = field }
}

/// 响应解得开,却**不是这家的格式** —— 一个协议特征字段都没有(OPT-016)。
///
/// 通用的中转站软件适配器几乎所有字段都可缺失(没设上限就不报),于是任何 JSON 对象
/// 都能解成一份「全默认值」:反代的 `200 {"error":…}`、别的软件的响应都会被当成
/// 「这家、没设额度」,测试连接就此报成功并停下,不再试下一家。
/// 合法的「没设上限」和「根本不是这个协议」必须分开 —— 前者照常,后者报错。
struct ProtocolMismatchError: Error {}

// MARK: - 解码辅助

/// 这几个是**通用**的严格解码工具,不属于任何一家的线上格式 ——
/// 所以是 internal 而不是 private:第二个适配器(TuziProvider)照样要用它们,
/// 各抄一份就成了会各自漂移的平行实现(不变量 5)。
///
/// 它们目前住在这个文件里,是因为「不重排文件」比「按洁癖归位」更要紧。
extension KeyedDecodingContainer {

    /// 键存在且不是 null
    ///
    /// null 归到「没给」而不是「坏了」:用 null 表示可选字段为空是很常见的写法,
    /// 为此把整份响应判死太激进。但它同样不是观测值,照样会让用量被标成不完整。
    func present(_ k: Key) throws -> Bool {
        guard contains(k) else { return false }
        return try !decodeNil(forKey: k)
    }

    func number(_ k: Key) throws -> Double? {
        guard try present(k) else { return nil }
        guard let v = try? decode(Double.self, forKey: k) else {
            throw InvalidFieldError(field: k.stringValue)
        }
        return v
    }

    func integer(_ k: Key) throws -> Int? {
        guard try present(k) else { return nil }
        guard let v = try? decode(Int.self, forKey: k) else {
            throw InvalidFieldError(field: k.stringValue)
        }
        return v
    }

    func text(_ k: Key) throws -> String? {
        guard try present(k) else { return nil }
        guard let v = try? decode(String.self, forKey: k) else {
            throw InvalidFieldError(field: k.stringValue)
        }
        return v
    }

    func flag(_ k: Key) throws -> Bool? {
        guard try present(k) else { return nil }
        guard let v = try? decode(Bool.self, forKey: k) else {
            throw InvalidFieldError(field: k.stringValue)
        }
        return v
    }

    /// 嵌套对象。缺失 → nil;存在但解不出来 → 拒绝。
    /// 内层自己抛的 InvalidFieldError 原样上抛,好保留真正出问题的那个字段名。
    func object<T: Decodable>(_ type: T.Type, forKey k: Key) throws -> T? {
        guard try present(k) else { return nil }
        do {
            return try decode(type, forKey: k)
        } catch let error as InvalidFieldError {
            throw error
        } catch {
            throw InvalidFieldError(field: k.stringValue)
        }
    }

    func nested<NestedKey>(_ keys: NestedKey.Type,
                           forKey k: Key) throws -> KeyedDecodingContainer<NestedKey>? {
        guard try present(k) else { return nil }
        guard let container = try? nestedContainer(keyedBy: keys, forKey: k) else {
            throw InvalidFieldError(field: k.stringValue)
        }
        return container
    }
}

