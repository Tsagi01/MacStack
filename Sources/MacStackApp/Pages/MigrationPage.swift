import SwiftUI
import MacStackCore

struct MigrationPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingLegacyDatabaseMigration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "旧 XAMPP 迁移", subtitle: "先盘点、再选择、后迁移；当前步骤严格只读。")
            GroupBox("阶段 1：只读盘点") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("读取 /Applications/XAMPP 中的网站目录名、可统计大小、旧组件架构和非敏感配置摘要。不会运行旧二进制，也不会显示数据库密码或配置内容片段。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("生成只读盘点报告", systemImage: "doc.text.magnifyingglass") {
                            Task { await model.auditXAMPP() }
                        }.disabled(model.auditingXAMPP)
                        Button("在 Finder 中显示报告", systemImage: "folder") {
                            model.revealXAMPPAuditReport()
                        }.disabled(model.xamppAuditReportPath == nil)
                        if model.auditingXAMPP { ProgressView().controlSize(.small) }
                    }
                    Text(model.xamppAuditStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let path = model.xamppAuditReportPath {
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("阶段 2：网站迁移副本") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("选择目标、二次确认、SHA-256 验证；保留原文件", systemImage: "square.on.square")
                    Label("数据库使用逻辑 SQL 导出与导入，不复用旧物理目录", systemImage: "cylinder.split.1x2")
                    Label("迁移后逐项验证，再决定是否清理旧环境", systemImage: "checkmark.shield")
                    if model.xamppSites.isEmpty {
                        Text("生成盘点报告后，这里会列出可以创建副本的网站。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.xamppSites, id: \.path) { site in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(site.name).font(.headline)
                                Text("\(site.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: site.byteCount, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("创建迁移副本…", systemImage: "square.on.square") {
                                Task { await model.migrateWebsiteCopy(site) }
                            }.disabled(model.migratingSite != nil || !site.readable)
                        }
                    }
                    if model.migratingSite != nil { ProgressView("正在校验和复制…") }
                    Text(model.websiteMigrationStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Divider()
                    Button("迁移旧 XAMPP 数据库…", systemImage: "cylinder.split.1x2") {
                        showingLegacyDatabaseMigration = true
                    }
                    Text("数据库迁移要求旧 XAMPP 的数据库服务正在运行；使用逻辑导出/导入，绝不复制物理数据目录。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showingLegacyDatabaseMigration) {
            LegacyDatabaseMigrationView().environmentObject(model)
        }
    }
}

#Preview("迁移") {
    MigrationPage().environmentObject(AppModel())
}
