import AppKit
import UniformTypeIdentifiers

/// A snapshot is captured before the save panel opens, so continuing transcription
/// cannot change the contents of the file the user is currently choosing to save.
enum TextExport {
    /// Used by the AI workspace for its results.
    static func save(_ text: String, onError: @escaping (String) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        save(text, fileName: "声笺 \(formatter.string(from: Date())).txt", fileExtension: "txt", title: "文本另存为", onError: onError)
    }

    /// Writes `text` as UTF-8 (no BOM) to a file the user picks.
    static func save(_ text: String, fileName: String, fileExtension: String, title: String, onError: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = fileName
        let data = Data(text.utf8)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { onError("保存失败：\(error.localizedDescription)") }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
