import SwiftUI
import MacStackCore

struct DatabasePage: View {
    @EnvironmentObject private var model: AppModel
    @State private var newDatabaseName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "数据库", subtitle: "管理 MacStack 独立的 MariaDB 数据目录；不会读取或初始化旧 XAMPP/MySQL 数据目录。")
            LabeledContent("预设地址", value: "127.0.0.1:\(model.settings.preferences.databasePort)")
            HStack {
                Button("准备数据库", systemImage: "externaldrive.badge.plus") {
                    Task { await model.prepareDatabaseEnvironment() }
                }.disabled(model.preparingDatabase || model.changingDatabase || model.databaseRunning)
                Button("启动", systemImage: "play.fill") {
                    Task { await model.startDatabase() }
                }.disabled(model.preparingDatabase || model.changingDatabase || model.databaseRunning)
                Button("停止", systemImage: "stop.fill") {
                    Task { await model.stopDatabase() }
                }.disabled(model.changingDatabase || !model.databaseRunning)
                if model.preparingDatabase || model.changingDatabase { ProgressView().controlSize(.small) }
            }
            Text(model.databaseStatus)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            HStack {
                Button("准备 phpMyAdmin", systemImage: "shippingbox") {
                    Task { await model.preparePHPMyAdmin() }
                }.disabled(model.preparingPHPMyAdmin || model.savingSettings || model.webServicesRunning)
                Button("打开 phpMyAdmin", systemImage: "safari") { model.openPHPMyAdmin() }
                    .disabled(!model.phpMyAdminPrepared || !model.webServicesRunning || !model.databaseRunning)
                Button("复制登录密码", systemImage: "key") {
                    Task { await model.copyDatabasePassword() }
                }
                if model.preparingPHPMyAdmin { ProgressView().controlSize(.small) }
            }
            Text("登录用户名：macstack。\n\(model.phpMyAdminStatus)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            GroupBox("创建数据库与连接代码") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("数据库名称，例如 course_site", text: $newDatabaseName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        Button("创建数据库", systemImage: "plus.circle") {
                            let name = newDatabaseName
                            Task {
                                if await model.createDatabase(named: name) { newDatabaseName = "" }
                            }
                        }
                        .disabled(newDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.changingDatabase)
                    }
                    Button("复制所选数据库的 PDO 模板", systemImage: "doc.on.doc") {
                        model.copyPDOConnectionTemplate()
                    }
                    .disabled(model.selectedDatabase.isEmpty)
                    Text("PDO 模板使用 127.0.0.1、当前端口、utf8mb4 和预处理语句；不会把钥匙串密码复制进源码。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            GroupBox("SQL 备份与恢复") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("业务数据库", selection: $model.selectedDatabase) {
                            if model.databases.isEmpty {
                                Text("没有可选数据库").tag("")
                            } else {
                                ForEach(model.databases, id: \.self) { Text($0).tag($0) }
                            }
                        }.frame(maxWidth: 420)
                        Button("刷新", systemImage: "arrow.clockwise") {
                            Task { await model.refreshDatabases() }
                        }
                    }
                    HStack {
                        Button("导出所选数据库…", systemImage: "square.and.arrow.up") {
                            Task { await model.exportSelectedDatabase() }
                        }.disabled(model.selectedDatabase.isEmpty || model.backingUpDatabase || model.restoringDatabase)
                        Button("恢复 SQL 备份…", systemImage: "square.and.arrow.down") {
                            Task { await model.restoreDatabaseBackup() }
                        }.disabled(model.restoringDatabase)
                        if model.restoringDatabase {
                            ProgressView(value: model.restoreProgress).frame(width: 120)
                            Text("\(Int(model.restoreProgress * 100))%").font(.caption.monospacedDigit())
                            Button("取消", role: .destructive) { model.cancelDatabaseRestore() }
                        }
                        if model.backingUpDatabase || model.restoringDatabase {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(model.databaseBackupStatus)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("导出包含表、数据、视图、触发器、事件和存储过程。恢复前会再次确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.databaseRunning || model.changingDatabase || model.savingSettings)
            GroupBox("备份历史与自动备份") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("立即备份全部数据库", systemImage: "clock.arrow.circlepath") {
                            Task { await model.runAutomaticBackupNow() }
                        }
                        .disabled(!model.databaseRunning || model.backingUpDatabase || model.restoringDatabase || model.savingSettings)
                        Button("打开备份文件夹", systemImage: "folder") { model.openBackupDirectory() }
                    }
                    Text(model.automaticBackupStatus).font(.caption).foregroundStyle(.secondary)
                    if model.backupRecords.isEmpty {
                        Text("还没有备份记录。").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.backupRecords.prefix(8))) { record in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(record.database).font(.headline)
                                    Text("\(record.automatic ? "自动" : "手动") · \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("显示") { model.revealBackup(record) }
                            }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#Preview("数据库") {
    DatabasePage().environmentObject(AppModel())
}
