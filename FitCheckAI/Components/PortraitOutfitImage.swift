import SwiftUI
import Vision

// MARK: - Outfit image source

/// Where a (typically portrait, full-body) outfit photo comes from — either an
/// in-memory `UIImage` (the just-uploaded photo) or a remote Storage `URL`
/// (history / leaderboard thumbnails). Shared by `PortraitOutfitImage` and
/// `OutfitImageViewer` so every screen renders outfits the same portrait-safe way.
enum OutfitImageSource: Equatable {
    case uiImage(UIImage)
    case remote(URL)
}

/// Identifiable wrapper so a tapped outfit photo can drive `.fullScreenCover(item:)`.
struct OutfitImageItem: Identifiable, Equatable {
    let id = UUID()
    let source: OutfitImageSource
}


// MARK: - Portrait-safe outfit image

/// Renders an outfit photo without ever cropping the face/head or shoes: the full
/// image is shown with `.scaledToFit()` over a solid cream fill, so it fits cleanly
/// inside whatever fixed-height frame the parent gives it. Portrait (full-body) and
/// wide/landscape/group photos alike are shown whole — letterboxed against the cream
/// background — so the image never dictates the layout height. Falls back to a
/// neutral camera placeholder when there's no image yet.
///
/// The PARENT owns the frame (height), corner radius, badges, and tap gesture —
/// this view only paints the picture + blurred backdrop and fills whatever frame
/// it's given. Wrap it like:
/// ```
/// PortraitOutfitImage(source: ...)
///     .frame(maxWidth: .infinity).frame(height: 460)
///     .clipped()
///     .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
/// ```
struct PortraitOutfitImage: View {
    let source: OutfitImageSource?

    var body: some View {
        switch source {
        case .uiImage(let img):
            fill(Image(uiImage: img))
        case .remote(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): fill(img)
                case .failure:          PortraitOutfitPlaceholder()
                default:                PortraitOutfitLoading()
                }
            }
        case nil:
            PortraitOutfitPlaceholder()
        }
    }

    /// Solid cream fill + the sharp aspect-fit foreground (full body, never cropped).
    /// Wide/landscape photos letterbox cleanly against the cream rather than blowing
    /// up the container or showing a blurred backdrop.
    private func fill(_ image: Image) -> some View {
        ZStack {
            Color.fcSurface

            image
                .resizable()
                .scaledToFit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Neutral placeholder shown when an outfit photo is missing or fails to load.
struct PortraitOutfitPlaceholder: View {
    var body: some View {
        ZStack {
            Color.fcSurface
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44))
                .foregroundColor(.fcTextSecondary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loading state while a remote outfit photo is being fetched.
struct PortraitOutfitLoading: View {
    var body: some View {
        Color.fcSurface2
            .overlay(ProgressView().tint(.fcTextSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Full-screen outfit viewer

/// Full-screen viewer for a tapped outfit photo: black backdrop, the full image
/// shown with `.scaledToFit()`, pinch- and double-tap-to-zoom, drag-to-pan when
/// zoomed, and a close button. Works for both in-memory and remote sources.
struct OutfitImageViewer: View {
    let source: OutfitImageSource
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            imageView
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification)
                .simultaneousGesture(panWhenZoomed)
                .onTapGesture(count: 2) { toggleZoom() }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var imageView: some View {
        switch source {
        case .uiImage(let img):
            Image(uiImage: img).resizable().scaledToFit()
        case .remote(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .empty:            ProgressView().tint(.white)
                default:                Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = min(max(lastScale * value, 1), 4) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(.spring(response: 0.3)) { offset = .zero; lastOffset = .zero }
                }
            }
    }

    private var panWhenZoomed: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3)) {
            if scale > 1 {
                scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
            } else {
                scale = 2; lastScale = 2
            }
        }
    }
}

// MARK: - Smart (Vision-based) outfit preview card

/// Edge-to-edge outfit preview that crops *around the person* instead of the center.
/// On-device Vision detects the face (or, failing that, the human body) and produces
/// a crop — at the card's exact aspect ratio — that keeps the face/head visible high
/// in the frame with the shoulders/chest below, so cards never show mostly wall.
///
/// No blur, no letterbox: the cropped image fills the card. The PARENT owns the
/// frame, corner radius, gradient overlay, score pill, and Details button — this view
/// only paints the smart-cropped picture. Use for Home Latest Look + History/Saved
/// thumbnails; detail/result screens keep `PortraitOutfitImage` (full image).
///
/// Everything is client-side: the original photo is never modified, the full image
/// is downloaded once (cached), and each crop is cached by source + aspect so it's
/// computed a single time.
struct SmartOutfitImageView: View {
    let source: OutfitImageSource?

    @State private var base: UIImage?
    @State private var cropped: UIImage?
    /// Source identity (sans aspect) the current `base`/`cropped` were built for, so
    /// a recycled view that gets a *different* outfit resets instead of showing stale art.
    @State private var loadedKey: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.fcSurface2

                if let cropped {
                    // Crop already matches the card aspect → fills exactly, no re-crop.
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFill()
                } else if let base {
                    // While Vision runs, show a top-anchored fill so the face is never
                    // center-cropped even for the split second before the smart crop lands.
                    Image(uiImage: base)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                } else if source == nil {
                    PortraitOutfitPlaceholder()
                } else {
                    PortraitOutfitLoading()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: taskKey(geo.size)) {
                await prepare(targetAspect: geo.size.width / max(geo.size.height, 1))
            }
        }
    }

    /// Re-run when the outfit OR the card's aspect ratio (bucketed) changes.
    private func taskKey(_ size: CGSize) -> String {
        let ar = size.height > 0 ? Int((size.width / size.height) * 100) : 0
        return "\(SmartOutfitCrop.sourceKey(source))|\(ar)"
    }

    @MainActor
    private func prepare(targetAspect: CGFloat) async {
        guard let source, targetAspect > 0 else { return }

        // New outfit in a recycled view → drop stale image/crop first.
        let srcKey = SmartOutfitCrop.sourceKey(source)
        if srcKey != loadedKey {
            base = nil
            cropped = nil
            loadedKey = srcKey
        }

        guard let img = await OutfitImageLoader.load(source) else { return }
        if !Task.isCancelled { base = img }

        let cacheKey = "\(srcKey)|\(Int(targetAspect * 100))" as NSString
        if let hit = SmartOutfitCrop.cache.object(forKey: cacheKey) {
            if !Task.isCancelled { cropped = hit }
            return
        }

        // Vision + crop run off the main actor (crop is async + nonisolated).
        let result = await SmartOutfitCrop.crop(img, toAspect: targetAspect)
        SmartOutfitCrop.cache.setObject(result, forKey: cacheKey)
        if !Task.isCancelled { cropped = result }
    }
}

// MARK: - Image loading

/// Loads an `OutfitImageSource` into a `UIImage` (needed for Vision). Remote images
/// are downloaded once and memo-cached; `.uiImage` sources pass straight through.
enum OutfitImageLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func load(_ source: OutfitImageSource) async -> UIImage? {
        switch source {
        case .uiImage(let img):
            return img
        case .remote(let url):
            let key = url.absoluteString as NSString
            if let hit = cache.object(forKey: key) { return hit }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return nil }
            cache.setObject(img, forKey: key)
            return img
        }
    }
}

