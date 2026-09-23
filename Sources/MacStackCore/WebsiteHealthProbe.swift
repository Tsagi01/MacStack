import Foundation

/// 一次网站探测的结论分类。
///
/// 分类的目的不是「好看」，而是让界面能给出**可执行**的下一步：403 与 404 需要
/// 不同的处理，500 需要指向错误日志，连接失败需要检查服务或端口。
public enum WebsiteHealthOutcome: Equatable, Sendable {
    /// 2xx：页面正常。
    case ok
    /// 3xx：发生了跳转，`status` 与 `location` 说明跳到哪。
    case redirect
    /// 401：服务已响应，但需要认证。
    case unauthorized
    /// 403：服务已响应，但访问被拒绝。**不一定代表故障**——站点可能故意加了访问保护。
    case forbidden
    /// 404：服务已响应，但找不到页面。
    case notFound
    /// 5xx：服务已响应，但页面执行异常。
    case serverError
    /// 其它 4xx。
    case clientError
    /// 3xx 之外的意外状态码（1xx）。
    case unexpectedStatus
    /// 请求超时。
    case timedOut
    /// 连不上：服务未启动、端口不对或被占用。
    case connectionFailed
    /// 被系统传输安全策略拦截（App Transport Security）。
    case transportBlocked
    /// TLS 握手失败，通常是证书问题。
    case tlsFailure

    /// 是否应当以「异常」的语气呈现。403 归为「已响应但被拒绝」，不算故障。
    public var isFailure: Bool {
        switch self {
        case .ok, .redirect, .forbidden, .unauthorized: false
        case .notFound, .serverError, .clientError, .unexpectedStatus,
             .timedOut, .connectionFailed, .transportBlocked, .tlsFailure: true
        }
    }
}

/// 一次探测的完整记录。
///
/// 保留 `errorDomain` / `errorCode` 是刻意的：界面只说「无法访问」时，用户和我们都
/// 无从判断到底是端口没起、被 ATS 拦了，还是证书有问题。原始错误码是唯一能区分它们的
/// 证据，因此在「建立真实验收手段」这一步就必须记录下来。
public struct WebsiteHealthResult: Equatable, Sendable {
    /// 实际请求的地址。
    public let requestURL: String
    /// HTTP 状态码；请求未到达 HTTP 层时为 nil。
    public let status: Int?
    /// 响应头里的 `Location`（仅 3xx）。
    public let location: String?
    public let outcome: WebsiteHealthOutcome
    /// `NSError` 的 domain，例如 `NSURLErrorDomain`。
    public let errorDomain: String?
    /// `NSError` 的 code，例如 -1004（连接被拒绝）、-1022（被 ATS 拦截）。
    public let errorCode: Int?
    /// 面向人的补充说明。
    public let detail: String?
    public let checkedAt: Date

    /// 跟随本地跳转后到达的最终状态码；未跟随则为 nil。
    public let followedStatus: Int?
    /// 跟随后的最终地址；未跟随则为 nil。
    public let followedURL: String?
    /// 跳转目标是外部地址，因此**没有**跟随。
    public let skippedExternalRedirect: Bool
    /// 检测到跳转循环。
    public let detectedRedirectLoop: Bool

    public init(
        requestURL: String,
        status: Int? = nil,
        location: String? = nil,
        outcome: WebsiteHealthOutcome,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        detail: String? = nil,
        checkedAt: Date = Date(),
        followedStatus: Int? = nil,
        followedURL: String? = nil,
        skippedExternalRedirect: Bool = false,
        detectedRedirectLoop: Bool = false
    ) {
        self.requestURL = requestURL
        self.status = status
        self.location = location
        self.outcome = outcome
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.detail = detail
        self.checkedAt = checkedAt
        self.followedStatus = followedStatus
        self.followedURL = followedURL
        self.skippedExternalRedirect = skippedExternalRedirect
        self.detectedRedirectLoop = detectedRedirectLoop
    }
}

