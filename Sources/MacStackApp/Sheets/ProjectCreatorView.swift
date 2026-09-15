import SwiftUI
import MacStackCore

struct ProjectCreatorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var parentPath = RuntimeLayout.applicationSupport().documentRoot.path
    @State private var createDatabase = true
    @State private var databaseName = ""
    @State private var localError: String?
    let onCreate: (String, String, String?, Bool) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("创建 PHP 项目").font(.title.bold())
            Text("创建独立项目骨架、可选 MariaDB 数据库，并自动登记为可访问网站。不会覆盖已有文件。")
                .foregroundStyle(.secondary)
            Form {
                TextField("项目名称", text: $name)
                LabeledContent("上级目录") {
                    HStack {
                        Text(parentPath).lineLimit(1).truncationMode(.middle)
                        Button("选择…") { chooseParent() }
                    }
                }
                Toggle("同时创建数据库", isOn: $createDatabase)
                if createDatabase {
                    TextField("数据库名称", text: $databaseName)
                }
            }.formStyle(.grouped)
            if let localError { Text(localError).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    localError = nil
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        localError = "请输入项目名称。"
                        return
                    }
                    if createDatabase && databaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        localError = "请输入数据库名称。"
                        return
                    }
                    Task {
                        if await onCreate(name, parentPath, createDatabase ? databaseName : nil, createDatabase) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.creatingProject)
                if model.creatingProject { ProgressView().controlSize(.small) }
            }
        }
        .padding(24)
        .frame(width: 680)
        .onChange(of: name) { _, value in
            if databaseName.isEmpty {
                let candidate = value.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
                if candidate.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil {
                    databaseName = candidate
                }
            }
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "选择项目上级目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: parentPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { parentPath = url.path }
    }
}


#Preview("创建 PHP 项目") {
    ProjectCreatorView { _, _, _, _ in true }.environmentObject(AppModel())
}
