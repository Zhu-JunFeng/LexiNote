import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var runtime = AppRuntime.shared
    @ObservedObject private var recommendations = RecommendationService.shared
    @AppStorage("LexiNote.autoRecordToLibrary") private var autoRecordToLibrary = true
    @State private var isRecording = false
    @State private var isRecordingSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("偏好设置")
                    .font(.title2.weight(.semibold))
                Text("让查词随时顺手可用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: $autoRecordToLibrary) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("查到后自动记录到单词本")
                        .font(.callout.weight(.medium))
                    Text("有释义时保存首条意思；已有词卡不会被覆盖。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("打开查词窗口")
                        .font(.callout.weight(.medium))
                    Text("在其他应用中也可以使用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isRecording ? "请按组合键…" : runtime.shortcut.displayString) {
                    isRecording = true
                    isRecordingSave = false
                }
                .frame(minWidth: 130)
                ShortcutRecorder(isRecording: $isRecording) { shortcut in
                    runtime.updateShortcut(shortcut)
                }
                .frame(width: 1, height: 1)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("全局加入单词本")
                        .font(.callout.weight(.medium))
                    Text("读取一次剪贴板；重复词卡直接打开")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isRecordingSave ? "请按组合键…" : runtime.saveShortcut.displayString) {
                    isRecordingSave = true
                    isRecording = false
                }
                .frame(minWidth: 130)
                ShortcutRecorder(isRecording: $isRecordingSave) { shortcut in
                    runtime.updateSaveShortcut(shortcut)
                }
                .frame(width: 1, height: 1)
            }

            Text("点击组合键可重新录入；按 Esc 取消。窗口内 ⌘S 仍可保存当前词卡。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = runtime.hotkeyError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            Toggle(isOn: Binding(get: { recommendations.isEnabled },
                                 set: { recommendations.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("随机推荐通知")
                        .font(.callout.weight(.medium))
                    Text("使用电脑时，每累计约 30–120 分钟推荐新词或到期复习词。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if let status = recommendations.statusMessage {
                Text(status).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(LexiStyle.canvas)
        .tint(LexiStyle.accent)
        .onChange(of: isRecording) { _, recording in
            runtime.isRecordingShortcut = recording || isRecordingSave
        }
        .onChange(of: isRecordingSave) { _, recording in
            runtime.isRecordingShortcut = recording || isRecording
        }
        .onDisappear { runtime.isRecordingShortcut = false }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (HotkeyShortcut) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { shortcut in
            onCapture(shortcut)
            isRecording = false
        }
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = { shortcut in
            onCapture(shortcut)
            isRecording = false
        }
        nsView.onCancel = { isRecording = false }
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((HotkeyShortcut) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
            guard modifiers & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0 else {
                NSSound.beep()
                return
            }
            onCapture?(HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        }
    }
}
