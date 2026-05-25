import SwiftUI
import PhotosUI
import FirebaseAuth
import AVFoundation

// MARK: - Check Flow Coordinator
struct CheckFlowView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @StateObject private var vm = CheckFlowViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                switch vm.step {
                case .camera:
                    CameraPickerScreen(vm: vm)
                case .quality:
                    PhotoQualityScreen(vm: vm)
                case .styleGoal:
                    StyleGoalScreen(vm: vm)
                case .analyzing:
                    AnalyzingScreen(vm: vm)
                case .result:
                    if let analysis = vm.analysis {
                        ResultView(analysis: analysis, outfitImage: vm.selectedImage)
                    }
                }
            }
        }
        .onAppear { vm.appState = appState }
    }
}

// MARK: - ViewModel
@MainActor
final class CheckFlowViewModel: ObservableObject {
    enum Step { case camera, quality, styleGoal, analyzing, result }

    @Published var step: Step = .camera
    @Published var selectedImage: UIImage?
    @Published var selectedGoal: StyleGoal = .genZ
    @Published var photoQualityScore: Double = 0
    @Published var qualityIssues: [String] = []
    @Published var analysis: OutfitAnalysis?
    @Published var errorMessage: String?
    @Published var isRetrying = false

    var appState: AppState?

    func imageSelected(_ image: UIImage) {
        selectedImage = image
        evaluatePhotoQuality(image)
        withAnimation(.spring()) { step = .quality }
    }

    func proceedFromQuality() {
        withAnimation(.spring()) { step = .styleGoal }
    }

    func startAnalysis() {
        withAnimation(.spring()) { step = .analyzing }
        Task { await runAnalysis() }
    }

    private func evaluatePhotoQuality(_ image: UIImage) {
        var issues: [String] = []
        var score: Double = 100

        // Resolution check
        if image.size.width < 400 || image.size.height < 400 {
            issues.append("Photo resolution is low")
            score -= 25
        }

        // Aspect ratio: portrait is better for outfits
        let ratio = image.size.height / image.size.width
        if ratio < 0.8 {
            issues.append("Landscape photo — portrait works better")
            score -= 15
        }

        photoQualityScore = max(score, 20)
        qualityIssues = issues
    }

    private func runAnalysis() async {
        guard let image = selectedImage, let appState else { return }

        // Guard: verify Firebase Auth has a current user before making any calls
        guard Auth.auth().currentUser != nil else {
            print("[CheckFlow] ⚠️ No signed-in user — aborting analysis")
            errorMessage = "Please sign in to check your fit."
            withAnimation { step = .camera }
            return
        }
        print("[CheckFlow] Starting analysis for uid: \(Auth.auth().currentUser!.uid)")

        let storageService = StorageService()
        let resized = storageService.prepareForUpload(image)
        let fileSize = storageService.estimatedFileSizeBytes(resized)

        do {
            // 1. Create Firestore record and get storage path
            print("[CheckFlow] Requesting upload slot...")
            let uploadResp = try await appState.aiService.requestUploadSlot(
                fileName: "outfit_\(Date().timeIntervalSince1970).jpg",
                fileSizeBytes: fileSize,
                styleGoal: selectedGoal
            )
            print("[CheckFlow] Upload slot: fitCheckId=\(uploadResp.fitCheckID) path=\(uploadResp.storagePath)")

            // 2. Upload image directly to Firebase Storage
            print("[CheckFlow] Uploading image to Storage...")
            try await appState.aiService.uploadImage(resized, toStoragePath: uploadResp.storagePath)
            print("[CheckFlow] ✅ Image uploaded")

            // 3. Analyze
            print("[CheckFlow] Calling analyzeOutfit fitCheckId=\(uploadResp.fitCheckID)")
            appState.analyticsService.track(.analysisStarted)
            let result = try await appState.aiService.analyzeOutfit(
                fitCheckID: uploadResp.fitCheckID,
                styleGoal: selectedGoal
            )
            print("[CheckFlow] ✅ Analysis complete — score: \(result.overallScore)")

            appState.analyticsService.track(.analysisCompleted, properties: [
                "score": result.overallScore,
                "style_goal": selectedGoal.rawValue,
                "confidence": result.confidenceLevel
            ])

            analysis = result
            withAnimation(.spring()) { step = .result }

            // Update daily checks
            await appState.refreshUser()

        } catch let err as AIError {
            print("[CheckFlow] ⚠️ AIError: \(err)")
            errorMessage = err.errorDescription
            withAnimation { step = .camera }
        } catch {
            print("[CheckFlow] ⚠️ Unexpected error: \(error)")
            errorMessage = "Something went wrong. Please try again."
            withAnimation { step = .camera }
        }
    }
}

