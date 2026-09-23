import SwiftUI
import AppKit
import MacStackCore

@MainActor
final class MacStackAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var finishingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, model.hasCriticalOperation {
            model.message = "正在执行数据库、项目或组件任务。请等待完成，或先取消可取消的操作，再退出 MacStack。"
            return .terminateCancel
        }
        guard !finishingTermination, let model,
              model.webServicesRunning || model.databaseRunning else { return .terminateNow }
        finishingTermination = true
        Task {
            await model.stopAllServicesForTermination()
            let stopped = !model.webServicesRunning && !model.databaseRunning
            if !stopped { finishingTermination = false }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}

@main
struct MacStackApp: App {
    @NSApplicationDelegateAdaptor(MacStackAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // 尽早建立信号基线：默认处置下，向读端已关闭的管道写入会**直接杀死进程**，
        // 代码里的 catch 根本没机会执行。恢复数据库备份时会踩到（见
        // ProcessSignalBaseline.ignoreSIGPIPE 的说明）。
        ProcessSignalBaseline.ignoreSIGPIPE()
    }
    var body: some Scene {
        WindowGroup("MacStack") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
                .task { await model.launch() }
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加网站目录…") { model.addWebsite() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.canSave)
            }
        }
    }
}
