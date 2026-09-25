//
//  UpdateChecker.swift — 「有新版本」提醒
//
//  **只提醒，不安装。** 点那一行打开 GitHub 的 Release 页面，用户自己下载或跑命令行重装。
//  议过 app 内一键下载替换：那要为「从网上拿代码替换自己」配一整套签名校验和私钥保管，
//  而只提醒的话，用户下载时的信任和首次安装完全一样。讨论记录在项目须知「应用内更新」一节。
//
//  新版能无感接上，是因为用户数据全都不在 app 包里（偏好、History.sqlite、钥匙串）。
//  前提是 bundle ID、偏好键名、钥匙串服务名永远不改，数据库迁移只向前。
//
//  查询失败（离线、GitHub 限流、响应格式变了）一律**不显示也不报错**，保留上一次的结论：
//  这是个锦上添花的提醒，不该因为连不上 GitHub 让面板出现一条错误。
//

import Foundation

@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    /// 点提醒打开的页面。releases/latest 会跳到最新一版，那页有更新说明、下载附件和命令行安装命令
    static let releasePage = URL(string: "https://github.com/rigelmansid/CodaPace/releases/latest")!
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/rigelmansid/CodaPace/releases/latest")!

    /// 比本机新的那个版本；没有新版、或还没查成功时为 nil
    @Published private(set) var available: ReleaseVersion?

    private var timer: Timer?

    /// 启动时查一次，之后每天一次。GitHub 未登录的限额是每小时 60 次，远用不完
    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer?.tolerance = 3600
    }

    func check() async {
        guard let installedText = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let installed = ReleaseVersion(installedText) else { return }

        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(LatestRelease.self, from: data),
              let latest = ReleaseVersion(release.tagName)
        else { return }

        available = latest > installed ? latest : nil
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }
}
