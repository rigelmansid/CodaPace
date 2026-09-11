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

    private func migrate() throws {
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

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_samples_account_ts
                ON samples (account_key, ts);
            """)
    }

    // MARK: - 写入

    public func insert(_ sample: Sample) throws {
        let sql = """
            INSERT OR REPLACE INTO samples
              (account_key, ts, total_cost, daily_cost, weekly_opus_cost,
               window_cost, all_tokens, requests)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
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

    // MARK: - 读取

    /// 最近一条采样。**重启后的 token 基线就靠它** ——
    /// 没有它就只能拿累计值当增量,会把上亿的历史全算进今天。
    public func lastSample() throws -> Sample? {
        let sql = """
            SELECT ts, total_cost, daily_cost, weekly_opus_cost,
                   window_cost, all_tokens, requests
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
                   window_cost, all_tokens, requests
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
            requests: Int(sqlite3_column_int(stmt, 6))
        )
    }
}
