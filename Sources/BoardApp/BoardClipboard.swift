import AppKit

enum BoardClipboardError: LocalizedError {
    case localFileRequired
    case unreadableImage
    case invalidImage
    case imageEncodingFailed
    case invalidFolder
    case unavailablePasteboard

    var errorDescription: String? {
        switch self {
        case .localFileRequired: return "Choose an image or folder on this Mac."
        case .unreadableImage: return "The image could not be read. Check that it still exists and try again."
        case .invalidImage: return "This file could not be opened as an image."
        case .imageEncodingFailed: return "The image could not be prepared for copying."
        case .invalidFolder: return "This folder is no longer available."
        case .unavailablePasteboard: return "The clipboard could not be updated. Try copying again."
        }
    }
}

@MainActor
enum BoardClipboard {
    static func copyImage(at url: URL, to pasteboard: NSPasteboard = .general) throws {
        guard url.isFileURL else { throw BoardClipboardError.localFileRequired }
        let source: Data
        do { source = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw BoardClipboardError.unreadableImage }
        guard let bitmap = NSBitmapImageRep(data: source), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            throw BoardClipboardError.invalidImage
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BoardClipboardError.imageEncodingFailed
        }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else { throw BoardClipboardError.imageEncodingFailed }
        if let tiff = bitmap.representation(using: .tiff, properties: [:]) {
            guard item.setData(tiff, forType: .tiff) else { throw BoardClipboardError.imageEncodingFailed }
        }
        // All decoding and conversion finish before touching the current clipboard.
        // Do not add a file URL or string: chat composers may paste that instead of the picture.
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw BoardClipboardError.unavailablePasteboard }
    }

    static func copyFolder(_ folder: URL, to pasteboard: NSPasteboard = .general) throws {
        guard folder.isFileURL else { throw BoardClipboardError.localFileRequired }
        let path = folder.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BoardClipboardError.invalidFolder
        }
        let item = NSPasteboardItem()
        guard item.setString(path, forType: .string) else { throw BoardClipboardError.unavailablePasteboard }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw BoardClipboardError.unavailablePasteboard }
    }
}
