//
//  CameraPicker.swift
//  WorkoutTracker
//
//  Thin SwiftUI wrappers around UIKit photo controllers:
//   • CameraPicker        — UIImagePickerController for taking a photo.
//   • PhotoLibraryPicker  — PHPickerViewController for choosing from the library.
//  Both are presented lazily (from a sheet/cover) rather than embedded in a Form,
//  because SwiftUI's `PhotosPicker`, when built eagerly into a Form row, can stall
//  the UI on the Simulator. Camera requires NSCameraUsageDescription.
//

import SwiftUI
import UIKit
import PhotosUI

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Pick a single image from the photo library via PHPickerViewController.
/// Presented from a sheet — NOT embedded in a Form — to avoid the Simulator
/// stall caused by SwiftUI's `PhotosPicker` building eagerly inside a List/Form.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    /// Returns JPEG data for the chosen image.
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.8) else { return }
                DispatchQueue.main.async { self.parent.onImage(data) }
            }
        }
    }
}
