import SwiftUI
import MacStackCore

struct OverviewPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(title: "你的本地开发环境", subtitle: "从原生组件开始，逐步搭建属于你的 Mac 工作台。")
            HStack {
                Label("框架已就绪", systemImage: "square.stack.3d.up")
                Spacer()
                Text("安装检测 ≠ 服务运行状态").foregroundStyle(.secondary)
            }.padding(18).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            GroupBox("全部服务") {
                HStack(spacing: 12) {
                    Button("Start All", systemImage: "play.fill") {
                        Task { await model.startAllServices() }
                    }
                    .disabled(model.changingAllServices || model.savingSettings || (model.webServicesRunning && model.databaseRunning))
                    Button("Stop All", systemImage: "stop.fill") {
                        Task { await model.stopAllServices() }
                    }
                    .disabled(model.changingAllServices || model.savingSettings || (!model.webServicesRunning && !model.databaseRunning))
                    if model.changingAllServices { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("Web \(model.webServicesRunning ? "运行中" : "已停止") · 数据库 \(model.databaseRunning ? "运行中" : "已停止")")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            ForEach(model.inspections) { result in componentCard(result) }
            if model.scanning { ProgressView("正在读取本机组件…") }
            GroupBox("Apache + PHP-FPM 环境") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("生成 MacStack 专属配置并调用组件自带的语法检查。不会启动服务，不会修改 Homebrew 或旧 XAMPP 的默认配置。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("生成并校验配置", systemImage: "checkmark.shield") {
                            Task { await model.prepareWebEnvironment() }
                        }.disabled(model.preparingWebStack || model.savingSettings || model.changingWebServices || model.webServicesRunning)
                        if model.preparingWebStack || model.changingWebServices { ProgressView().controlSize(.small) }
                    }
                    Text(model.webStackStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Divider()
                    HStack {
                        Button("启动 Web 环境", systemImage: "play.fill") {
                            Task { await model.startWebServices() }
                        }.disabled(model.preparingWebStack || model.savingSettings || model.changingWebServices || model.webServicesRunning)
                        Button("停止", systemImage: "stop.fill") {
                            Task { await model.stopWebServices() }
                        }.disabled(model.savingSettings || model.changingWebServices || !model.webServicesRunning)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func componentCard(_ result: ComponentInspection) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: result.component == .mariadb ? "externaldrive" : "shippingbox")
                .font(.title2).foregroundStyle(.teal).frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(result.component.title).font(.headline)
                Text(result.component.purpose).font(.subheadline).foregroundStyle(.secondary)
                Text(result.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Text(result.status.rawValue).font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background((result.status == .appleSilicon ? Color.teal : Color.secondary).opacity(0.12), in: Capsule())
                Text(serviceText(for: result.component))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func serviceText(for component: Component) -> String {
        switch component {
        case .apache, .php: model.webServicesRunning ? "服务：运行中" : "服务：已停止"
        case .mariadb: model.databaseRunning ? "服务：运行中" : "服务：已停止"
        }
    }
}

#Preview("总览") {
    OverviewPage().environmentObject(AppModel())
}
