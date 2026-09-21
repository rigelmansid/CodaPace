//
//  HistoryStore.swift — 本地历史存储(SQLite)
//
//  用系统自带的 SQLite C API,不引第三方依赖。
//  所有表都按 account_key 分区,换 apiId 时历史自动隔离。
//

import Foundation
import SQLite3

/// 绑定字符串时必须告诉 SQLite「这块内存待会儿就没了,你自己拷一份」,
/// 否则 Swift 的临时字符串在语句执行前就被回收,读出来是乱码。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct StoreError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class HistoryStore {

    private var db: OpaquePointer?
    private let accountKey: String

    /// 是否正处在一个显式事务里。SQLite 不支持嵌套事务,靠它挡住误用。
    private var isInTransaction = false

    /// 默认落盘位置
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("CodaPace", isDirectory: true)
            .appendingPathComponent("History.sqlite")
    }

    public init(path: URL = HistoryStore.defaultURL(), accountKey: String) throws {
        self.accountKey = accountKey

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &db, flags, nil) == SQLITE_OK else {
            throw StoreError("无法打开历史数据库:\(lastMessage)")
        }

        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA busy_timeout = 3000;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - 建表

    /// 当前的库结构版本。加字段、加表都要把它 +1,并在 migrate 里补上对应的一步。
    ///
    /// 用 SQLite 自带的 `user_version`,不额外建表 —— 它就是为这件事准备的。
    static let schemaVersion: Int32 = 3

    private func migrate() throws {
        let from = try userVersion()

        try execute("""
            CREATE TABLE IF NOT EXISTS samples (
                account_key      TEXT NOT NULL,
                ts               REAL NOT NULL,
                total_cost       REAL NOT NULL,
                daily_cost       REAL NOT NULL,
                weekly_opus_cost REAL NOT NULL,
                window_cost      REAL NOT NULL,
                all_tokens       REAL NOT NULL,
                requests         INTEGER NOT NULL,
                PRIMARY KEY (account_key, ts)
            );
            """)

        try execute("""
            CREATE TABLE IF NOT EXISTS token_days (
                account_key TEXT NOT NULL,
                day         TEXT NOT NULL,
                tokens      REAL NOT NULL DEFAULT 0,
                requests    INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (account_key, day)
            );
            """)

        // v3 起:归不到具体某天的增量。总量不丢,但不假装知道它属于哪天。
        // (CREATE TABLE IF NOT EXISTS 本身幂等,不必按版本号门控;
        //  需要门控的是 ALTER TABLE 那类不可重复的操作。)
        try execute("""
            CREATE TABLE IF NOT EXISTS unattributed_deltas (
                account_key TEXT NOT NULL,
                from_ts     REAL NOT NULL,
                to_ts       REAL NOT NULL,
                tokens      REAL NOT NULL,
                requests    INTEGER NOT NULL,
                PRIMARY KEY (account_key, from_ts, to_ts)
            );
            """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_samples_account_ts
                ON samples (account_key, ts);
            """)

        // v1 → v2:记下采样当时的额度上限。
        //
        // 老行的这四列留空(NULL),**刻意不回填当前上限** —— 那等于把今天的配额
        // 说成当时的事实。读出来是 nil,画图时如实跳过,而不是编一个百分比。
        if from < 2 {
            for column in ["total_limit", "daily_limit", "weekly_opus_limit", "window_limit"] {
                try addColumnIfMissing(column, to: "samples")
            }
        }

        try setUserVersion(Self.schemaVersion)
    }

    // MARK: - 版本

    private func userVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    /// 加一列。已经有了就跳过 —— SQLite 没有 ADD COLUMN IF NOT EXISTS,
    /// 而重复建表的老库(v1 之前就建好的)可能已经带上了。
    private func addColumnIfMissing(_ column: String, to table: String) throws {
        let stmt = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(stmt) }

        var existing: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) { existing.insert(String(cString: name)) }
        }
        guard !existing.contains(column) else { return }

        try execute("ALTER TABLE \(table) ADD COLUMN \(column) REAL;")
    }

    // MARK: - 事务

    /// 把若干次写入合成一个原子单元:要么全进,要么一条不留。
    ///
    /// 需要它的场景是一次刷新要写两处 —— `samples` 里的采样行,和 `token_days` 里
    /// 当天的增量。分两次自动提交的话,只写进一半就退出会留下一个**没法修复**的状态:
    /// 那条采样成了重启后的恢复基线,而它对应的增量从未累加,再也补不回来
    /// (基线一旦前移,那段用量就不在任何一次差值的区间里了)。
    ///
    /// 用 `BEGIN IMMEDIATE` 而不是默认的 `DEFERRED`:这里必然要写,
    /// 一开始就拿写锁,好把「提交时才发现拿不到锁」提前暴露成开始时失败。
    ///
    /// **不可嵌套** —— SQLite 没有嵌套事务,套用会得到 `cannot start a transaction
    /// within a transaction`。这里显式挡掉,给一句能看懂的错误。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !isInTransaction else {
            throw StoreError("事务不能嵌套")
        }

        try execute("BEGIN IMMEDIATE;")
        isInTransaction = true
        defer { isInTransaction = false }

        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            // 回滚本身再失败也只能咽下 —— 要往上报的是 body 的原始错误。
            // COMMIT 失败也走这里,同样需要回滚,不能让连接一直挂在事务里。
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 写入

    public func insert(_ sample: Sample) throws {
        let sql = """
            INSERT OR REPLACE INTO samples
              (account_key, ts, total_cost, daily_cost, weekly_opus_cost,
               window_cost, all_tokens, requests,
               total_limit, daily_limit, weekly_opus_limit, window_limit)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, sample.at.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, sample.totalCost)
        sqlite3_bind_double(stmt, 4, sample.dailyCost)
        sqlite3_bind_double(stmt, 5, sample.weeklyOpusCost)
        sqlite3_bind_double(stmt, 6, sample.windowCost)
        sqlite3_bind_double(stmt, 7, sample.allTokens)
        sqlite3_bind_int(stmt, 8, Int32(sample.requests))

        // 上限未知时写 NULL,和「上限为 0(不限)」区分开
        if let limits = sample.limits {
            sqlite3_bind_double(stmt, 9, limits.total)
            sqlite3_bind_double(stmt, 10, limits.daily)
            sqlite3_bind_double(stmt, 11, limits.weeklyOpus)
            sqlite3_bind_double(stmt, 12, limits.window)
        } else {
            for index in Int32(9)...Int32(12) { sqlite3_bind_null(stmt, index) }
        }

        try step(stmt)
    }

    /// 把增量累加进当天的桶(没有就新建)
    public func addTokenDelta(day: String, tokens: Double, requests: Int) throws {
        let sql = """
            INSERT INTO token_days (account_key, day, tokens, requests)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(account_key, day) DO UPDATE SET
                tokens   = tokens + excluded.tokens,
                requests = requests + excluded.requests;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, day, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, tokens)
        sqlite3_bind_int(stmt, 4, Int32(requests))

        try step(stmt)
    }

    /// 记下一段归不到具体某天的增量
    public func addUnattributed(from: Date, to: Date, tokens: Double, requests: Int) throws {
        let sql = """
            INSERT INTO unattributed_deltas (account_key, from_ts, to_ts, tokens, requests)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(account_key, from_ts, to_ts) DO UPDATE SET
                tokens   = tokens + excluded.tokens,
                requests = requests + excluded.requests;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, to.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, tokens)
        sqlite3_bind_int(stmt, 5, Int32(requests))

        try step(stmt)
    }

    // MARK: - 读取

    /// 某段时间里归不到具体某天的用量合计。
    /// 界面据此如实说明「另有这么多用量无法归到某一天」,而不是把它悄悄抹掉。
    public func unattributedTotal(from: Date, to: Date) throws -> (tokens: Double, requests: Int) {
        let sql = """
            SELECT COALESCE(SUM(tokens), 0), COALESCE(SUM(requests), 0)
            FROM unattributed_deltas
            WHERE account_key = ? AND from_ts >= ? AND to_ts <= ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, to.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (sqlite3_column_double(stmt, 0), Int(sqlite3_column_int(stmt, 1)))
    }

    /// 最近一条采样。**重启后的 token 基线就靠它** ——
    /// 没有它就只能拿累计值当增量,会把上亿的历史全算进今天。
    public func lastSample() throws -> Sample? {
        let sql = """
            SELECT ts, total_cost, daily_cost, weekly_opus_cost,
                   window_cost, all_tokens, requests,
                   total_limit, daily_limit, weekly_opus_limit, window_limit
            FROM samples WHERE account_key = ?
            ORDER BY ts DESC LIMIT 1;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readSample(stmt)
    }

    public func samples(from: Date, to: Date) throws -> [Sample] {
        let sql = """
            SELECT ts, total_cost, daily_cost, weekly_opus_cost,
                   window_cost, all_tokens, requests,
                   total_limit, daily_limit, weekly_opus_limit, window_limit
            FROM samples
            WHERE account_key = ? AND ts >= ? AND ts <= ?
            ORDER BY ts ASC;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, to.timeIntervalSince1970)

        var result: [Sample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(readSample(stmt))
        }
        return result
    }

    public func tokenDays(from: String, to: String) throws -> [TokenDay] {
        let sql = """
            SELECT day, tokens, requests FROM token_days
            WHERE account_key = ? AND day >= ? AND day <= ?
            ORDER BY day ASC;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, from, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, to, -1, SQLITE_TRANSIENT)

        var result: [TokenDay] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = String(cString: sqlite3_column_text(stmt, 0))
            result.append(TokenDay(day: day,
                                   tokens: sqlite3_column_double(stmt, 1),
                                   requests: Int(sqlite3_column_int(stmt, 2))))
        }
        return result
    }

    public func sampleCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM samples WHERE account_key = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - 保留策略

    /// 删掉早于 cutoff 的采样(按天聚合的 token 桶很小,不清理)
    public func pruneSamples(before cutoff: Date) throws {
        let stmt = try prepare("DELETE FROM samples WHERE account_key = ? AND ts < ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, accountKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
        try step(stmt)
    }

    // MARK: - 底层

    private var lastMessage: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "未知错误"
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError("SQL 执行失败:\(lastMessage)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError("SQL 预编译失败:\(lastMessage)")
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw StoreError("SQL 写入失败:\(lastMessage)")
        }
    }

    private func readSample(_ stmt: OpaquePointer?) -> Sample {
        Sample(
            at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
            totalCost: sqlite3_column_double(stmt, 1),
            dailyCost: sqlite3_column_double(stmt, 2),
            weeklyOpusCost: sqlite3_column_double(stmt, 3),
            windowCost: sqlite3_column_double(stmt, 4),
            allTokens: sqlite3_column_double(stmt, 5),
            requests: Int(sqlite3_column_int(stmt, 6)),
            limits: readLimits(stmt, from: 7)
        )
    }

    /// 四列任意一列为 NULL 就当整组上限未知 —— 半组上限拼不出一条完整的历史事实。
    /// 迁移上来的老行四列都是 NULL,正好落在这里。
    private func readLimits(_ stmt: OpaquePointer?, from index: Int32) -> QuotaLimits? {
        for offset in Int32(0)..<Int32(4) where
            sqlite3_column_type(stmt, index + offset) == SQLITE_NULL {
            return nil
        }
        return QuotaLimits(total: sqlite3_column_double(stmt, index),
                           daily: sqlite3_column_double(stmt, index + 1),
                           weeklyOpus: sqlite3_column_double(stmt, index + 2),
                           window: sqlite3_column_double(stmt, index + 3))
    }
}