/// 界面上呈现的网站状态。
///
/// 刻意区分两个时间，因为它们回答的是不同问题：
///
/// - `lastCheckedAt`：最后一次**真实 HTTP 请求**的时间。服务停止**不**改变它。
/// - `statusUpdatedAt`：状态本身最后一次变化的时间，含「服务已停止」这类非请求原因。
///
/// 合成一个时间会误导人：停掉服务时把「最后检查时间」也刷新，看起来像刚做过 HTTP 检查，
/// 而实际上那次检查发生在更早、服务还在运行的时候。
public struct WebsiteStatus: Equatable, Sendable {
    public var outcome: WebsiteHealthOutcome
    public var status: Int?
    /// 面向界面的一行文案。
    public var summary: String
    /// 更详细的说明：跳转目标、系统错误码、排查建议。
    public var detail: String?
    /// 最后一次真实 HTTP 请求的时间；nil 表示从未做过真实请求。
    public var lastCheckedAt: Date?
    /// 状态最后一次变化的时间。
    public var statusUpdatedAt: Date
    /// 最后一次真实请求的完整结果，供界面展开查看。
    public var lastResult: WebsiteHealthResult?

    public init(
        outcome: WebsiteHealthOutcome,
        status: Int? = nil,
        summary: String,
        detail: String? = nil,
        lastCheckedAt: Date? = nil,
        statusUpdatedAt: Date = Date(),
        lastResult: WebsiteHealthResult? = nil
    ) {
        self.outcome = outcome
        self.status = status
        self.summary = summary
        self.detail = detail
        self.lastCheckedAt = lastCheckedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.lastResult = lastResult
    }
}

extension WebsiteStatus {
    /// 由一次真实探测结果生成状态。两个时间都取这次请求的时刻。
    public static func from(_ result: WebsiteHealthResult) -> WebsiteStatus {
        WebsiteStatus(
            outcome: result.outcome,
            status: result.status,
            summary: summary(for: result),
            detail: result.detail,
            lastCheckedAt: result.checkedAt,
            statusUpdatedAt: result.checkedAt,
            lastResult: result
        )
    }

    /// 服务未运行时的状态。
    ///
    /// **保留 `previous?.lastCheckedAt`**：服务停止只改变「状态更新时间」，
    /// 不能让界面显示一个假的「刚刚检查过」。
    public static func notRunning(enabled: Bool, previous: WebsiteStatus?, now: Date = Date()) -> WebsiteStatus {
        WebsiteStatus(
            outcome: enabled ? .connectionFailed : .connectionFailed,
            status: nil,
            summary: enabled ? "已启用 · 等待 Web 服务启动" : "已停用",
            detail: enabled ? "Web 服务未运行，尚未发起 HTTP 请求。" : nil,
            lastCheckedAt: previous?.lastCheckedAt,
            statusUpdatedAt: now,
            lastResult: previous?.lastResult
        )
    }

    /// 状态发生非请求类变化（例如服务意外退出）时，只更新时间与文案。
    public static func serviceStopped(previous: WebsiteStatus?, summary: String, now: Date = Date()) -> WebsiteStatus {
        WebsiteStatus(
            outcome: .connectionFailed,
            status: nil,
            summary: summary,
            detail: "Web 服务已停止，尚未发起新的 HTTP 请求。",
            lastCheckedAt: previous?.lastCheckedAt,
            statusUpdatedAt: now,
            lastResult: previous?.lastResult
        )
    }

    static func summary(for result: WebsiteHealthResult) -> String {
        let code = result.status.map { "HTTP \($0)" }
        switch result.outcome {
        case .ok:
            return "页面正常（\(code ?? "HTTP 2xx")）"
        case .redirect:
            var text = "发生跳转（\(code ?? "HTTP 3xx")"
            if let location = result.location { text += " → \(location)" }
            text += "）"
            if result.detectedRedirectLoop { text += " · 检测到跳转循环" }
            if result.skippedExternalRedirect { text += " · 目标是外部地址，未跟随" }
            if let followed = result.followedStatus { text += " · 跟随本地跳转后 HTTP \(followed)" }
            return text
        case .unauthorized:
            return "需要认证（\(code ?? "HTTP 401")）"
        case .forbidden:
            return "访问被拒绝（\(code ?? "HTTP 403")，服务已响应）"
        case .notFound:
            return "找不到页面（\(code ?? "HTTP 404")）"
        case .serverError:
            return "页面执行异常（\(code ?? "HTTP 5xx")）"
        case .clientError:
            return "请求被拒绝（\(code ?? "HTTP 4xx")）"
        case .unexpectedStatus:
            return "未预期的状态码（\(code ?? "未知")）"
        case .timedOut:
            return "请求超时"
        case .connectionFailed:
            return "连接失败"
        case .transportBlocked:
            return "被系统传输安全策略拦截"
        case .tlsFailure:
            return "TLS 握手失败"
        }
    }
}

