import SwiftUI
import UIKit
import Vision

// Read Japanese from a photo, a screenshot or a copied image: pick the area,
// Apple's on-device text recognition reads it, you check the text, and it
// becomes the passage. Nothing leaves the phone.

struct ImportedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

enum TextRecognizer {
    /// Draws the image upright (camera photos are often rotated) and at most
    /// `maxSide` pixels long, which keeps recognition fast.
    static func upright(_ image: UIImage, maxSide: CGFloat = 4096) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, maxSide / max(pixels.width, pixels.height, 1))
        if image.imageOrientation == .up && factor == 1 && image.cgImage != nil { return image }
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// `region` is normalised with the origin at the bottom left (Vision's convention).
    static func recognize(_ image: CGImage, region: CGRect) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ja-JP", "en-US"]
                request.usesLanguageCorrection = true
                request.regionOfInterest = region
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: TextRecognizer.assemble(request.results ?? []))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private struct Line {
        let text: String
        let box: CGRect
    }

    /// Puts recognised lines back into reading order. Lines that simply wrapped
    /// are joined (Japanese needs no space); gaps and short sentence-final lines
    /// start a new paragraph. Tall, narrow boxes are read as vertical columns.
    static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let lines: [Line] = observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty else { return nil }
            return Line(text: text, box: observation.boundingBox)
        }
        guard !lines.isEmpty else { return "" }
        let tall = lines.filter { $0.box.height > $0.box.width * 1.5 && $0.text.count > 1 }.count
        let vertical = lines.count > 1 && tall * 2 > lines.count
        let ordered = vertical
            ? lines.sorted { ($0.box.maxX, $0.box.maxY) > ($1.box.maxX, $1.box.maxY) }
            : lines.sorted { ($0.box.maxY, -$0.box.minX) > ($1.box.maxY, -$1.box.minX) }
        let longest = ordered.map { vertical ? $0.box.height : $0.box.width }.max() ?? 1
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "」", "』", "…"]
        var result = ""
        var previous: Line?
        for line in ordered {
            if let previous {
                let gap = vertical ? previous.box.minX - line.box.maxX : previous.box.minY - line.box.maxY
                let thickness = vertical ? previous.box.width : previous.box.height
                let length = vertical ? previous.box.height : previous.box.width
                let endedEarly = previous.text.last.map { enders.contains($0) } == true && length < longest * 0.85
                if gap > thickness * 0.7 || endedEarly {
                    result += "\n"
                } else if let last = result.last, let first = line.text.first,
                          last.isASCII && (last.isLetter || last.isNumber || last == ","),
                          first.isASCII && (first.isLetter || first.isNumber) {
                    result += " "
                }
            }
            result += line.text
            previous = line
        }
        return result
    }
}