// MARK: - Vision smart crop

/// Produces a person-focused crop of an outfit photo at a target aspect ratio using
/// on-device Vision. Pure, cache-friendly, and runs off the main actor.
enum SmartOutfitCrop {
    /// Cropped results, keyed by `sourceKey|aspect*100`.
    static let cache = NSCache<NSString, UIImage>()

    /// Stable identity for a source, ignoring aspect ratio.
    static func sourceKey(_ source: OutfitImageSource?) -> String {
        switch source {
        case .remote(let u):  return u.absoluteString
        case .uiImage(let i): return "ui-\(UInt(bitPattern: ObjectIdentifier(i).hashValue))"
        case nil:             return "nil"
        }
    }

    private enum FocusKind { case face, person, none }
    private struct Focus {
        let kind: FocusKind
        let center: CGPoint   // pixels, top-left origin
        let topY: CGFloat     // pixel y of the top of the detected region
    }

    /// Crops `image` to `targetAspect` (width/height), keeping the face high in frame.
    /// `async` + nonisolated → the Vision work executes on the cooperative pool, never
    /// blocking the main thread.
    static func crop(_ image: UIImage, toAspect targetAspect: CGFloat) async -> UIImage {
        let up = image.normalizedUp()
        guard let cg = up.cgImage, targetAspect > 0 else { return up }

        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let focus = detectFocus(cg: cg, width: W, height: H)

        // Largest crop of the target aspect that fits inside the image (cover crop).
        var cropW: CGFloat, cropH: CGFloat
        if targetAspect >= W / H {
            cropW = W
            cropH = W / targetAspect
        } else {
            cropH = H
            cropW = H * targetAspect
        }

        // Horizontal: center on the subject. Vertical: place the focus so the face
        // sits ~32% down from the top, leaving room for shoulders/chest below.
        var originX = focus.center.x - cropW / 2
        var originY: CGFloat
        switch focus.kind {
        case .face:   originY = focus.center.y - cropH * 0.32
        case .person: originY = focus.topY - cropH * 0.08
        case .none:   originY = 0; originX = (W - cropW) / 2   // top-aligned fallback
        }

        originX = min(max(originX, 0), max(0, W - cropW))
        originY = min(max(originY, 0), max(0, H - cropH))

        let rect = CGRect(x: originX.rounded(), y: originY.rounded(),
                          width: cropW.rounded(.down), height: cropH.rounded(.down))
        guard let out = cg.cropping(to: rect) else { return up }
        return UIImage(cgImage: out, scale: up.scale, orientation: .up)
    }

    /// Runs face detection, then human-body detection as a fallback. Coordinates are
    /// converted from Vision's normalized, bottom-left space to top-left pixels.
    private static func detectFocus(cg: CGImage, width W: CGFloat, height H: CGFloat) -> Focus {
        let faceReq = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([faceReq])
        if let faces = faceReq.results, !faces.isEmpty {
            let face = faces.max { area($0.boundingBox) < area($1.boundingBox) }!
            let bb = face.boundingBox
            return Focus(kind: .face,
                         center: CGPoint(x: bb.midX * W, y: (1 - bb.midY) * H),
                         topY: (1 - bb.maxY) * H)
        }

        let humanReq = VNDetectHumanRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([humanReq])
        if let humans = humanReq.results, !humans.isEmpty {
            let person = humans.max { $0.boundingBox.height < $1.boundingBox.height }!
            let bb = person.boundingBox
            return Focus(kind: .person,
                         center: CGPoint(x: bb.midX * W, y: (1 - bb.midY) * H),
                         topY: (1 - bb.maxY) * H)
        }

        return Focus(kind: .none, center: CGPoint(x: W / 2, y: 0), topY: 0)
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}

private extension UIImage {
    /// Redraws the image in `.up` orientation so its `cgImage` pixels match what's
    /// displayed — required before mapping Vision coordinates and cropping.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
