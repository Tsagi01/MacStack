import Foundation

public enum ExternalEditorError: Error, LocalizedError {
    case notInstalled
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            """
            没有找到 VS Code 的命令行工具。
            安装 VS Code 后，在它的命令面板里执行 Shell Command: Install 'code' command in PATH。
            """
        case .launchFailed(let detail):
            "无法启动 VS Code：\(detail)"
        }
    }
}

/// 在外部编辑器里打开项目目录。
///
/// 只支持 VS Code：它是这类教学场景最常用的编辑器，而且提供了稳定的命令行入口
/// （`code <目录>`）。**没有安装时要能被检测出来**，界面据此禁用按钮并说明原因，
/// 而不是让用户点了没反应。
public struct ExternalEditor: Sendable {
    public let name = "VS Code"
    public let executable: URL?

    public var isAvailable: Bool { executable != nil }

    public init(prefix: URL = URL(fileURLWithPath: "/opt/homebrew")) {
        let candidates = [
            // 用户执行过 "Install 'code' command in PATH" 之后的常见位置。
            prefix.appendingPathComponent("bin/code"),
            URL(fileURLWithPath: "/usr/local/bin/code"),
            URL(fileURLWithPath: "/usr/bin/code"),
            // 没装命令行工具时，直接调用 app 包里自带的入口。
            URL(fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
        ]
        self.executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 用编辑器打开一个目录。
    ///
    /// 刻意**不等待**进程结束：编辑器会一直运行，等它会让界面卡住。
    public func open(directory: URL) throws {
        guard let executable else { throw ExternalEditorError.notInstalled }
        let process = Process()
        process.executableURL = executable
        process.arguments = [directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ExternalEditorError.launchFailed(error.localizedDescription)
        }
    }
}
