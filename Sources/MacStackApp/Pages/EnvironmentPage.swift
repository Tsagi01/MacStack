import SwiftUI
import MacStackCore

struct EnvironmentPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "原生组件检测", subtitle: "优先检查 MacStack.app 内置运行时；开发版缺少内置包时才读取 /opt/homebrew。检测不会启动服务。")
            Button("检测 PHP 扩展与开发工具", systemImage: "wrench.and.screwdriver") {
                Task { await model.inspectDeveloperTools() }
            }
            .disabled(model.inspectingDeveloperTools)
            if let runtime = model.portableRuntime {
                GroupBox("内置便携运行时") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("无需 Homebrew", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.teal)
                        LabeledContent("运行时版本", value: runtime.manifest.runtimeVersion)
                        LabeledContent("Apache", value: runtime.manifest.apacheVersion)
                        LabeledContent("PHP", value: runtime.manifest.phpVersion)
                        LabeledContent("MariaDB", value: runtime.manifest.mariaDBVersion)
                        LabeledContent("phpMyAdmin", value: runtime.manifest.phpMyAdminVersion)
                        Text(model.dependencyStatus).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let report = model.dependencyReport {
                GroupBox("组件安装") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(report.dependencies) { dependency in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(dependency.title)
                                    Text(dependency.formula).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(dependency.installedVersion ?? "未安装")
                                    .font(.caption).foregroundStyle(dependency.installedVersion == nil ? Color.secondary : Color.teal)
                            }
                        }
                        let missingCore = report.dependencies.filter { $0.required && $0.installedVersion == nil }.map(\.formula)
                        let missingOptional = report.dependencies.filter { !$0.required && $0.installedVersion == nil }.map(\.formula)
                        HStack {
                            if !missingCore.isEmpty {
                                Button("安装缺失核心组件", systemImage: "arrow.down.circle") {
                                    Task { await model.installDependencies(missingCore) }
                                }
                            }
                            if !missingOptional.isEmpty {
                                Button("安装可选工具", systemImage: "shippingbox") {
                                    Task { await model.installDependencies(missingOptional) }
                                }
                            }
                            if model.installingDependencies { ProgressView().controlSize(.small) }
                        }
                        Text(model.dependencyStatus).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(model.inspections) { result in
                GroupBox(result.component.title) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(result.status.rawValue).font(.headline)
                        ForEach(result.executablePaths, id: \.self) { path in
                            Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Text(result.detail).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let tools = model.developerTools {
                GroupBox("PHP 与扩展") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tools.phpVersion).font(.headline)
                        Text(tools.phpExecutable).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("已加载 \(tools.phpModules.count) 个模块")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(tools.phpModules.joined(separator: " · "))
                            .font(.caption).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("附加工具") {
                    VStack(alignment: .leading, spacing: 12) {
                        toolRow("Composer", version: tools.composerVersion, path: tools.composerExecutable, missing: "未安装；Composer 项目按钮会保持禁用")
                        toolRow("Perl / CGI", version: tools.perlVersion, path: tools.perlExecutable, missing: "未安装")
                        toolRow("ProFTPD", version: tools.proFTPDVersion, path: tools.proFTPDExecutable, missing: "未安装；本机开发通常不需要 FTP 服务器")
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func toolRow(_ name: String, version: String?, path: String?, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text(path == nil ? "不可用" : "可用")
                    .font(.caption.bold())
                    .foregroundStyle(path == nil ? Color.secondary : Color.teal)
            }
            Text(version ?? missing).font(.caption).foregroundStyle(.secondary)
            if let path { Text(path).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
        }
    }
}

#Preview("环境") {
    EnvironmentPage().environmentObject(AppModel())
}
