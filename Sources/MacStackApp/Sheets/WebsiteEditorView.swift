import SwiftUI
import MacStackCore

struct WebsiteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var website: Website
    @State private var portText: String
    @State private var localError: String?
    let onSave: (Website) -> Void

    init(website: Website, onSave: @escaping (Website) -> Void) {
        _website = State(initialValue: website)
        _portText = State(initialValue: String(website.port))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑网站").font(.title.bold())
            Form {
                TextField("名称", text: $website.name)
                LabeledContent("项目目录", value: website.rootPath)
                TextField("公开目录", text: $website.publicRootPath)
                TextField("本地域名（可选）", text: $website.hostname, prompt: Text("my-site.localhost"))
                TextField("HTTP 端口", text: $portText)
            }.formStyle(.grouped)
            HStack {
                Button("选择公开目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: website.rootPath, isDirectory: true)
                    if panel.runModal() == .OK, let url = panel.url { website.publicRootPath = url.path }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    guard let port = Int(portText) else {
                        localError = "端口必须是整数。"
                        return
                    }
                    website.port = port
                    onSave(website)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
            if let localError { Text(localError).foregroundStyle(.red).font(.caption) }
        }.padding(24).frame(width: 620)
    }
}


#Preview("编辑网站") {
    WebsiteEditorView(
        website: Website(name: "示例站点", rootPath: "/tmp/example", port: 8081, isEnabled: true)
    ) { _ in }
}
