import AppKit
import UndertoneCore
import SwiftUI

/// 手动模式：把聊天记录粘贴进来分析，不用截屏，也不用开着聊天软件。
struct ManualView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    @Binding var transcript: String
    /// 预览渲染时用普通文字代替输入框（系统输入框画不出来）。
    var editable = true

    private var parsed: ChatTranscript.Parsed { ChatTranscript.parse(transcript) }
    private var latest: ChatMessage? { parsed.messages.last { $0.speaker == .them } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(symbol: "doc.on.clipboard", title: L("粘贴聊天记录", "Paste a chat")) {
                if !parsed.messages.isEmpty {
                    let theirs = parsed.messages.filter { $0.speaker == .them }.count
                    Text(L("\(parsed.messages.count) 条 · 对方 \(theirs) 条", parsed.messages.count == 1 ? "1 message · \(theirs) from them" : "\(parsed.messages.count) messages · \(theirs) from them"))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            editor
            if transcript.isEmpty {
                Text(L("也可以直接粘贴或拖进一张聊天、邮件截图，在本机识别。\n在聊天软件里选中几条消息复制，粘贴到这里。支持「John: 内容」和「John — Today at 9:40 PM」换行两种格式；认不出名字的行会算作对方说的。",
                       "You can also paste or drop a screenshot of a chat or an email; it's read on this Mac.\nCopy a few messages from your messaging app and paste them here. Works with \"John: message\", \"John — Today at 9:40 PM\" on its own line, and \"[10/3/26, 9:40 PM] John: message\" exports. Lines without a name count as theirs."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if latest == nil {
                Text(L("没找到对方发的消息。如果整段都是你自己说的，就没什么可分析的。", "No messages from them found. If it's all you talking, there's nothing to analyze."))
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            controls
        }
        .padding(12)
        .card()
    }

    @ViewBuilder private var editor: some View {
        if editable {
            textEditor
                .overlay {
                    if monitor.readingScreenshot {
                        HStack(spacing: 6) { Spinner(size: 11); Text(L("正在识别截图…", "Reading the screenshot…")).font(.system(size: 12)) }
                            .padding(8).background(.regularMaterial, in: Capsule())
                    }
                }
                // 把截图拖进来也行
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    Self.loadImage(from: providers) { image in monitor.analyzeScreenshot(image) }
                    return true
                }
        } else {
            textEditor
        }
    }

    @ViewBuilder private var textEditor: some View {
        if editable {
            TextEditor(text: $transcript)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        } else {
            Text(transcript.isEmpty ? " " : transcript)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button(L("粘贴", "Paste")) {
                // 剪贴板里是图片（截图）就识别图片，否则粘贴文字
                if let image = Self.image(from: NSPasteboard.general) {
                    monitor.analyzeScreenshot(image)
                } else {
                    transcript = NSPasteboard.general.string(forType: .string) ?? transcript
                }
            }
            .buttonStyle(PillButtonStyle())
            .help(L("粘贴文字，或者粘贴一张聊天、邮件截图", "Paste text, or a screenshot of a chat or email"))
            if !transcript.isEmpty {
                Button(L("清空", "Clear")) { transcript = "" }.buttonStyle(PillButtonStyle(tint: .secondary))
            }
            if parsed.names.count > 1 {
                Picker("", selection: Binding(get: { monitor.manualContact ?? parsed.names[0] },
                                              set: { monitor.manualContact = $0 })) {
                    ForEach(parsed.names, id: \.self) { Text(L("对方：\($0)", "Them: \($0)")).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 130)
            }
            Spacer()
            Button(monitor.analyzing ? L("分析中…", "Analyzing…") : L("分析这段", "Analyze")) {
                monitor.manualContact = monitor.manualContact ?? parsed.names.first
                monitor.analyzeManual(transcript)
            }
            .buttonStyle(PillButtonStyle(filled: true))
            .disabled(latest == nil || monitor.analyzing)
        }
    }
}

extension ManualView {
    static func image(from pasteboard: NSPasteboard) -> CGImage? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func loadImage(from providers: [NSItemProvider], then handle: @escaping @MainActor (CGImage) -> Void) {
        guard let provider = providers.first else { return }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                var rect = CGRect(origin: .zero, size: image.size)
                guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
                Task { @MainActor in handle(cg) }
            }
        }
    }
}

/// 顶部的「实时 / 手动」切换。
struct ModeSwitch: View {
    @ObservedObject var monitor: Monitor
    @Binding var manual: Bool

    var body: some View {
        HStack(spacing: 4) {
            tab(L("实时看聊天", "Live"), symbol: "eye", selected: !manual) {
                manual = false
                monitor.start()
            }
            tab(L("手动粘贴", "Paste"), symbol: "doc.on.clipboard", selected: manual) {
                manual = true
                monitor.pause()   // 手动模式不截屏
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func tab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.09) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