// MARK: - Camera Picker Screen
struct CameraPickerScreen: View {
    @ObservedObject var vm: CheckFlowViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCameraSheet = false

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            // Error banner
            if let err = vm.errorMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.fcWarning)
                        Text(err)
                            .font(.fcCaption)
                            .foregroundColor(.fcTextPrimary)
                        Spacer()
                        Button(action: { vm.errorMessage = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.fcTextSecondary)
                        }
                    }
                    .padding(12)
                    .background(Color.fcWarning.opacity(0.15))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    Spacer()
                }
                .zIndex(1)
            }

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.fcTextPrimary)
                            .padding(10)
                            .background(Color.fcSurface)
                            .clipShape(Circle())
                    }
                    Spacer()
                    Text("Check My Fit")
                        .font(.fcBodyBold)
                        .foregroundColor(.fcTextPrimary)
                    Spacer()
                    Color.clear.frame(width: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                // Guide illustration
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.fcSurface)
                        .frame(width: 220, height: 320)

                    VStack(spacing: 8) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.fcTextSecondary.opacity(0.3))
                        Text("Stand here\nhead to toe")
                            .font(.fcCaption)
                            .foregroundColor(.fcTextSecondary)
                            .multilineTextAlignment(.center)
                    }

                    // Dashed border
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.fcAccent.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .frame(width: 220, height: 320)
                }

                // Tip
                HStack(spacing: 8) {
                    Text("💡")
                    Text("Best results: full-body mirror shot, good lighting")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }
                .padding(12)
                .background(Color.fcSurface)
                .cornerRadius(12)
                .padding(.horizontal, 32)
                .padding(.top, 24)

                Spacer()

                // Action buttons
                HStack(spacing: 20) {
                    // Gallery
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 24))
                                .foregroundColor(.fcTextPrimary)
                            Text("Gallery")
                                .font(.fcCaption)
                                .foregroundColor(.fcTextSecondary)
                        }
                        .frame(width: 70, height: 70)
                        .background(Color.fcSurface)
                        .cornerRadius(18)
                    }

                    // Shutter
                    Button(action: {
                        let status = AVCaptureDevice.authorizationStatus(for: .video)
                        switch status {
                        case .authorized:
                            showCameraSheet = true
                        case .notDetermined:
                            AVCaptureDevice.requestAccess(for: .video) { granted in
                                DispatchQueue.main.async {
                                    if granted { showCameraSheet = true }
                                    else { vm.errorMessage = "Camera access denied. Go to Settings → FitCheck → Camera to enable it." }
                                }
                            }
                        case .denied, .restricted:
                            vm.errorMessage = "Camera access denied. Go to Settings → FitCheck → Camera to enable it."
                        @unknown default:
                            showCameraSheet = true
                        }
                    }) {
                        Circle()
                            .fill(Color.fcAccent)
                            .frame(width: 80, height: 80)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                                    .frame(width: 70, height: 70)
                            )
                    }
                    .buttonStyle(HapticButtonStyle())
                    .shadow(color: Color.fcAccent.opacity(0.5), radius: 16)

                    Color.clear.frame(width: 70, height: 70)
                }
                .padding(.bottom, 50)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    vm.imageSelected(uiImage)
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraSheet) {
            ImagePickerController(selectedImage: Binding(
                get: { nil },
                set: { img in if let img { vm.imageSelected(img) } }
            ))
        }
    }
}

// MARK: - UIKit Camera Bridge
struct ImagePickerController: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            // Simulator or device without camera — fall back to photo library
            picker.sourceType = .photoLibrary
        }
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePickerController
        init(_ parent: ImagePickerController) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.selectedImage = info[.originalImage] as? UIImage
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
