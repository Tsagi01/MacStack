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
                Button("打开默认网站目录", systemImage: "folder") {
                    model.openDefaultWebsiteFolder()
                }
                Spacer()
                Button("刷新全部状态", systemImage: "arrow.clockwise") {
                    Task { await model.refreshWebsiteStatuses() }
                }
                .disabled(!model.webServicesRunning)
                .help("对所有已启用的网站重新发起一次真实 HTTP 请求")
            }

            defaultWebsiteCard

            if model.settings.websites.isEmpty {
                ContentUnavailableView(
                    "还没有登记其他网站",
                    systemImage: "folder.badge.plus",
                    description: Text("上面的默认网站目录可以直接放文件使用；也可以在这里登记已有的项目文件夹。")
                )
            }
            ForEach(model.settings.websites) { site in
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(site.name).font(.headline)
                            // 用「项目目录」与「网页公开目录」两个说法把「在哪里写代码」和
                            // 「浏览器能看到哪里」区分开——这是新手最容易混淆的一处。
                            LabeledContent("项目目录（写代码的地方）", value: site.rootPath)
                            LabeledContent("网页公开目录（浏览器能访问的地方）", value: site.publicRootPath)
                            LabeledContent("访问地址", value: site.localURLString)
                            statusView(model.websiteStatuses[site.id]
                                ?? WebsiteStatus.notRunning(enabled: site.isEnabled, previous: nil))
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
                            Button("刷新状态", systemImage: "arrow.clockwise") {
                                Task { await model.refreshWebsiteStatus(site.id) }
                            }
                            .disabled(!site.isEnabled || !model.webServicesRunning)
                            Button("项目目录", systemImage: "folder") { model.reveal(site.rootPath) }
                            Button("用 \(model.externalEditor.name) 打开", systemImage: "chevron.left.forwardslash.chevron.right") {
                                model.openInExternalEditor(URL(fileURLWithPath: site.rootPath))
                            }
                            .disabled(!model.externalEditor.isAvailable)
                            .help(model.externalEditor.isAvailable
                                ? "用 VS Code 打开项目目录"
                                : "未检测到 VS Code 命令行工具")
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
        .task {
            // 只在页面可见时做低频检查：切走即停止，不做常驻轮询。
            while !Task.isCancelled {
                await model.refreshWebsiteStatuses()
                try? await Task.sleep(for: .seconds(20))
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

    /// 默认网站卡片。
    ///
    /// 它不在 `settings.websites` 里，但同样由 Apache 提供，用户也常直接往里面放文件。
    /// 之前这里只有一行等宽路径，看起来不像「一个网站」，不容易意识到可以直接用。
    private var defaultWebsiteCard: some View {
        let root = RuntimeLayout.applicationSupport().documentRoot
        let status = model.defaultWebsiteStatus
            ?? WebsiteStatus.notRunning(enabled: true, previous: nil)
        return GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("默认网站").font(.headline)
                        Text("MacStack 自带")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.teal.opacity(0.2))
                            .foregroundStyle(.teal)
                            .clipShape(Capsule())
                    }
                    LabeledContent("网页公开目录（浏览器能访问的地方）", value: root.path)
                    LabeledContent("访问地址", value: model.defaultWebsiteURL?.absoluteString ?? "—")
                    statusView(status)
                }
                HStack {
                    Button("在 Finder 中打开", systemImage: "folder") { model.openDefaultWebsiteFolder() }
                    Button("用 \(model.externalEditor.name) 打开", systemImage: "chevron.left.forwardslash.chevron.right") {
                        model.openInExternalEditor(root)
                    }
                    .disabled(!model.externalEditor.isAvailable)
                    .help(model.externalEditor.isAvailable
                        ? "用 VS Code 打开这个目录"
                        : "未检测到 VS Code 命令行工具")
                    Button("打开网站", systemImage: "safari") { model.openDefaultWebsite() }
                        .disabled(!model.webServicesRunning)
                    Button("刷新状态", systemImage: "arrow.clockwise") {
                        Task { await model.refreshWebsiteStatuses() }
                    }
                    .disabled(!model.webServicesRunning)
                    Spacer()
                }
            }.padding(12)
        }
    }

    /// 网站状态：一行结论 + 补充说明 + 两个时间。
    ///
    /// 两个时间刻意分开显示：
    /// - 「最后检查」= 最后一次**真实 HTTP 请求**。服务停止不会让它跳动。
    /// - 「状态更新」= 状态本身最后一次变化，含服务停止这类非请求原因。
    ///
    /// 合成一个会让用户以为「刚做过检查」，而实际那次检查发生在服务还在运行时。
    @ViewBuilder
    private func statusView(_ status: WebsiteStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(status.summary)
                .font(.caption.bold())
                .foregroundStyle(statusColor(status))
            if let detail = status.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(status.lastCheckedAt.map { "最后检查 \(Self.timeText($0))" } ?? "尚未检查")
                Text("状态更新 \(Self.timeText(status.statusUpdatedAt))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// 颜色只在**做过真实请求**之后才有意义：从未检查过时用中性色，
    /// 避免把「还没查」渲染成红色故障。
    private func statusColor(_ status: WebsiteStatus) -> Color {
        guard status.lastCheckedAt != nil else { return .secondary }
        switch status.outcome {
        case .ok:
            return .teal
        case .redirect, .forbidden, .unauthorized:
            // 服务已响应，只是需要留意——不是故障。
            return .orange
        case .notFound, .serverError, .clientError, .unexpectedStatus,
             .timedOut, .connectionFailed, .transportBlocked, .tlsFailure:
            return .red
        }
    }
}

#Preview("网站") {
    WebsitesPage().environmentObject(AppModel())
}
