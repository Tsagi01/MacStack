import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacStackCore
extension AppModel {
    func save(_ next: WorkspaceSettings) async {
        guard canSave else { return }
        if let reason = operationGate.saveRejection {
            message = reason
            return
        }

        savingSettings = true
        defer { savingSettings = false }

        let previous = settings
        let outcome = await ServiceReconfiguration.apply(
            previous: previous,
            next: next,
            webWasRunning: webServicesRunning,
            databaseWasRunning: databaseRunning,
            effects: self
        )

        switch outcome {
        case .rejected(let text):
            message = text
        case .persistedOnly, .reconfigured:
            settings = next
            beginBackupScheduler()
            record("已保存网站清单与预设配置。")
        }
    }

    func addWebsite() {
        let panel = NSOpenPanel()
        panel.title = "选择网站根目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var publicRoot = canonical
        let suggested = canonical.appendingPathComponent("public", isDirectory: true)
        if FileManager.default.fileExists(atPath: suggested.appendingPathComponent("index.php").path) {
            let alert = NSAlert()
            alert.messageText = "检测到 public/index.php"
            alert.informativeText = "这个项目可能使用 public 作为公开目录。你可以使用 public，也可以保持项目根目录。"
            alert.addButton(withTitle: "使用 public")
            alert.addButton(withTitle: "使用项目根目录")
            if alert.runModal() == .alertFirstButtonReturn { publicRoot = suggested }
        }
        let reserved = Set(settings.websites.map(\.port) + [settings.preferences.httpPort, settings.preferences.databasePort, settings.preferences.httpsPort])
        guard let port = PortAvailability().nextAvailable(startingAt: 8081, excluding: reserved) else {
            message = "没有找到可用的网站端口。"
            return
        }
        var next = settings
        do {
            try next.addWebsite(at: canonical, publicRoot: publicRoot, port: port)
            try store.save(next)
            settings = next
            websiteStatuses[next.websites.last!.id] = "已登记 · 等待启用"
            record("已登记网站 \(canonical.lastPathComponent)，分配端口 \(port)。")
        }
        catch { message = error.localizedDescription }
    }

    func openApplicationFolder() {
        let folder = RuntimeLayout.applicationSupport().documentRoot
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            record("已在 Finder 中打开默认网站目录。")
        } catch {
            message = "无法打开应用文件夹：\(error.localizedDescription)"
        }
    }

    func removeWebsite(_ id: UUID) async {
        var next = settings
        next.websites.removeAll { $0.id == id }
        await applyWebsiteSettings(next, action: "网站已移出清单；项目文件未删除。", changingID: id)
        if settings.websites.allSatisfy({ $0.id != id }) { websiteStatuses[id] = nil }
    }

    func updateWebsite(_ website: Website) async {
        do { try WebsiteHostingValidator().validate(website) }
        catch { message = error.localizedDescription; return }
        var next = settings
        guard let index = next.websites.firstIndex(where: { $0.id == website.id }) else { return }
        let previousWebsite = next.websites[index]
        let portIsAlreadyOurs = webServicesRunning && previousWebsite.isEnabled && previousWebsite.port == website.port
        guard portIsAlreadyOurs || PortAvailability().isAvailable(website.port) else {
            message = "端口 \(website.port) 已被其他程序占用。"
            return
        }
        next.websites[index] = website
        await applyWebsiteSettings(next, action: "网站 \(website.name) 的设置已更新。", changingID: website.id)
    }

    func toggleWebsite(_ id: UUID) async {
        var next = settings
        guard let index = next.websites.firstIndex(where: { $0.id == id }) else { return }
        if !next.websites[index].isEnabled {
            do { try WebsiteHostingValidator().validate(next.websites[index]) }
            catch { message = error.localizedDescription; return }
            guard PortAvailability().isAvailable(next.websites[index].port) else {
                message = "端口 \(next.websites[index].port) 已被其他程序占用。请编辑网站并换一个端口。"
                return
            }
        }
        next.websites[index].isEnabled.toggle()
        let verb = next.websites[index].isEnabled ? "已启用" : "已停用"
        await applyWebsiteSettings(next, action: "网站 \(next.websites[index].name) \(verb)。", changingID: id)
    }

    func openWebsite(_ website: Website) {
        guard website.isEnabled, webServicesRunning else {
            message = "请先启用网站并启动 Web 环境。"
            return
        }
        NSWorkspace.shared.open(URL(string: website.localURLString)!)
    }

    func openSecureWebsite(_ website: Website) {
        guard webServicesRunning, settings.preferences.httpsEnabled,
              let address = website.secureURLString(port: settings.preferences.httpsPort),
              let url = URL(string: address) else {
            message = "请先为网站设置 .localhost 域名、启用 HTTPS 并启动 Web 环境。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func trustLocalCertificate() async {
        let alert = NSAlert()
        alert.messageText = "信任 MacStack 本地 HTTPS 证书？"
        alert.informativeText = "证书只覆盖 localhost 与当前登记的 .localhost 域名，并加入当前用户登录钥匙串。macOS 可能要求你确认身份。不要将该证书用于互联网服务器。"
        alert.addButton(withTitle: "加入钥匙串")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let hostnames = settings.websites.map(\.hostname).filter { !$0.isEmpty }
            try await Task.detached {
                _ = try TLSCertificateManager().prepare(hostnames: hostnames)
                try TLSCertificateManager().trustForCurrentUser()
            }.value
            tlsStatus = "本地证书已加入当前用户钥匙串。"
            record("本地 HTTPS 证书已加入登录钥匙串。")
        } catch {
            message = error.localizedDescription
            tlsStatus = "证书信任未完成：\(error.localizedDescription)"
        }
    }

    func revealWebsiteLog(_ website: Website) {
        let log = RuntimeLayout.applicationSupport().logDirectory
            .appendingPathComponent("site-\(website.id.uuidString.lowercased())-error.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            reveal(RuntimeLayout.applicationSupport().logDirectory.path)
        }
    }

    func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            message = "路径不存在：\(path)"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

}
