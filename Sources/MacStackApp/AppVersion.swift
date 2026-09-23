import Foundation

/// 应用版本号的唯一来源。
///
/// 之前界面里硬编码了 `Text("0.10.0 · ...")`，与 `Resources/Info.plist` 的
/// `CFBundleShortVersionString` 各写一份，两者必然会漂移。这里统一从包元数据读取。
///
/// 用 `swift run` 直接跑（没有 app bundle）时读不到 Info.plist，此时返回
/// 「开发构建」而不是编一个版本号——宁可显示得朴素，也不显示一个可能是错的版本。
enum AppVersion {
    /// 纯版本号（`CFBundleShortVersionString`），用于与线上版本**比较**。
    ///
    /// 与 `display` 分开：`display` 带「(build 15)」这类后缀，拿去比版本会解析失败。
    /// 用 `swift run` 直接跑（没有 app bundle）时返回 nil。
    static var marketing: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static var display: String {
        let short = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !short.isEmpty else { return "开发构建" }

        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return build.isEmpty ? short : "\(short) (build \(build))"
    }
}
