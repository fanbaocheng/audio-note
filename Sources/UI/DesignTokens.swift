import SwiftUI

/// 统一设计令牌 — 所有 UI 组件取值入口
enum DS {
    enum Surface {
        static let windowBg    = Color(NSColor.windowBackgroundColor)
        static let controlBg   = Color(NSColor.controlBackgroundColor)
        static let textBg      = Color(NSColor.textBackgroundColor)
        static let separator   = Color(NSColor.separatorColor)
        static let quaternary  = Color(NSColor.quaternaryLabelColor)
    }

    enum Status {
        static let downloading = Color.blue
        static let transcribing = Color.indigo
        static let recording   = Color.red
        static let success     = Color.green
        static let warning     = Color.orange
        static let failure     = Color.red
    }

    enum Opacity {
        static let cardHover: Double = 0.04
        static let cardBg: Double = 0.06
        static let cardBorder: Double = 0.25
        static let badgeBg: Double = 0.15
        static let progressTrack: Double = 0.15
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 5
        static let md: CGFloat = 7
        static let lg: CGFloat = 8
    }

    enum Font {
        static let primary: CGFloat = 13
        static let secondary: CGFloat = 11
        static let micro: CGFloat = 10
    }

    enum Row {
        static let minHeight: CGFloat = 52
        static let minHeightWithProgress: CGFloat = 66
    }

    enum ProgressBar {
        static let height: CGFloat = 6
        static let cornerRadius: CGFloat = 3
    }
}

// MARK: - 通用组件

struct DSProgressBar: View {
    let value: Double
    var tint: Color = DS.Status.downloading

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DS.ProgressBar.cornerRadius)
                    .fill(tint.opacity(DS.Opacity.progressTrack))
                RoundedRectangle(cornerRadius: DS.ProgressBar.cornerRadius)
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * CGFloat(max(0, min(1, value)))))
            }
        }
        .frame(height: DS.ProgressBar.height)
    }
}

struct DSBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: DS.Font.micro, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(DS.Opacity.badgeBg)))
            .foregroundStyle(tint)
    }
}

struct DSTaskRowBg: View {
    let tint: Color
    let isError: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.lg)
            .fill(isError ? tint.opacity(DS.Opacity.cardBg) : DS.Surface.controlBg)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(tint.opacity(DS.Opacity.cardBorder), lineWidth: 1))
    }
}
