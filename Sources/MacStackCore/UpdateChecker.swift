import Foundation

/// 可比较的版本号。
///
/// 不能用字符串比较：`"0.9" < "0.10"` 在字符串意义下是 **false**（逐字符比 `9` > `1`），
/// 而版本意义下 `0.9` 比 `0.10` 旧。必须逐段按整数比。
public struct Version: Comparable, Equatable, Sendable {
    public let components: [Int]
    /// 预发布标识（`0.10.0-beta.1` 里的 `beta.1`）。正式版为 nil。
    public let prerelease: String?
    /// 原始字符串，用于展示。
    public let raw: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var body = trimmed
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }

        let split = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericPart = String(split[0])
        self.prerelease = split.count > 1 ? String(split[1]) : nil

        let pieces = numericPart.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var values: [Int] = []
        for piece in pieces {
            // 只取数字前缀，容忍 `1a` 这类写法；完全取不到数字就认为不是版本号。
            let digits = piece.prefix { $0.isNumber }
            guard let value = Int(digits) else { return nil }
            values.append(value)
        }
        self.components = values
        self.raw = trimmed
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // 数字部分相同：正式版比预发布版新（`1.0.0` > `1.0.0-beta`）。
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left < right
        }
    }
}

public struct UpdateCheckResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// 当前已是最新（含「本地版本比线上还新」这种情况）。
        case upToDate
        case updateAvailable
        case failed
    }

    public let status: Status
    public let currentVersion: String
    public let latestVersion: String?
    /// 是否预发布版本。
    public let latestIsPrerelease: Bool
    public let releaseNotes: String?
    public let releaseURL: URL?
    public let publishedAt: Date?
    /// 失败原因，面向用户。
    public let failureReason: String?
    public let checkedAt: Date

    public init(
        status: Status,
        currentVersion: String,
        latestVersion: String? = nil,
        latestIsPrerelease: Bool = false,
        releaseNotes: String? = nil,
        releaseURL: URL? = nil,
        publishedAt: Date? = nil,
        failureReason: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.status = status
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.latestIsPrerelease = latestIsPrerelease
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
        self.publishedAt = publishedAt
        self.failureReason = failureReason
        self.checkedAt = checkedAt
    }
}

/// 查询 GitHub Releases 并判断是否有新版本。
///
/// **只做「检查 → 看说明 → 打开下载页」**，不下载、不替换、不自动打开浏览器。
/// 自动更新要处理签名验证、停服、替换失败回滚，以及 MariaDB 大版本不能等同于
/// 程序文件回退等问题，是独立的一件事。
public struct UpdateChecker: Sendable {
    /// 仓库标识。与 README 里的下载页保持一致。
    public static let repository = "Tsagi01/MacStack"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func check(currentVersion: String) async -> UpdateCheckResult {
        guard let current = Version(currentVersion) else {
            return UpdateCheckResult(
                status: .failed,
                currentVersion: currentVersion,
                failureReason: "无法识别当前版本号「\(currentVersion)」。"
            )
        }

        let releases: [Release]
        do {
            releases = try await fetchReleases()
        } catch let error as UpdateCheckError {
            return UpdateCheckResult(
                status: .failed,
                currentVersion: currentVersion,
                failureReason: error.errorDescription
            )
        } catch {
            return UpdateCheckResult(
                status: .failed,
                currentVersion: currentVersion,
                failureReason: "检查更新失败：\(error.localizedDescription)"
            )
        }

        // 取版本号最高的一个（草稿已在上游过滤）。
        let candidates = releases.compactMap { release -> (Release, Version)? in
            guard let version = Version(release.tagName) else { return nil }
            return (release, version)
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 }) else {
            return UpdateCheckResult(
                status: .failed,
                currentVersion: currentVersion,
                failureReason: "线上没有可识别的版本号。"
            )
        }

        let (release, latest) = newest
        guard latest > current else {
            return UpdateCheckResult(
                status: .upToDate,
                currentVersion: currentVersion,
                latestVersion: latest.raw,
                latestIsPrerelease: release.prerelease
            )
        }

        return UpdateCheckResult(
            status: .updateAvailable,
            currentVersion: currentVersion,
            latestVersion: latest.raw,
            latestIsPrerelease: release.prerelease,
            releaseNotes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines),
            releaseURL: URL(string: release.htmlURL) ?? Self.releasesPage,
            publishedAt: release.publishedDate
        )
    }

    private func fetchReleases() async throws -> [Release] {
        var components = URLComponents(string: "https://api.github.com/repos/\(Self.repository)/releases")!
        components.queryItems = [URLQueryItem(name: "per_page", value: "10")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 要求带 User-Agent，否则直接 403。
        request.setValue("MacStack-UpdateCheck", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.unexpectedResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        let releases = try decoder.decode([Release].self, from: data)
        // 草稿对用户不可见，不应参与比较。
        return releases.filter { !$0.draft }
    }

    private struct Release: Decodable {
        let tagName: String
        let body: String?
        let htmlURL: String
        let publishedAt: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case draft
            case prerelease
        }

        var publishedDate: Date? {
            guard let publishedAt else { return nil }
            return ISO8601DateFormatter().date(from: publishedAt)
        }
    }
}

public enum UpdateCheckError: Error, LocalizedError {
    case unexpectedResponse
    case rateLimited
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            "GitHub 返回了无法识别的响应。"
        case .rateLimited:
            "GitHub 暂时限制了查询频率，请过一会儿再试。"
        case .httpStatus(let code):
            "GitHub 返回 HTTP \(code)。"
        }
    }
}