/// 对站点发起**真实** HTTP 请求并给出分类结论。
///
/// 两个设计要点：
///
/// 1. **使用站点真实域名，不改成 `127.0.0.1`。** 之前为了绕开 App Transport Security
///    改用数字回环地址，代价是请求里没有网站的 `Host`，依赖域名判断的项目
///    （WordPress 的 `siteurl`、Laravel 的 `APP_URL`）表现会与浏览器里不一致。
///    正确做法是在 `Info.plist` 声明只覆盖 `localhost` 及其子域的传输安全例外，
///    然后照用户真实访问的方式请求。
///
/// 2. **默认不跟随重定向。** `URLSession` 默认自动跟随，会把 301/302 悄悄变成最终的
///    200，界面就永远显示不出「发生了跳转」。这里先拿到原始 3xx 与 `Location`，
///    再**有限度地**探测本地跳转目标，并把外部跳转、跳转循环分开报告。
public struct WebsiteHealthProbe: Sendable {
    public struct Configuration: Sendable {
        /// 单次请求超时。
        public var timeout: TimeInterval
        /// 最多跟随几跳本地跳转。
        public var maximumLocalRedirectHops: Int
        public var userAgent: String

        public init(
            timeout: TimeInterval = 3,
            maximumLocalRedirectHops: Int = 2,
            userAgent: String = "MacStack-HealthProbe/1.0"
        ) {
            self.timeout = timeout
            self.maximumLocalRedirectHops = maximumLocalRedirectHops
            self.userAgent = userAgent
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout
        // 健康检查必须反映此刻的真实状态，不能命中缓存。
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// 探测一个地址。不抛错——所有失败都表达为分类结果，便于界面统一呈现。
    public func probe(_ url: URL) async -> WebsiteHealthResult {
        let first = await attempt(url)
        guard case .redirect = first.outcome, let location = first.location else {
            return first
        }

        // 拿到跳转目标后，决定是否继续探测。
        guard let target = URL(string: location, relativeTo: url)?.absoluteURL else {
            return first
        }
        guard isLocal(target, relativeTo: url) else {
            return WebsiteHealthResult(
                requestURL: first.requestURL, status: first.status, location: first.location,
                outcome: first.outcome, errorDomain: first.errorDomain, errorCode: first.errorCode,
                detail: first.detail, checkedAt: first.checkedAt,
                skippedExternalRedirect: true
            )
        }

        var visited: Set<String> = [url.absoluteString]
        var current = target
        var last = first
        for _ in 0..<max(0, configuration.maximumLocalRedirectHops) {
            if visited.contains(current.absoluteString) {
                return WebsiteHealthResult(
                    requestURL: first.requestURL, status: first.status, location: first.location,
                    outcome: .redirect, errorDomain: first.errorDomain, errorCode: first.errorCode,
                    detail: "跳转目标回到了已经访问过的地址，存在跳转循环。",
                    checkedAt: first.checkedAt,
                    followedURL: current.absoluteString,
                    detectedRedirectLoop: true
                )
            }
            visited.insert(current.absoluteString)

            last = await attempt(current)
            guard case .redirect = last.outcome, let nextLocation = last.location else { break }
            guard let next = URL(string: nextLocation, relativeTo: current)?.absoluteURL,
                  isLocal(next, relativeTo: url) else {
                // 跟到一半跳出本地范围，停在这里并如实报告。
                return WebsiteHealthResult(
                    requestURL: first.requestURL, status: first.status, location: first.location,
                    outcome: first.outcome, errorDomain: first.errorDomain, errorCode: first.errorCode,
                    detail: first.detail, checkedAt: first.checkedAt,
                    followedStatus: last.status, followedURL: last.requestURL,
                    skippedExternalRedirect: true
                )
            }
            current = next
        }

        return WebsiteHealthResult(
            requestURL: first.requestURL, status: first.status, location: first.location,
            outcome: first.outcome, errorDomain: first.errorDomain, errorCode: first.errorCode,
            detail: first.detail, checkedAt: first.checkedAt,
            followedStatus: last.status, followedURL: last.requestURL
        )
    }

    /// 跳转目标是否仍在「本机」范围内。外部地址不跟随——健康检查不该顺手去访问互联网。
    private func isLocal(_ target: URL, relativeTo origin: URL) -> Bool {
        guard let host = target.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "127.0.0.1" || host == "::1" { return true }
        return host == origin.host?.lowercased()
    }

    private func attempt(_ url: URL) async -> WebsiteHealthResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        request.httpMethod = "GET"
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        // 明确不接受压缩：健康检查只关心状态与响应头，不解析正文。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            let (_, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            let location = http?.value(forHTTPHeaderField: "Location")
            let outcome = Self.classify(status: status)
            return WebsiteHealthResult(
                requestURL: url.absoluteString,
                status: status,
                location: location,
                outcome: outcome,
                detail: Self.describe(status: status, outcome: outcome, location: location)
            )
        } catch {
            let nsError = error as NSError
            let outcome = Self.classify(errorCode: nsError.code)
            return WebsiteHealthResult(
                requestURL: url.absoluteString,
                outcome: outcome,
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                detail: Self.describe(error: nsError, outcome: outcome)
            )
        }
    }

