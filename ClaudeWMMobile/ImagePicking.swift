//
//  ImagePicking.swift
//  ClaudeWMMobile
//
//  Getting a picture into a card: from Photos, from the camera, or pasted.
//
//  What is sent is a JPEG or PNG at full size. A screenshot stays PNG — its
//  text would blur as JPEG — and anything else (a HEIC from the camera roll)
//  becomes JPEG here, because the Mac keeps what it can show everywhere and
//  would otherwise turn a 2 MB HEIC into a 20 MB PNG.
//

import SwiftUI
import PhotosUI
import UIKit

struct PickedImage {
    var data: Data
    var preview: UIImage
    var filename: String
}

enum ImagePreparation {
    static func prepare(_ data: Data, suggestedName: String? = nil) -> PickedImage? {
        guard let image = UIImage(data: data) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return PickedImage(data: data, preview: image, filename: name(suggestedName, "png"))
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return PickedImage(data: data, preview: image, filename: name(suggestedName, "jpeg"))
        }
        return prepare(image, suggestedName: suggestedName)
    }

    static func prepare(_ image: UIImage, suggestedName: String? = nil) -> PickedImage? {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        return PickedImage(data: jpeg, preview: image, filename: name(suggestedName, "jpeg"))
    }

    /// A pasted picture is usually a screenshot, so it goes as PNG.
    static func preparePasted(_ image: UIImage) -> PickedImage? {
        guard let png = image.pngData() else { return prepare(image) }
        return PickedImage(data: png, preview: image, filename: name("Pasted image", "png"))
    }

    private static func name(_ suggested: String?, _ ext: String) -> String {
        let base = suggested.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Photo \(Date.now.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
        return "\(base).\(ext)"
    }

    static func load(_ item: PhotosPickerItem) async -> PickedImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return prepare(data)
    }
}

/// The camera, which SwiftUI has no view for.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPicked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// The three ways in, attached to any screen with a notes editor. The editor's
/// bar asks; this presents and hands back a prepared image.
struct ImageSources: ViewModifier {
    let controller: NotesEditorController
    let onImage: (PickedImage) -> Void

    @State private var showsLibrary = false
    @State private var showsCamera = false
    @State private var libraryItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showsLibrary, selection: $libraryItems, maxSelectionCount: 6,
                          matching: .images)
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { image in
                    if let picked = ImagePreparation.prepare(image) { onImage(picked) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: libraryItems) { _, items in
                guard !items.isEmpty else { return }
                libraryItems = []
                Task {
                    for item in items {
                        if let picked = await ImagePreparation.load(item) { onImage(picked) }
                    }
                }
            }
            .onAppear {
                controller.onPhotoLibrary = { showsLibrary = true }
                controller.onCamera = { if CameraPicker.isAvailable { showsCamera = true } else { showsLibrary = true } }
                controller.onPasteImage = { image in
                    if let picked = ImagePreparation.preparePasted(image) { onImage(picked) }
                }
            }
    }
}

extension View {
    func imageSources(_ controller: NotesEditorController, onImage: @escaping (PickedImage) -> Void) -> some View {
        modifier(ImageSources(controller: controller, onImage: onImage))
    }
}
