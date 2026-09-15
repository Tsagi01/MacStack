import SwiftUI
import MacStackCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var httpPort = "8080"
    @State private var databasePort = "3307"
    @State private var restoreLastSession = true
    @State private var autoStartWeb = false
    @State private var autoStartDatabase = false
    @State private var automaticBackupEnabled = false
    @State private var backupIntervalHours = "24"
    @State private var backupRetentionDays = "30"
    @State private var preferredPHPFormula = "auto"
    @State private var httpsEnabled = false
    @State private var httpsPort = "8443"
    @State private var perlCGIEnabled = false
    @State private var allowHtaccess = true
    @State private var allowHtaccessOptions = false
    @State private var phpTimezone = ""
    @State private var memoryLimitMB = "512"
    @State private var uploadMaxFilesizeMB = "64"
    @State private var postMaxSizeMB = "80"
    @State private var expiresEnabled = false
    @State private var deflateEnabled = false
    @State private var autoindexEnabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("环境预设").font(.largeTitle.bold())
            Text("保存端口、启动方式、PHP、HTTPS、CGI 与备份预设；运行服务时会暂时禁用修改。")
                .foregroundStyle(.secondary)
            GroupBox {
                Form {
                    TextField("HTTP 端口", text: $httpPort)
                    TextField("数据库端口", text: $databasePort)
                    Toggle("恢复上次运行状态", isOn: $restoreLastSession)
                    Toggle("每次打开 MacStack 都启动 Web", isOn: $autoStartWeb)
                    Toggle("每次打开 MacStack 都启动数据库", isOn: $autoStartDatabase)
                    Picker("PHP 版本", selection: $preferredPHPFormula) {
                        Text("自动选择").tag("auto")
                        Text("PHP 8.2").tag("php@8.2")
                        Text("PHP 8.3").tag("php@8.3")
                        Text("PHP 8.4").tag("php@8.4")
                        Text("PHP 8.5").tag("php@8.5")
                        Text("Homebrew 默认 PHP").tag("php")
                    }
                    Toggle("启用本地 HTTPS", isOn: $httpsEnabled)
                    if httpsEnabled {
                        TextField("HTTPS 端口", text: $httpsPort)
                    }
                    Toggle("启用 Perl / CGI（高级）", isOn: $perlCGIEnabled)
                    Toggle("启用自动数据库备份", isOn: $automaticBackupEnabled)
                    if automaticBackupEnabled {
                        TextField("备份间隔（小时）", text: $backupIntervalHours)
                        TextField("自动备份保留天数（0 表示不清理）", text: $backupRetentionDays)
                        Text("只清理自动备份；手工导出的备份不会被删除。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("网站兼容性").font(.callout).foregroundStyle(.secondary)
                    Toggle("允许站点使用 .htaccess", isOn: $allowHtaccess)
                    if allowHtaccess {
                        Text("放开 FileInfo、Indexes、AuthConfig、Limit 四类覆盖，伪静态、站点认证与目录首页可正常工作。不含 Options，因此站点无法通过 .htaccess 推翻 MacStack 的符号链接与目录列表策略。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("允许 .htaccess 覆盖 Options（高级）", isOn: $allowHtaccessOptions)
                        Text("开启后站点可以自行调整符号链接与目录列表策略，会放宽现有默认。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("按需加载的可选 Apache 模块")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("expires（.htaccess 可设置缓存头）", isOn: $expiresEnabled)
                    Toggle("deflate（.htaccess 可启用压缩）", isOn: $deflateEnabled)
                    Toggle("autoindex（.htaccess 可用 IndexOptions）", isOn: $autoindexEnabled)
                    Divider()
                    Text("PHP 运行时").font(.callout).foregroundStyle(.secondary)
                    TextField("PHP 时区（留空跟随系统）", text: $phpTimezone)
                    TextField("memory_limit（MB）", text: $memoryLimitMB)
                    TextField("upload_max_filesize（MB）", text: $uploadMaxFilesizeMB)
                    TextField("post_max_size（MB，必须大于上传上限）", text: $postMaxSizeMB)
                }.padding().frame(maxWidth: 500)
            }
            Button("保存预设") {
                guard let http = Int(httpPort), let database = Int(databasePort), let https = Int(httpsPort),
                      let interval = Int(backupIntervalHours),
                      let retention = Int(backupRetentionDays),
                      let memory = Int(memoryLimitMB), let upload = Int(uploadMaxFilesizeMB),
                      let post = Int(postMaxSizeMB) else {
                    model.message = "端口、备份间隔和 PHP 限制必须是整数。"; return
                }
                var next = model.settings
                next.preferences.httpPort = http
                next.preferences.databasePort = database
                next.preferences.restoreLastSession = restoreLastSession
                next.preferences.autoStartWeb = autoStartWeb
                next.preferences.autoStartDatabase = autoStartDatabase
                next.preferences.preferredPHPFormula = preferredPHPFormula
                next.preferences.automaticBackupEnabled = automaticBackupEnabled
                next.preferences.backupIntervalHours = interval
                next.preferences.backupRetentionDays = retention
                next.preferences.httpsEnabled = httpsEnabled
                next.preferences.httpsPort = https
                next.preferences.perlCGIEnabled = perlCGIEnabled
                next.preferences.allowHtaccess = allowHtaccess
                next.preferences.allowHtaccessOptions = allowHtaccessOptions
                next.preferences.phpTimezone = phpTimezone
                next.preferences.memoryLimitMB = memory
                next.preferences.uploadMaxFilesizeMB = upload
                next.preferences.postMaxSizeMB = post
                // 排序归一化：让「是否变更」的判断不受界面勾选顺序影响。
                var modules: [String] = []
                if expiresEnabled { modules.append("expires") }
                if deflateEnabled { modules.append("deflate") }
                if autoindexEnabled { modules.append("autoindex") }
                next.preferences.optionalApacheModules = modules.sorted()
                Task { await model.save(next) }
            }.disabled(!model.canSave || model.savingSettings || model.webServicesRunning || model.changingWebServices || model.databaseRunning || model.changingDatabase)
            if httpsEnabled {
                Button("把本地证书加入登录钥匙串…", systemImage: "lock.shield") {
                    Task { await model.trustLocalCertificate() }
                }
                Text(model.tlsStatus).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("本地配置文件").font(.headline)
            Text(model.store.fileURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("首次保存预设或登记网站时创建。配置出错时会保留原文件并禁用保存。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            httpPort = String(model.settings.preferences.httpPort)
            databasePort = String(model.settings.preferences.databasePort)
            restoreLastSession = model.settings.preferences.restoreLastSession
            autoStartWeb = model.settings.preferences.autoStartWeb
            autoStartDatabase = model.settings.preferences.autoStartDatabase
            preferredPHPFormula = model.settings.preferences.preferredPHPFormula
            automaticBackupEnabled = model.settings.preferences.automaticBackupEnabled
            backupIntervalHours = String(model.settings.preferences.backupIntervalHours)
            backupRetentionDays = String(model.settings.preferences.backupRetentionDays)
            httpsEnabled = model.settings.preferences.httpsEnabled
            httpsPort = String(model.settings.preferences.httpsPort)
            perlCGIEnabled = model.settings.preferences.perlCGIEnabled
            allowHtaccess = model.settings.preferences.allowHtaccess
            allowHtaccessOptions = model.settings.preferences.allowHtaccessOptions
            phpTimezone = model.settings.preferences.phpTimezone
            memoryLimitMB = String(model.settings.preferences.memoryLimitMB)
            uploadMaxFilesizeMB = String(model.settings.preferences.uploadMaxFilesizeMB)
            postMaxSizeMB = String(model.settings.preferences.postMaxSizeMB)
            let modules = model.settings.preferences.optionalApacheModules
            expiresEnabled = modules.contains("expires")
            deflateEnabled = modules.contains("deflate")
            autoindexEnabled = modules.contains("autoindex")
        }
    }
}


#Preview("设置") {
    SettingsView().environmentObject(AppModel())
}
