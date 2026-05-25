import SwiftUI

struct TrendDetailView: View {
    let trend: WeeklyTrend
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    headerSection
                    tagSection
                    if !trend.outfitExamples.isEmpty { examplesSection }
                    dosAndDontsSection
                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }

            // Sticky CTA
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, Color.fcBackground], startPoint: .top, endPoint: .bottom)
                    .frame(height: 30)
                Button(action: { onApply(); dismiss() }) {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 20))
                        Text("Apply This Trend to My Fit Check")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundColor(.fcBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.fcAccent)
                    .cornerRadius(16)
                    .shadow(color: Color.fcAccent.opacity(0.4), radius: 12, y: 4)
                }
                .buttonStyle(HapticButtonStyle())
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .background(Color.fcBackground)
            }
        }
        .navigationTitle(trend.title)
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundColor(.fcAccent)
                Text(weekLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.fcAccent)
            }
            Text(trend.shortDescription)
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !trend.styleTags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Style Tags")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(trend.styleTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.fcAccent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.fcAccent.opacity(0.1))
                                    .overlay(Capsule().stroke(Color.fcAccent.opacity(0.3), lineWidth: 1))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            if !trend.colors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Key Colors")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(trend.colors, id: \.self) { color in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.fcSurface2)
                                        .frame(width: 8, height: 8)
                                    Text(color)
                                        .font(.system(size: 13))
                                        .foregroundColor(.fcTextPrimary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.fcSurface)
                                .cornerRadius(10)
                            }
                        }
                    }
                }
            }
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outfit Examples")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)

            VStack(spacing: 10) {
                ForEach(trend.outfitExamples, id: \.self) { example in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "tshirt.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.fcAccent)
                            .frame(width: 20)
                            .padding(.top, 2)
                        Text(example)
                            .font(.fcBody)
                            .foregroundColor(.fcTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(Color.fcSurface)
                    .cornerRadius(14)
                }
            }
        }
    }

    private var dosAndDontsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Style Rules")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)

            HStack(alignment: .top, spacing: 12) {
                dosColumn
                dontsColumn
            }
        }
    }

    private var dosColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.fcSuccess)
                    .font(.system(size: 14))
                Text("Do")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.fcTextPrimary)
            }
            ForEach(trend.dos, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.fcSuccess)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(item)
                        .font(.system(size: 13))
                        .foregroundColor(.fcTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.fcSuccess.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcSuccess.opacity(0.2), lineWidth: 1))
        .cornerRadius(16)
    }

    private var dontsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.fcError)
                    .font(.system(size: 14))
                Text("Don't")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.fcTextPrimary)
            }
            ForEach(trend.donts, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.fcError)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(item)
                        .font(.system(size: 13))
                        .foregroundColor(.fcTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.fcError.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcError.opacity(0.2), lineWidth: 1))
        .cornerRadius(16)
    }

    private var weekLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "Week of \(formatter.string(from: trend.weekStartDate))"
    }
}