/// Crop, recognise, review.
struct PhotoTextImport: View {
    let image: UIImage
    let style: ReaderStyle
    let finish: (String) -> Void
    let cancel: () -> Void
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragStart: CGRect?
    @State private var working = false
    @State private var failure: String?
    @State private var reviewing = false
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Group {
                if reviewing { review } else { cropper }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(style.background.ignoresSafeArea())
            .navigationTitle(reviewing ? "Check the text" : "Choose the text area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if reviewing {
                        Button("Back") { reviewing = false }
                    } else {
                        Button("Cancel", action: cancel)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if reviewing {
                        Button("Read") { finish(text) }
                            .fontWeight(.semibold)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("usePhotoText")
                    } else {
                        Button("Scan") { scan() }
                            .fontWeight(.semibold)
                            .disabled(working)
                            .accessibilityIdentifier("scanPhotoText")
                    }
                }
            }
        }
        .tint(style.accent)
        .preferredColorScheme(style.colorScheme)
    }

    // MARK: Crop

    static func fitted(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
    }

    private var cropper: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let frame = Self.fitted(image.size, in: proxy.size)
                let box = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                                 width: crop.width * frame.width, height: crop.height * frame.height)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .gesture(draw(frame))
                        .position(x: frame.midX, y: frame.midY)
                    Path { path in
                        path.addRect(frame)
                        path.addRect(box)
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Rectangle()
                        .stroke(style.accent, lineWidth: 2.5)
                        .frame(width: max(box.width, 1), height: max(box.height, 1))
                        .contentShape(Rectangle())
                        .gesture(move(frame))
                        .position(x: box.midX, y: box.midY)
                    ForEach(0..<4, id: \.self) { corner in
                        Circle()
                            .fill(style.accent)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .frame(width: 46, height: 46)
                            .contentShape(Rectangle())
                            .gesture(resize(corner, frame))
                            .position(x: corner % 2 == 0 ? box.minX : box.maxX, y: corner < 2 ? box.minY : box.maxY)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(18)
            VStack(spacing: 8) {
                if working {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading the text…").font(HandFont.body(15))
                    }
                } else if let failure {
                    Text(failure).font(.footnote).foregroundStyle(style.accent).multilineTextAlignment(.center)
                } else {
                    Text("Drag the corners, move the box, or draw a new box over the text. Then tap Scan.")
                        .font(HandFont.body(14)).foregroundStyle(style.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button("Whole image") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                        .buttonStyle(HandSoftButtonStyle(style: style))
                    Button { scan() } label: { Label("Scan text", systemImage: "text.viewfinder") }
                        .buttonStyle(HandPrimaryButtonStyle(style: style))
                        .disabled(working)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func clampRect(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> CGRect {
        let left = min(max(0, min(minX, maxX)), 1), right = min(max(0, max(minX, maxX)), 1)
        let top = min(max(0, min(minY, maxY)), 1), bottom = min(max(0, max(minY, maxY)), 1)
        return CGRect(x: left, y: top, width: max(right - left, 0.03), height: max(bottom - top, 0.03))
    }

    /// Dragging on the picture draws a new box.
    private func draw(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                crop = clampRect(value.startLocation.x / frame.width, value.startLocation.y / frame.height,
                                 value.location.x / frame.width, value.location.y / frame.height)
            }
    }

    private func move(_ frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let x = min(max(0, start.minX + value.translation.width / frame.width), 1 - start.width)
                let y = min(max(0, start.minY + value.translation.height / frame.height), 1 - start.height)
                crop = CGRect(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Corners: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    private func resize(_ corner: Int, _ frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let dx = value.translation.width / frame.width, dy = value.translation.height / frame.height
                let smallest: CGFloat = 0.05
                var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
                if corner % 2 == 0 { minX = min(max(0, start.minX + dx), maxX - smallest) }
                else { maxX = max(min(1, start.maxX + dx), minX + smallest) }
                if corner < 2 { minY = min(max(0, start.minY + dy), maxY - smallest) }
                else { maxY = max(min(1, start.maxY + dy), minY + smallest) }
                crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func scan() {
        guard let cgImage = image.cgImage else {
            failure = "This image can't be read. Try taking a screenshot of it instead."
            return
        }
        working = true
        failure = nil
        // Vision measures from the bottom-left corner.
        let region = CGRect(x: crop.minX, y: 1 - crop.maxY, width: crop.width, height: crop.height)
        Task {
            do {
                let result = try await TextRecognizer.recognize(cgImage, region: region)
                working = false
                if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failure = "No text found in that area. Try a larger box or a sharper picture."
                } else {
                    text = result
                    reviewing = true
                }
            } catch {
                working = false
                failure = error.localizedDescription
            }
        }
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fix any misread characters, then tap Read.")
                .font(HandFont.body(14))
                .foregroundStyle(style.secondary)
            TextEditor(text: $text)
                .font(.system(size: 19))
                .scrollContentBackground(.hidden)
                .padding(10)
                .sketchCard(style, radius: 18)
                .accessibilityIdentifier("photoTextEditor")
            Button { finish(text) } label: {
                Label("Read this text", systemImage: "book")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HandPrimaryButtonStyle(style: style))
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }
}

/// The system camera, returning one photo (or nil when cancelled).
struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {
        context.coordinator.done = done
    }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
