import SwiftUI
import MacStackCore

struct WebsitesPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingWebsite: Website?
    @State private var showingProjectCreator = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "网站", subtitle: "添加项目、选择公开目录并通过独立本机端口运行。")
            HStack {
                Button("创建 PHP 项目…", systemImage: "wand.and.stars") {
                    showingProjectCreator = true
                }
                .disabled(!model.canSave || model.savingSettings || model.creatingProject || model.changingWebsiteID != nil)
                Button("添加网站目录…", systemImage: "plus") { model.addWebsite() }
                    .disabled(!model.canSave || model.savingSettings || model.changingWebsiteID != nil)
                Button("Open Application Folder", systemImage: "folder") {
                    model.openApplicationFolder()
                }
            }
            Text(RuntimeLayout.applicationSupport().documentRoot.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.settings.websites.isEmpty {
                ContentUnavailableView("还没有登记网站", systemImage: "folder.badge.plus", description: Text("选择已有项目文件夹，保存在本地网站清单中。"))
            }
            ForEach(model.settings.websites) { site in
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(site.name).font(.headline)
                            LabeledContent("项目目录", value: site.rootPath)
                            LabeledContent("公开目录", value: site.publicRootPath)
                            LabeledContent("访问地址", value: site.localURLString)
                            Text(model.websiteStatuses[site.id] ?? (site.isEnabled ? "已启用 · 等待 Web 服务启动" : "已停用"))
                                .font(.caption.bold())
                                .foregroundStyle(site.isEnabled ? .teal : .secondary)
                        }
                        Spacer()
                        if model.changingWebsiteID == site.id { ProgressView().controlSize(.small) }
                        }
                        HStack {
                            Button(site.isEnabled ? "停用" : "启用", systemImage: site.isEnabled ? "pause.fill" : "play.fill") {
                                Task { await model.toggleWebsite(site.id) }
                            }
                            Button("打开网站", systemImage: "safari") { model.openWebsite(site) }
                                .disabled(!site.isEnabled || !model.webServicesRunning)
                            if model.settings.preferences.httpsEnabled && !site.hostname.isEmpty {
                                Button("HTTPS", systemImage: "lock") { model.openSecureWebsite(site) }
                                    .disabled(!site.isEnabled || !model.webServicesRunning)
                            }
                            Button("编辑", systemImage: "pencil") { editingWebsite = site }
                            Button("项目目录", systemImage: "folder") { model.reveal(site.rootPath) }
                            Button("错误日志", systemImage: "doc.text") { model.revealWebsiteLog(site) }
                            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: site.rootPath).appendingPathComponent("composer.json").path) {
                                Button("Composer install", systemImage: "shippingbox") {
                                    Task { await model.runComposerInstall(for: site) }
                                }
                                .disabled(model.developerTools?.composerExecutable == nil || model.composerProjectID != nil)
                            }
                            Spacer()
                            Button("移出清单", role: .destructive) {
                                Task { await model.removeWebsite(site.id) }
                            }
                        }.disabled(!model.canSave || model.changingWebsiteID != nil)
                    }.padding(12)
                }
            }
        }
        .sheet(item: $editingWebsite) { website in
            WebsiteEditorView(website: website) { updated in
                Task { await model.updateWebsite(updated) }
            }
        }
        .sheet(isPresented: $showingProjectCreator) {
            ProjectCreatorView { name, parentPath, databaseName, createDatabase in
                await model.createPHPProject(
                    name: name,
                    parentPath: parentPath,
                    databaseName: databaseName,
                    createDatabase: createDatabase
                )
            }
            .environmentObject(model)
        }
    }
}

#Preview("网站") {
    WebsitesPage().environmentObject(AppModel())
}