    static func classify(status: Int?) -> WebsiteHealthOutcome {
        guard let status else { return .unexpectedStatus }
        switch status {
        case 200..<300: return .ok
        case 300..<400: return .redirect
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default: return .unexpectedStatus
        }
    }

    /// 按 `NSURLError` 错误码分类。
    ///
    /// -1022 是 App Transport Security 的拦截，必须与「连不上」区分开：前者说明请求
    /// 根本没发出去，后者说明服务没起来。混在一起会让排查方向完全错掉。
    static func classify(errorCode: Int) -> WebsiteHealthOutcome {
        switch errorCode {
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .transportBlocked
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return .tlsFailure
        default:
            return .connectionFailed
        }
    }

    private static func describe(
        status: Int?,
        outcome: WebsiteHealthOutcome,
        location: String?
    ) -> String {
        guard let status else { return "服务已响应，但状态码无法识别。" }
        switch outcome {
        case .ok:
            return "页面正常。"
        case .redirect:
            return location.map { "发生跳转，目标：\($0)" } ?? "发生了跳转，但响应里没有 Location。"
        case .unauthorized:
            return "服务已响应，但需要认证。"
        case .forbidden:
            return "服务已响应，但访问被拒绝。站点可能设置了访问保护。"
        case .notFound:
            return "服务已响应，但找不到页面。检查公开目录里是否有 index.php 或 index.html。"
        case .serverError:
            return "页面执行异常。查看站点错误日志定位具体原因。"
        case .clientError:
            return "服务已响应，但请求被拒绝（HTTP \(status)）。"
        case .unexpectedStatus:
            return "收到未预期的状态码 HTTP \(status)。"
        case .timedOut, .connectionFailed, .transportBlocked, .tlsFailure:
            return "未收到 HTTP 响应。"
        }
    }

    private static func describe(error: NSError, outcome: WebsiteHealthOutcome) -> String {
        switch outcome {
        case .timedOut:
            return "请求超时，站点可能在处理中卡住。"
        case .transportBlocked:
            return "请求被系统传输安全策略拦截（\(error.domain) \(error.code)）。"
        case .tlsFailure:
            return "TLS 握手失败，通常是证书问题（\(error.domain) \(error.code)）。"
        case .connectionFailed:
            return "连不上：检查服务是否运行、端口是否正确（\(error.domain) \(error.code)）。"
        default:
            return error.localizedDescription
        }
    }
}

/// 拒绝自动跟随重定向，让调用方拿到原始 3xx。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 传 nil 表示不跟随：把 301/302 原样交回，界面才能如实显示「发生跳转」。
        completionHandler(nil)
    }
}
