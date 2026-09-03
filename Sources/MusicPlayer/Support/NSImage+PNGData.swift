import AppKit

extension NSImage {
    /// PNG-encodes this image — used wherever artwork gets copied in from
    /// outside the app (pasted from the clipboard, picked via a file
    /// importer), since the artwork override store just holds raw bytes.
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
