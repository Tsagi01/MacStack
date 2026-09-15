import Foundation

public struct DeveloperToolReport: Equatable, Sendable {
    public let phpVersion: String
    public let phpExecutable: String
    public let phpModules: [String]
    public let composerVersion: String?
    public let composerExecutable: String?
    public let perlVersion: String?
    public let perlExecutable: String?
    public let proFTPDVersion: String?
    public let proFTPDExecutable: String?
}

public struct DeveloperToolInspector: Sendable {
    public let prefix: URL
    private let runner = FoundationCommandRunner()

    public init(prefix: URL = URL(fileURLWithPath: "/opt/homebrew")) {
        self.prefix = prefix
    }

    public func inspect(preferredPHPFormula: String = "auto") throws -> DeveloperToolReport {
        let web = try WebStackResolver(prefix: prefix, preferredFormula: preferredPHPFormula).resolve()
        let modulesOutput = try runner.run(executable: web.php, arguments: ["-m"])
        let modules = modulesOutput.combinedOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("[") && !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let composer = firstExecutable([
            prefix.appendingPathComponent("bin/composer"),
            URL(fileURLWithPath: "/usr/local/bin/composer")
        ])
        let perl = firstExecutable([
            prefix.appendingPathComponent("bin/perl"),
            URL(fileURLWithPath: "/usr/bin/perl")
        ])
        let proftpd = firstExecutable([
            prefix.appendingPathComponent("bin/proftpd"),
            prefix.appendingPathComponent("sbin/proftpd"),
            URL(fileURLWithPath: "/usr/local/sbin/proftpd")
        ])
        return DeveloperToolReport(
            phpVersion: web.phpVersion,
            phpExecutable: web.php.path,
            phpModules: modules,
            composerVersion: version(composer, arguments: ["--version"]),
            composerExecutable: composer?.path,
            perlVersion: version(perl, arguments: ["-v"]),
            perlExecutable: perl?.path,
            proFTPDVersion: version(proftpd, arguments: ["-v"]),
            proFTPDExecutable: proftpd?.path
        )
    }

    private func firstExecutable(_ urls: [URL]) -> URL? {
        urls.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func version(_ executable: URL?, arguments: [String]) -> String? {
        guard let executable,
              let result = try? runner.run(executable: executable, arguments: arguments),
              result.status == 0 else { return nil }
        return VersionText.firstLine(result.combinedOutput)
    }
}

public enum ComposerError: Error, LocalizedError {
    case unavailable
    case invalidProject(String)
    case commandFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "没有找到 Composer。可先通过 Homebrew 安装 composer。"
        case .invalidProject(let path): "Composer 项目目录无效或是符号链接：\(path)"
        case .commandFailed(let status, let output): "Composer 执行失败（退出码 \(status)）：\n\(output)"
        }
    }
}

public struct ComposerRunner: Sendable {
    public let executable: URL

    public init(executable: URL? = nil) throws {
        let choices = [
            executable,
            URL(fileURLWithPath: "/opt/homebrew/bin/composer"),
            URL(fileURLWithPath: "/usr/local/bin/composer")
        ].compactMap { $0 }
        guard let found = choices.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ComposerError.unavailable
        }
        self.executable = found
    }

    public func install(project: URL) throws -> String {
        let root = project.standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw ComposerError.invalidProject(root.path)
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["install", "--no-interaction", "--no-ansi"]
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ComposerError.commandFailed(process.terminationStatus, output)
        }
        return output
    }
}
