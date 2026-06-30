import Foundation

/// 共享 UserDefaults 域：GUI 和 CLI 必须读写同一份配置。
///
/// 之所以不能用 `UserDefaults.standard`：
/// - GUI .app 进程的 standard 落到 `com.ryanfan.audionote.plist`
/// - CLI 进程的 standard 落到可执行文件名（"audio-note"）
/// 两者天然不一致。
///
/// 通过显式 suite 强制统一。SwiftUI 里 `@AppStorage(... , store: AppDefaults.shared)` 同理。
public enum AppDefaults {
    /// 与 GUI bundle identifier 保持一致，落到 `~/Library/Preferences/com.ryanfan.audionote.plist`
    public static let suiteName = "com.ryanfan.audionote"

    public static let shared: UserDefaults = {
        if let ud = UserDefaults(suiteName: suiteName) {
            return ud
        }
        // 极端情况兜底
        return UserDefaults.standard
    }()
}
