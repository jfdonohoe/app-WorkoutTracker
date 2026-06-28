//
//  AnimatedImageView.swift
//  WorkoutTracker
//
//  Shows an image from raw Data. If the data is an animated GIF it plays the
//  animation and LOOPS by default (UIImageView auto-loops an animatedImage).
//  Pair with `.aspectRatio(AnimatedImageView.aspectRatio(of:), contentMode: .fit)`
//  to display the ENTIRE image at its natural shape (no cropping).
//

import SwiftUI
import UIKit
import ImageIO

struct AnimatedImageView: UIViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Remembers the data we last decoded so SwiftUI updates that don't change
    /// the image don't trigger a re-decode.
    final class Coordinator { var decodedData: Data? }

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        iv.image = Self.makeImage(data)
        context.coordinator.decodedData = data
        return iv
    }

    func updateUIView(_ iv: UIImageView, context: Context) {
        // Only re-decode when the underlying image actually changes. Decoding a
        // GIF rebuilds every frame via ImageIO; doing it on every SwiftUI update
        // (e.g. once per rest-timer tick) pegs the CPU.
        guard context.coordinator.decodedData != data else { return }
        context.coordinator.decodedData = data
        iv.image = Self.makeImage(data)
    }

    /// Static image, or a looping animated image for multi-frame data (GIF).
    static func makeImage(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var total: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            total += frameDelay(src, i)
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        // animatedImage(with:duration:) loops indefinitely when set on a UIImageView.
        return UIImage.animatedImage(with: frames, duration: total > 0 ? total : Double(frames.count) * 0.1)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.011 ? 0.1 : d   // clamp tiny/zero delays like browsers do
    }

    /// Width / height of the image, for `.aspectRatio`. Defaults to 1 if unknown.
    static func aspectRatio(of data: Data) -> CGFloat {
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat, h > 0 {
            return w / h
        }
        if let img = UIImage(data: data), img.size.height > 0 {
            return img.size.width / img.size.height
        }
        return 1
    }
}
