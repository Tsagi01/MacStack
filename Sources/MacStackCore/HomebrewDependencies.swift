import Foundation

public struct HomebrewDependency: Equatable, Identifiable, Sendable {
    public var id: String { formula }
    public let formula: String
    public let title: String
    public let required: Bool
    public let installedVersion: String?
}

public struct HomebrewDependencyReport: Equatable, Sendable {
    public let brewPath: String?
    public let dependencies: [HomebrewDependency]
}

public enum HomebrewDependencyError: Error, LocalizedError {
    case homebrewMissing
    case unsafeFormula(String)
    case installFailed(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .homebrewMissing: "没有找到 Apple Silicon Homebrew（/opt/homebrew/bin/brew）。"
        case .unsafeFormula(let formula): "拒绝安装未列入 MacStack 白名单的配方：\(formula)"
        case .installFailed(let formula, let status, let output): "Homebrew 安装 \(formula) 失败（退出码 \(status)）：\n\(output)"
        }
    }
}

public struct HomebrewDependencyManager: Sendable {
    public static let catalog: [(formula: String, title: String, required: Bool)] = [
        ("httpd", "Apache Web Server", true),
        ("php@8.2", "PHP 8.2 + PHP-FPM", true),
        ("mariadb@11.4", "MariaDB 11.4", true),
        ("phpmyadmin", "phpMyAdmin", false),
        ("composer", "Composer", false)
    ]
    public let brew: URL

    public init(brew: URL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")) {
        self.brew = brew
    }

    public func inspect() -> HomebrewDependencyReport {
        guard FileManager.default.isExecutableFile(atPath: brew.path) else {
            return HomebrewDependencyReport(
                brewPath: nil,
                dependencies: Self.catalog.map { HomebrewDependency(formula: $0.formula, title: $0.title, required: $0.required, installedVersion: nil) }
            )
        }
        let dependencies = Self.catalog.map { item -> HomebrewDependency in
            let result = try? FoundationCommandRunner().run(executable: brew, arguments: ["list", "--versions", item.formula])
            let value = result?.status == 0 ? VersionText.firstLine(result?.combinedOutput ?? "") : nil
            return HomebrewDependency(formula: item.formula, title: item.title, required: item.required, installedVersion: value)
        }
        return HomebrewDependencyReport(brewPath: brew.path, dependencies: dependencies)
    }

    public func install(formulas: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: brew.path) else { throw HomebrewDependencyError.homebrewMissing }
        let allowed = Set(Self.catalog.map(\.formula) + ["php@8.3", "php@8.4", "php@8.5", "php"])
        var output = ""
        for formula in formulas {
            guard allowed.contains(formula) else { throw HomebrewDependencyError.unsafeFormula(formula) }
            let result = try FoundationCommandRunner().run(executable: brew, arguments: ["install", formula])
            output += result.combinedOutput
            guard result.status == 0 else {
                throw HomebrewDependencyError.installFailed(formula, result.status, result.combinedOutput)
            }
        }
        return output
    }
}
