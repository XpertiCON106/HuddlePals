import AVFoundation
import SwiftUI
import UIKit

/// Camera-only capture for the main deposit flow: wraps
/// `UIImagePickerController` locked to the device camera, so there is no
/// path to choose an existing photo from the library or files. SwiftUI has
/// no native in-the-moment camera, so this UIKit bridge is the standard
/// approach.
struct CameraPicker: UIViewControllerRepresentable {
    /// False on the Simulator and any device without a camera.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Whether Compose can open the camera, and if not, why.
    enum Availability: Equatable {
        /// Open it (iOS asks for permission the first time).
        case ready
        /// The user turned camera access off for HuddlePals: Settings fixes it.
        case denied
        /// Screen Time or a device profile blocks the camera.
        case restricted
        /// The Simulator, or a device without a camera.
        case noCamera
    }

    /// Permission is checked first: a restricted camera also reports the
    /// source type as unavailable, and must not read as "no camera".
    static func availability(
        hasCamera: Bool = isAvailable,
        status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    ) -> Availability {
        switch status {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return hasCamera ? .ready : .noCamera
        }
    }

    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
