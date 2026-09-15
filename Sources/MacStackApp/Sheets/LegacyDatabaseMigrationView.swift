import SwiftUI
import MacStackCore

struct LegacyDatabaseMigrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var port = "3306"
    @State private var username = "root"
    @State private var password = ""

    private var credentials: LegacyDatabaseCredentials? {
        guard let value = Int(port) else { return nil }
        return LegacyDatabaseCredentials(port: value, username: username, password: password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("迁移旧 XAMPP 数据库").font(.title.bold())
            Text("先只读连接旧数据库并列出业务库，再由你逐个确认复制。密码仅在本次操作中使用，不会保存。")
                .foregroundStyle(.secondary)
            Form {
                TextField("旧数据库端口", text: $port)
                TextField("用户名", text: $username)
                SecureField("密码（XAMPP 默认可能为空）", text: $password)
            }.formStyle(.grouped)
            HStack {
                Button("连接并列出数据库", systemImage: "magnifyingglass") {
                    guard let credentials else { return }
                    Task { _ = await model.listLegacyDatabases(credentials: credentials) }
                }
                .disabled(credentials == nil || model.checkingLegacyDatabase || model.migratingLegacyDatabase != nil)
                if model.checkingLegacyDatabase { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text(model.legacyDatabaseStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.legacyDatabases.isEmpty {
                Text("还没有读取到业务数据库。").foregroundStyle(.secondary)
            } else {
                List(model.legacyDatabases, id: \.self) { database in
                    HStack {
                        Image(systemName: "cylinder")
                        Text(database)
                        Spacer()
                        Button("复制到 MacStack") {
                            guard let credentials else { return }
                            Task { _ = await model.migrateLegacyDatabase(named: database, credentials: credentials) }
                        }
                        .disabled(model.migratingLegacyDatabase != nil)
                    }
                }.frame(minHeight: 180)
            }
            if model.migratingLegacyDatabase != nil {
                HStack {
                    ProgressView(value: model.restoreProgress).frame(width: 220)
                    Text("\(Int(model.restoreProgress * 100))%").font(.caption.monospacedDigit())
                    Button("取消导入", role: .destructive) { model.cancelDatabaseRestore() }
                }
            }
        }.padding(24).frame(width: 720, height: 600)
    }
}

#Preview("迁移旧数据库") {
    LegacyDatabaseMigrationView().environmentObject(AppModel())
}
