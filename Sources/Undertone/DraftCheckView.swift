import AppKit
import UndertoneCore
import SwiftUI

/// 「发之前看看」：把要发的英文回复贴进来，看对方读起来是什么感觉，再给一个更地道的写法。
struct DraftCheckView: View {
    @ObservedObject var monitor: Monitor
    /// 预览渲染时用普通文字代替输入框（系统输入框画不出来）。
    var editable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle(symbol: "pencil.and.outline", title: L("发之前看看", "Check before you send"), tint: Theme.care)
            editor
            HStack(spacing: 6) {
                if !monitor.draft.isEmpty {
                    Button(L("清空", "Clear")) { monitor.clearDraft() }.buttonStyle(PillButtonStyle(tint: .secondary))
                }
                Spacer()
                if monitor.checkingDraft { Spinner(size: 11) }
                Button(monitor.checkingDraft ? L("正在看…", "Checking…") : L("帮我看看", "Check it")) { monitor.checkDraft() }
                    .buttonStyle(PillButtonStyle(filled: true))
                    .disabled(monitor.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || monitor.checkingDraft)
            }
            if let error = monitor.draftError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let review = monitor.draftReview, review.draft == monitor.draft.trimmingCharacters(in: .whitespacesAndNewlines) {
                DraftReviewResult(review: review)
            }
        }
        .padding(12)
        .card(tint: Theme.care)
    }

    @ViewBuilder private var editor: some View {
        if editable {
            ZStack(alignment: .topLeading) {
                if monitor.draft.isEmpty {
                    Text(L("把你想回的英文写在这里，发出去之前先看看对方读起来是什么感觉",
                           "Type the reply you're about to send to see how it will come across"))
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $monitor.draft)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(6)
            }
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        } else {
            Text(monitor.draft.isEmpty ? " " : monitor.draft)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}

struct DraftReviewResult: View {
    let review: DraftReview

    private var fine: Bool { review.verdict == "得体" }
    private var tint: Color { fine ? Theme.reply : Color(red: 0.92, green: 0.52, blue: 0.20) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: fine ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(tint)
                Text(Vocabulary.display(review.verdict, in: Vocabulary.verdicts))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
                Spacer()
            }
            if let lands = review.landsAs { row(L("对方读来", "Lands as"), lands) }
            if let issues = review.issues { row(fine ? L("为什么", "Why") : L("问题", "Issue"), issues) }
            if review.rewriteDiffers, let rewrite = review.rewrite {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack {
                        Text(L("可以改成", "Try")).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        Spacer(minLength: 20)
                        Text(rewrite)
                            .font(.system(size: 13))
                            .foregroundStyle(.black.opacity(0.88))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(BubbleShape(tailOnLeft: false).fill(Color(red: 0.62, green: 0.91, blue: 0.47)))
                    }
                    if let gloss = review.rewriteGloss {
                        Text(L("意思：", "Means: ") + gloss).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                    CopyButton(text: rewrite)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.07)))
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                .frame(width: AppLanguage.current == .en ? 58 : 50, alignment: .leading)
            Text(text).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
