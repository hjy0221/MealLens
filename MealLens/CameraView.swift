import SwiftUI
import UIKit

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraView

        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let data = Self.normalizedJPEGData(from: image) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        private static func normalizedJPEGData(from image: UIImage) -> Data? {
            let maxDimension = 1600.0
            let longestSide = max(image.size.width, image.size.height)
            let ratio = longestSide > 0 ? min(1, maxDimension / longestSide) : 1
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            return normalized.jpegData(compressionQuality: 0.8)
        }
    }
}
