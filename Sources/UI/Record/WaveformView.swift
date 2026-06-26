import SwiftUI

/// 实时波形：镜像对称 + 渐变填充 + 圆角竖条
/// 待机时显示扁平基线，录制中根据 rmsHistory 绘制对称波形。
struct WaveformView: View {
    @Binding var rmsHistory: [Float]
    var isActive: Bool = true
    private let maxBars = 64

    var body: some View {
        Canvas { context, size in
            let totalSlots = CGFloat(maxBars)
            let barWidth = size.width / totalSlots * 0.6
            let gap = size.width / totalSlots * 0.4
            let midY = size.height / 2
            let maxHalfHeight = size.height / 2 - 2

            let bars = Array(rmsHistory.suffix(maxBars))
            let displayCount = max(bars.count, maxBars)

            // 渐变色：从静默灰 → 蓝紫 → 橙红（按振幅）
            for i in 0..<displayCount {
                let rms: Float = i < bars.count ? bars[i] : 0
                // 振幅映射：rms 范围一般 0~0.5，乘以放大系数
                let amplitude = min(CGFloat(rms) * 6.0, 1.0)
                let h = max(amplitude * maxHalfHeight, 1.5)
                let x = CGFloat(i) * (barWidth + gap)
                let rect = CGRect(x: x, y: midY - h, width: barWidth, height: h * 2)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                // 振幅越高颜色越暖
                let color: Color
                if !isActive {
                    color = Color.gray.opacity(0.25)
                } else if amplitude < 0.15 {
                    color = Color(red: 0.45, green: 0.55, blue: 0.95).opacity(0.55) // 蓝紫
                } else if amplitude < 0.5 {
                    color = Color(red: 0.35, green: 0.75, blue: 0.55) // 青绿
                } else {
                    color = Color(red: 1.0, green: 0.55, blue: 0.2) // 橙
                }
                context.fill(path, with: .color(color))
            }

            // 中线 baseline
            let baseline = Path { p in
                p.move(to: CGPoint(x: 0, y: midY))
                p.addLine(to: CGPoint(x: size.width, y: midY))
            }
            context.stroke(baseline, with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.08), value: rmsHistory.count)
    }
}
