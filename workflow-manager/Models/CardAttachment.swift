//
//  CardAttachment.swift
//  workflow-manager
//
//  An image pasted or dropped into a card's notes.
//
//  The bytes live here, in the store, and the notes carry only a reference —
//  `![screenshot](attachment:<uuid>)` — so the notes stay plain Markdown. Not
//  as base64 inside the notes (it would bloat `tasks.json`, every phone
//  snapshot and every MCP read, and bury the text in noise), and not as files
//  in the linked repository (a card needs no repository, and pasting a
//  screenshot must not write into someone's code).
//
//  `.externalStorage`, so SwiftData keeps large images beside the database
//  rather than inside it.
//

import Foundation
import SwiftData
import ImageIO
import UniformTypeIdentifiers
import ClaudeWMWire

@Model
final class CardAttachment {
    var uuid: UUID = UUID()
    var filename: String = ""
    /// A UTType identifier: `public.png`, `public.jpeg`, …
    var contentType: String = UTType.png.identifier
    @Attribute(.externalStorage) var data: Data = Data()
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var createdAt: Date = Date.now

    /// Inverse is declared on `WorkItem.attachments`.
    var item: WorkItem?

    init(filename: String, contentType: String, data: Data, pixelWidth: Int, pixelHeight: Int) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var mimeType: String {
        UTType(contentType)?.preferredMIMEType ?? "image/png"
    }

    /// What goes in the notes. The alt text is the file name without its
    /// extension, which is what a reader of the raw Markdown — Claude, `gh` —
    /// sees instead of the picture.
    var markdownReference: String {
        AttachmentReferences.markdown(alt: (filename as NSString).deletingPathExtension, id: uuid)
    }
}

// MARK: - Images

enum AttachmentImage {
    struct Normalized {
        var data: Data
        var contentType: String
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// Formats kept as they are. Anything else an image can arrive as — TIFF,
    /// which is what a pasteboard screenshot usually is — becomes PNG, so
    /// whatever reads the attachment later need not handle it.
    private static let kept: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.heic.identifier,
    ]

    /// Reads `data` as an image, or nil if it is not one.
    static func normalize(_ data: Data) -> Normalized? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        if kept.contains(type) {
            return Normalized(data: data, contentType: type, pixelWidth: width, pixelHeight: height)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = encode(image, as: .png, quality: nil) else { return nil }
        return Normalized(data: png, contentType: UTType.png.identifier, pixelWidth: width, pixelHeight: height)
    }

    /// A JPEG no longer than `maxEdge` on either side, for handing an image to
    /// a model: full-size screenshots are megabytes, and a model sees no more
    /// detail than this anyway.
    static func preview(of data: Data, maxEdge: Int = 1568, quality: Double = 0.82) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, as: .jpeg, quality: quality)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension WorkItem {
    /// Attachments the notes no longer mention. Deleting the reference is how
    /// an image is removed, so these are swept when the card's window closes —
    /// not on every keystroke, which would make ⌘Z of a deleted line restore a
    /// reference to an image already gone.
    var unreferencedAttachments: [CardAttachment] {
        let referenced = Set(AttachmentReferences.ids(in: details))
        return attachments.filter { !$0.isDeleted && !referenced.contains($0.uuid) }
    }
}
