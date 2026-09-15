import Foundation

public enum ProjectCreationError: Error, LocalizedError {
    case invalidName
    case invalidParent(String)
    case refusesSymbolicLink(String)
    case destinationExists(String)
    case invalidDatabaseName
    case registrationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidName: "项目名称不能为空，也不能包含 /、冒号、换行、空字符或以点开头。"
        case .invalidParent(let path): "项目上级目录不存在、不可写或不是文件夹：\(path)"
        case .refusesSymbolicLink(let path): "为避免写入意外位置，项目上级目录不能是符号链接：\(path)"
        case .destinationExists(let path): "目标项目已经存在，未覆盖：\(path)"
        case .invalidDatabaseName: "数据库名称必须以英文字母开头，只能包含英文字母、数字和下划线，最长 64 个字符。"
        case .registrationFailed: "项目文件已经创建，但网站登记未成功，已回滚本次创建。"
        }
    }
}

public struct CreatedPHPProject: Equatable, Sendable {
    public let root: URL
    public let publicRoot: URL
    public let files: [URL]
}

public struct PHPProjectCreator: Sendable {
    public init() {}

    public func validateProjectName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix("."),
              !value.contains("/"),
              !value.contains(":"),
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else {
            throw ProjectCreationError.invalidName
        }
        return value
    }

    public func validateDatabaseName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_]{0,63}$")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard expression.firstMatch(in: value, range: range) != nil else {
            throw ProjectCreationError.invalidDatabaseName
        }
        return value
    }

    public func create(
        named name: String,
        in parent: URL,
        databaseName: String?,
        databasePort: Int
    ) throws -> CreatedPHPProject {
        let safeName = try validateProjectName(name)
        let safeDatabase = try databaseName.map(validateDatabaseName)
        let canonicalParent = parent.standardizedFileURL
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: canonicalParent.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              files.isWritableFile(atPath: canonicalParent.path) else {
            throw ProjectCreationError.invalidParent(canonicalParent.path)
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ProjectCreationError.refusesSymbolicLink(canonicalParent.path)
        }
        let destination = canonicalParent.appendingPathComponent(safeName, isDirectory: true)
        guard !files.fileExists(atPath: destination.path) else {
            throw ProjectCreationError.destinationExists(destination.path)
        }

        let staging = canonicalParent.appendingPathComponent(".macstack-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        let publicRoot = staging.appendingPathComponent("public", isDirectory: true)
        let assets = publicRoot.appendingPathComponent("assets", isDirectory: true)
        let config = staging.appendingPathComponent("config", isDirectory: true)
        try files.createDirectory(at: assets, withIntermediateDirectories: true)
        try files.createDirectory(at: config, withIntermediateDirectories: true)

        let databaseLabel = safeDatabase.map { "数据库：\($0)" } ?? "数据库：暂未创建"
        let index = """
        <?php
        declare(strict_types=1);
        date_default_timezone_set('Asia/Shanghai');
        $title = '欢迎使用 \(phpSingleQuoted(safeName))';
        ?>
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title><?= htmlspecialchars($title, ENT_QUOTES, 'UTF-8') ?></title>
          <link rel="stylesheet" href="assets/style.css">
        </head>
        <body>
          <main>
            <span class="badge">MacStack PHP</span>
            <h1><?= htmlspecialchars($title, ENT_QUOTES, 'UTF-8') ?></h1>
            <p>当前服务器时间：<strong><?= date('Y-m-d H:i:s') ?></strong></p>
            <p>\(htmlEscaped(databaseLabel))</p>
            <p>编辑 <code>public/index.php</code>，刷新浏览器即可看到结果。</p>
          </main>
        </body>
        </html>
        """
        let style = """
        :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0d1718; color: #eafafa; }
        main { width: min(680px, calc(100% - 48px)); padding: 40px; border: 1px solid #315b5b; border-radius: 22px; background: #142526; box-shadow: 0 20px 70px #0007; }
        h1 { font-size: clamp(2rem, 6vw, 4rem); margin: 18px 0; }
        p { color: #b9d2d2; line-height: 1.7; }
        .badge { display: inline-block; padding: 7px 11px; border-radius: 999px; background: #0f766e; font-weight: 700; }
        code { color: #77e0d5; }
        """
        let databaseExample = Self.pdoTemplate(databaseName: safeDatabase ?? "YOUR_DATABASE", databasePort: databasePort)
        let readme = """
        # \(safeName)

        这是由 MacStack 创建的 PHP 项目。

        - 浏览器入口：`public/index.php`
        - 样式：`public/assets/style.css`
        - 数据库连接示例：`config/database.example.php`
        - 不要把真实数据库密码提交到 Git；复制示例后从环境变量读取密码。

        \(databaseLabel)
        """
        let output: [(String, String)] = [
            ("public/index.php", index + "\n"),
            ("public/assets/style.css", style + "\n"),
            ("config/database.example.php", databaseExample),
            ("README.md", readme + "\n"),
            (".gitignore", ".DS_Store\n.env\nconfig/database.php\n")
        ]
        for (path, content) in output {
            try Data(content.utf8).write(to: staging.appendingPathComponent(path), options: .atomic)
        }
        try files.moveItem(at: staging, to: destination)
        return CreatedPHPProject(
            root: destination,
            publicRoot: destination.appendingPathComponent("public", isDirectory: true),
            files: output.map { destination.appendingPathComponent($0.0) }
        )
    }

    public static func pdoTemplate(databaseName: String, databasePort: Int) -> String {
        let escaped = phpSingleQuoted(databaseName)
        return """
        <?php
        declare(strict_types=1);

        $dsn = 'mysql:host=127.0.0.1;port=\(databasePort);dbname=\(escaped);charset=utf8mb4';
        $username = 'macstack';
        $password = getenv('MACSTACK_DB_PASSWORD') ?: 'YOUR_PASSWORD_HERE';

        $pdo = new PDO($dsn, $username, $password, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
        """ + "\n"
    }

    private static func phpSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func phpSingleQuoted(_ value: String) -> String { Self.phpSingleQuoted(value) }

    private func htmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
