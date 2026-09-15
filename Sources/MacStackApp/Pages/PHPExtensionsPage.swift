import SwiftUI
import MacStackCore

struct PHPExtensionsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "PHP 扩展", subtitle: "管理 MacStack 自己的动态 PHP 扩展；不会改动 Homebrew 的全局 php.ini。")
            HStack {
                Button("重新检测", systemImage: "arrow.clockwise") {
                    Task { await model.inspectDeveloperTools() }
                }
                .disabled(model.inspectingDeveloperTools || model.changingPHPExtension != nil)
                Button("打开配置文件夹", systemImage: "folder") {
                    model.openPHPExtensionConfigurationFolder()
                }
                if model.inspectingDeveloperTools || model.changingPHPExtension != nil {
                    ProgressView().controlSize(.small)
                }
            }
            Text(model.phpExtensionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let report = model.phpExtensionReport {
                GroupBox("可管理的动态扩展") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(report.extensions) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.status == .enabled ? "checkmark.circle.fill" : "puzzlepiece.extension")
                                    .foregroundStyle(item.status == .enabled ? Color.teal : Color.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.title).font(.headline)
                                        Text(item.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Text(item.purpose).font(.caption).foregroundStyle(.secondary)
                                    if let path = item.libraryPath {
                                        Text(path).font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 8) {
                                    Text(item.status.rawValue)
                                        .font(.caption.bold())
                                        .foregroundStyle(item.status == .enabled ? Color.teal : Color.secondary)
                                    switch item.status {
                                    case .enabled:
                                        Button("停用") {
                                            Task { await model.setPHPExtension(item, enabled: false) }
                                        }
                                    case .disabled:
                                        Button("启用") {
                                            Task { await model.setPHPExtension(item, enabled: true) }
                                        }
                                    case .notInstalled:
                                        if item.canInstall {
                                            Button("安装…") {
                                                Task { await model.installPHPExtension(item) }
                                            }
                                        }
                                    case .incompatible:
                                        EmptyView()
                                    }
                                }
                                .disabled(model.changingPHPExtension != nil || model.inspectingDeveloperTools || model.savingSettings)
                            }
                            .padding(.vertical, 12)
                            if item.id != report.extensions.last?.id { Divider() }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("PHP 内置扩展（始终可用）") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("这些功能已经编译进当前 PHP，不能也不需要单独安装或关闭。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(report.builtInModules.joined(separator: " · "))
                            .font(.caption).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("配置与安全") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("MacStack 扩展配置", value: report.configurationPath)
                        LabeledContent("自动备份目录", value: report.backupDirectoryPath)
                        Text("启用或停用前会先用临时候选配置启动 PHP 校验；只有校验成功才原子替换。Web 正在运行时会受控重启，启动失败则恢复上一份配置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !model.inspectingDeveloperTools {
                ContentUnavailableView(
                    "尚未取得扩展信息",
                    systemImage: "puzzlepiece.extension",
                    description: Text("确认已安装所选 PHP，然后点击重新检测。")
                )
            }
        }
    }
}

#Preview("PHP 扩展") {
    PHPExtensionsPage().environmentObject(AppModel())
}
