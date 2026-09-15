import SwiftUI
import MacStackCore

private enum Page: String, CaseIterable, Identifiable {
    case overview = "总览", websites = "网站", database = "数据库", extensions = "PHP 扩展"
    case migration = "迁移", logs = "日志", environment = "环境", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .websites: "globe"
        case .database: "externaldrive"
        case .extensions: "puzzlepiece.extension"
        case .migration: "arrow.right.doc.on.clipboard"
        case .logs: "text.alignleft"
        case .environment: "cpu"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Page? = .overview

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").font(.title).foregroundStyle(.teal)
                    VStack(alignment: .leading) {
                        Text("MacStack").font(.title3.bold())
                        Text("本地 Web 工作台").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 14).padding(.top, 20)
                List(Page.allCases, selection: $selection) { page in
                    Label(page.rawValue, systemImage: page.icon).tag(page)
                }.listStyle(.sidebar)
                Text("\(AppVersion.display) · 便携运行时\n原生 Apple Silicon")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(16)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 215)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selection ?? .overview {
                    case .overview: OverviewPage()
                    case .websites: WebsitesPage()
                    case .database: DatabasePage()
                    case .extensions: PHPExtensionsPage()
                    case .migration: MigrationPage()
                    case .logs: LogsPage()
                    case .environment: EnvironmentPage()
                    case .settings: SettingsView()
                    }
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle((selection ?? .overview).rawValue)
                .toolbar {
                    Button {
                        Task { await model.inspect() }
                    } label: { Label("重新检测", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning)
                }
        }
        .tint(.teal)
        .alert("MacStack", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

#Preview {
    ContentView().environmentObject(AppModel())
}
