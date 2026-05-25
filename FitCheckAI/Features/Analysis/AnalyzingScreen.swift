import SwiftUI

struct AnalyzingScreen: View {
    @ObservedObject var vm: CheckFlowViewModel
    @State private var scanOffset: CGFloat = -300
    @State private var ringProgress: Double = 0
    @State private var detectedItems: [String] = []
    @State private var currentDetection = 0

    private let detectionSteps = [
        "Detecting outfit...",
        "Reading colors...",
        "Analyzing fit...",
        "Scoring accessories...",
        "Measuring trend alignment...",
        "Almost ready..."
    ]

    private let detectionTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Background: blurred outfit photo
            if let img = vm.selectedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 20)
                    .overlay(Color.black.opacity(0.65))
            }

            VStack(spacing: 0) {
                // Photo with scan effect
                ZStack {
                    if let img = vm.selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: UIScreen.main.bounds.height * 0.45)
                            .cornerRadius(20)
                            .clipped()
                    }

                    // Scan line
                    GeometryReader { geo in
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.clear, Color.fcAccent.opacity(0.8), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 3)
                            .offset(y: scanOffset + geo.size.height / 2)
                            .blur(radius: 2)
                    }

                    // Detection boxes overlay
                    if currentDetection >= 2 {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.fcAccent.opacity(0.7), lineWidth: 1.5)
                            .frame(width: 120, height: 160)
                            .offset(y: -20)
                            .transition(.opacity)
                    }
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.45)
                .padding(.top, 40)

                // Detection steps
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(detectionSteps.prefix(currentDetection + 1).enumerated()), id: \.offset) { idx, step in
                        HStack(spacing: 8) {
                            if idx < currentDetection {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.fcSuccess)
                                    .font(.system(size: 13))
                            } else {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.fcAccent)
                            }
                            Text(step)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(idx < currentDetection ? .fcTextSecondary : .fcTextPrimary)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(16)
                .background(Color.black.opacity(0.5))
                .cornerRadius(14)
                .padding(.horizontal, 24)
                .padding(.top, 24)

                Spacer()

                // Loading quip
                LoadingQuipView()
                    .padding(.bottom, 40)
            }
        }
        .onAppear { startAnimations() }
        .onReceive(detectionTimer) { _ in
            withAnimation(.spring()) {
                if currentDetection < detectionSteps.count - 1 {
                    currentDetection += 1
                }
            }
        }
    }

    private func startAnimations() {
        // Scan line animation
        withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: true)) {
            scanOffset = 300
        }
        // Ring progress
        withAnimation(.linear(duration: 6.0)) {
            ringProgress = 0.9
        }
    }
}
