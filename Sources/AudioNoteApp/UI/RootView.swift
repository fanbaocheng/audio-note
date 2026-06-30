import SwiftUI
import AudioNoteCore
import AppKit

/// 侧边栏导航选项
enum SidebarItem: String, CaseIterable, Identifiable {
    case record     = "录制"
    case download   = "下载"
    case transcript = "转写"
    case queue      = "任务"

    var id: String { rawValue }

    /// 填充版 SF Symbol — 配合彩色 tint 显示
    var icon: String {
        switch self {
        case .download:   return "arrow.down.circle.fill"
        case .record:     return "mic.circle.fill"
        case .transcript: return "doc.text.fill"
        case .queue:      return "list.bullet.rectangle.fill"
        }
    }

    /// 每个导航项的品牌色（选中/未选中都保持，选中时由系统反白文字，图标颜色保留）
    var tint: Color {
        switch self {
        case .download:   return Color(red: 0.23, green: 0.51, blue: 0.96)   // #3B82F6 蓝
        case .record:     return Color(red: 0.94, green: 0.27, blue: 0.27)   // #EF4444 红
        case .transcript: return Color(red: 0.55, green: 0.36, blue: 0.97)   // #8B5CF6 紫
        case .queue:      return Color(red: 0.96, green: 0.62, blue: 0.04)   // #F59E0B 橙
        }
    }
}

/// 根视图：左侧 Source List + 右侧内容区（底部状态栏 + Settings 入口）
struct RootView: View {
    @State private var selectedItem: SidebarItem = .record
    @EnvironmentObject var scheduler: TaskScheduler
    @EnvironmentObject var recorder: AudioCaptureEngine
    @EnvironmentObject var asr: ASRService

    /// 进行中的任务数（pending / downloading / transcribing / 各种 paused 等都算）
    private var activeTaskCount: Int {
        scheduler.allTasks.filter { t in
            if case .completed = t.status { return false }
            if case .failed = t.status { return false }
            if case .cancelled = t.status { return false }
            return true
        }.count
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedItem) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(item.tint)
                        .frame(width: 22, height: 22)
                    Text(item.rawValue)
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                    if item == .queue && activeTaskCount > 0 {
                        Text("\(activeTaskCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.red)
                            )
                            .frame(minWidth: 18)
                    }
                }
                .padding(.vertical, 7)
                .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            ZStack(alignment: .bottom) {
                // 内容区：自身充满，底部留出 statusBar 的高度，避免布局耦合
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, statusBarHeight)

                // 底部 statusBar：固定高度 + 浮在内容上方，不参与 detail 主布局，
                // 因此 sidebar 折叠/展开时 detail 区不会因 Divider/HStack 重排而抖动
                statusBar
                    .frame(height: statusBarHeight)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                    }
            }
            .navigationTitle(selectedItem.rawValue)
        }
        .onAppear {
            Logger.app.info("RootView 就绪", metadata: ["selectedTab": selectedItem.rawValue])
        }
    }

    private let statusBarHeight: CGFloat = 30

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch selectedItem {
        case .download:
            DownloadView()
        case .record:
            RecordView()
        case .transcript:
            TranscriptBrowserView()
        case .queue:
            TaskQueueView()
        }
    }

    // MARK: - Bottom Status Bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            statusItem(icon: "arrow.down.circle.fill",
                       tint: .blue,
                       label: "下载中",
                       count: scheduler.downloadingTasks.count)
            statusItem(icon: "text.quote",
                       tint: .indigo,
                       label: "转写中",
                       count: scheduler.transcribingTasks.count)
            statusItem(icon: "checkmark.circle.fill",
                       tint: .green,
                       label: "已完成",
                       count: scheduler.completedTasks.count)

            Spacer()

            settingsButton
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }

    private func statusItem(icon: String, tint: Color, label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(label)
            Text("\(count)").monospacedDigit().foregroundStyle(.primary)
        }
    }

    /// 设置按钮：优先用 SwiftUI 原生 SettingsLink（macOS 14+），
    /// 旧系统回退到 NSApplication selector（先激活 app 再发送，确保 responder chain 收到）。
    /// 点击后通过 simultaneousGesture 触发"将 Settings 窗口居中到主窗口"。
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")
            .simultaneousGesture(TapGesture().onEnded {
                SettingsWindowPositioner.scheduleCenterOnMainWindow()
            })
        } else {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                SettingsWindowPositioner.scheduleCenterOnMainWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }
}

/// Settings 窗口定位辅助：在 SettingsLink/selector 触发后，
/// 延迟若干 tick 等系统创建出 Settings 窗口，再把它居中到当前主窗口。
///
/// 为什么这么做：SwiftUI 的 `Settings { }` scene 由系统管理，
/// 内部 View 感知不到自己被装在哪个 NSWindow 里、也无权在 will-show 时定位。
/// 唯一可靠路径是外部在点击瞬间记下"参考窗口"，然后 polling 等新窗口出现并对齐。
enum SettingsWindowPositioner {
    /// 在点击 Settings 入口后调用。会捕获当前主窗口的 frame 作为参考，
    /// 然后用一个短轮询找到新出现的 Settings 窗口并居中。
    @MainActor
    static func scheduleCenterOnMainWindow() {
        // 1. 记录"已存在"的窗口集合 + 主窗口 frame
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let referenceFrame: NSRect? = {
            // 优先取 key window；其次取第一个可见的主窗口（排除 panel/utility）
            if let key = NSApp.keyWindow, key.isVisible, !key.title.contains("Settings"),
               !key.title.contains("设置") {
                return key.frame
            }
            return NSApp.windows.first {
                $0.isVisible &&
                $0.styleMask.contains(.titled) &&
                !$0.title.contains("Settings") &&
                !$0.title.contains("设置")
            }?.frame
        }()

        guard let refFrame = referenceFrame else { return }

        // 2. 轮询找新窗口（最多 1s, 每 50ms 一次）
        var attempts = 0
        let maxAttempts = 20
        func tryLocate() {
            attempts += 1
            let newWindow = NSApp.windows.first { win in
                guard win.isVisible else { return false }
                let id = ObjectIdentifier(win)
                if existing.contains(id) { return false }
                // SwiftUI Settings scene 创建的窗口 identifier 通常是 "com_apple_SwiftUI_Settings_window"
                // 或 title 含 "Settings/设置/Preferences"。两个条件都看一下。
                let idStr = win.identifier?.rawValue ?? ""
                if idStr.contains("Settings") || idStr.contains("Preferences") { return true }
                if win.title.contains("设置") || win.title.contains("Settings") || win.title.contains("Preferences") {
                    return true
                }
                // 兜底：新出现的、不是 main 的 titled 窗口
                return win.styleMask.contains(.titled)
            }

            if let win = newWindow {
                let size = win.frame.size
                let originX = refFrame.midX - size.width / 2
                let originY = refFrame.midY - size.height / 2
                win.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height),
                             display: true,
                             animate: false)
                Logger.app.info("Settings 窗口已居中到主窗口", metadata: [
                    "x": "\(Int(originX))", "y": "\(Int(originY))"
                ])
                return
            }

            if attempts < maxAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tryLocate() }
            } else {
                Logger.app.warn("未能定位 Settings 窗口，跳过居中")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tryLocate() }
    }
}
