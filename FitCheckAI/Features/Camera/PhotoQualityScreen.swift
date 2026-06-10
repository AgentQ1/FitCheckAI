import SwiftUI

struct PhotoQualityScreen: View {
    @ObservedObject var vm: CheckFlowViewModel
    @State private var showPoorQualityAlert = false

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 6) {
                    Text("Quick check before we score.")
                        .font(.fcHeading)
                        .foregroundColor(.fcTextPrimary)
                    Text("Better photo = better score.")
                        .font(.fcBody)
                        .foregroundColor(.fcTextSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 24)

                // Photo + checklist
                HStack(alignment: .top, spacing: 16) {
                    // Photo preview
                    if let img = vm.selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 130, height: 180)
                            .clipped()
                            .cornerRadius(16)
                    }

                    // Checklist
                    VStack(alignment: .leading, spacing: 12) {
                        QualityCheckRow(
                            label: "Full body visible",
                            status: .ok
                        )
                        QualityCheckRow(
                            label: "Good lighting",
                            status: vm.photoQualityScore > 60 ? .ok : .warning
                        )
                        ForEach(vm.qualityIssues, id: \.self) { issue in
                            QualityCheckRow(label: issue, status: .warning)
                        }
                        QualityCheckRow(
                            label: "High resolution",
                            status: vm.photoQualityScore > 50 ? .ok : .warning
                        )
                    }
                }
                .padding(.horizontal, 24)

                // Quality score bar
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Photo Quality")
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextPrimary)
                        Spacer()
                        Text("\(Int(vm.photoQualityScore))/100")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(Color.scoreColor(for: vm.photoQualityScore / 10))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.fcTextSecondary.opacity(0.15)).frame(height: 8)
                            Capsule()
                                .fill(Color.scoreColor(for: vm.photoQualityScore / 10))
                                .frame(width: geo.size.width * (vm.photoQualityScore / 100), height: 8)
                                .animation(.spring(), value: vm.photoQualityScore)
                        }
                    }
                    .frame(height: 8)
                }
                .padding(16)
                .background(Color.fcSurface)
                .cornerRadius(14)
                .padding(.horizontal, 24)

                Spacer()

                // Actions
                VStack(spacing: 12) {
                    Button("Looks Good — Continue →") {
                        if vm.photoQualityScore < 40 {
                            showPoorQualityAlert = true
                        } else {
                            vm.proceedFromQuality()
                        }
                    }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.fcBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.fcAccent)
                    .cornerRadius(16)
                    .buttonStyle(HapticButtonStyle())

                    Button("Retake Photo") {
                        withAnimation { vm.step = .camera }
                    }
                    .font(.fcBody)
                    .foregroundColor(.fcTextSecondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .alert("Low Photo Quality", isPresented: $showPoorQualityAlert) {
            Button("Retake for Better Results", role: .cancel) {
                vm.step = .camera
            }
            Button("Continue Anyway") {
                vm.proceedFromQuality()
            }
        } message: {
            Text("This photo may give weaker results. Retaking in better lighting will improve your score accuracy.")
        }
    }
}

struct QualityCheckRow: View {
    let label: String
    let status: QualityStatus

    enum QualityStatus { case ok, warning, error }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(status == .ok ? .fcSuccess : .fcWarning)
                .font(.system(size: 14))
            Text(label)
                .font(.fcCaption)
                .foregroundColor(.fcTextPrimary)
        }
    }
}
