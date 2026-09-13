import AppKit
import UniformTypeIdentifiers

/// A snapshot is captured before the save panel opens, so continuing transcription
/// cannot change the contents of the file the user is currently choosing to save.
enum TextExport {
    static func save(_ text: String, onError: @escaping (String) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "文本另存为"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        panel.nameFieldStringValue = "声笺 \(formatter.string(from: Date())).txt"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { onError("保存失败：\(error.localizedDescription)") }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
