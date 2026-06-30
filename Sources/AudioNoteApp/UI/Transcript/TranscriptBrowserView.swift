import SwiftUI
import AudioNoteCore

struct TranscriptBrowserView: View {
    @EnvironmentObject var scheduler: TaskScheduler
    @State private var searchText: String = ""
    @State private var selectedTask: UniTask?

    var completedWithTranscript: [UniTask] {
        scheduler.allTasks.filter { t in
            if case .completed = t.status { return true }
            return false
        }
    }

    var filtered: [UniTask] {
        if searchText.isEmpty { return completedWithTranscript }
        return completedWithTranscript.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索转写结果…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchText.isEmpty {
                    Button("清除") { searchText = "" }.buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Surface.textBg))

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36)).foregroundStyle(.quaternary)
                    Text(completedWithTranscript.isEmpty ? "暂无转写结果" : "无匹配结果").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(filtered) { task in
                    TranscriptRow(task: task, isSelected: selectedTask?.id == task.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTask = task }
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let task = selectedTask, let txtURL = task.transcriptURL, let text = try? String(contentsOf: txtURL, encoding: .utf8) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Text(task.title).font(.headline).lineLimit(1)
                        Spacer()
                        HStack(spacing: 8) {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([txtURL]) }
                                .buttonStyle(.borderless).font(.caption)
                            Button("复制全文") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                                .buttonStyle(.borderless).font(.caption)
                            Button("关闭") { selectedTask = nil }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    ScrollView {
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .frame(height: 250)
                .background(DS.Surface.controlBg)
            }
        }
        .background(DS.Surface.windowBg)
    }
}

struct TranscriptRow: View {
    @ObservedObject var task: UniTask
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayTitle).font(.system(size: DS.Font.primary, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(task.inputType.rawValue).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.quaternary))
                    Text("\(task.transcriptCharCount) 字").font(.caption2).foregroundStyle(.tertiary)
                    if let d = task.finishedAt {
                        Text(d.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.quaternary).opacity(isSelected ? 0 : 1)
        }
    }
}
