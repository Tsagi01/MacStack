import SwiftUI
import MacStackCore

struct LogsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "应用活动", subtitle: "这里显示本次打开后的操作；Apache 与 PHP-FPM 的完整日志保存在 MacStack runtime/logs。")
            Button("在 Finder 中打开服务日志") {
                model.reveal(RuntimeLayout.applicationSupport().logDirectory.path)
            }
            Button("立即整理日志", systemImage: "arrow.triangle.2.circlepath") {
                model.rotateLogsNow()
            }
            .disabled(model.webServicesRunning || model.databaseRunning)
            Text("单个日志达到 5 MB 时自动轮转，保留最近 3 份；也可以在全部服务停止时手动整理。")
                .font(.caption).foregroundStyle(.secondary)
            if model.activities.isEmpty { Text("暂无活动。").foregroundStyle(.secondary) }
            ForEach(Array(model.activities.enumerated()), id: \.offset) { _, text in
                Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Divider()
            }
        }
    }
}

#Preview("日志") {
    LogsPage().environmentObject(AppModel())
}
