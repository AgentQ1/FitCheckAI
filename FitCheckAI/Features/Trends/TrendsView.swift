import SwiftUI
import FirebaseFirestore

struct TrendsView: View {
    @EnvironmentObject var appState: AppState
    @State private var trends: [WeeklyTrend] = []
    @State private var isLoading = true
    @State private var selectedTrend: WeeklyTrend?
    @State private var showDetail = false
    @State private var appliedTrend: WeeklyTrend?

    private let db = Firestore.firestore()

    var currentTrend: WeeklyTrend? { trends.first }
    var pastTrends: [WeeklyTrend] { trends.count > 1 ? Array(trends.dropFirst()) : [] }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if trends.isEmpty {
                    emptyView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if let trend = currentTrend {
                                heroTrendCard(trend: trend)
                            }
                            if !pastTrends.isEmpty {
                                pastTrendsSection
                            }
                            Spacer(minLength: 100)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    .refreshable { await loadTrends() }
                }
            }
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showDetail) {
                if let trend = selectedTrend {
                    TrendDetailView(trend: trend, onApply: {
                        appliedTrend = trend
                        appState.showCheckFlow = true
                    })
                    .environmentObject(appState)
                }
            }
        }
        .task { await loadTrends() }
    }

    // MARK: - Subviews

    private func heroTrendCard(trend: WeeklyTrend) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero gradient header
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color.fcAccent2, Color.fcAccent.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 200)
                .cornerRadius(20, corners: [.topLeft, .topRight])

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundColor(.fcAccent)
                        Text("This Week's Trend")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.fcAccent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.fcAccent.opacity(0.12))
                    .cornerRadius(10)

                    Text(trend.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.fcTextPrimary)
                        .lineLimit(2)
                }
                .padding(20)
            }

            // Content below gradient
            VStack(alignment: .leading, spacing: 16) {
                Text(trend.shortDescription)
                    .font(.fcBody)
                    .foregroundColor(.fcTextSecondary)
                    .lineLimit(3)

                // Style tags
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(trend.styleTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.fcAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.fcAccent.opacity(0.1))
                                .overlay(
                                    Capsule().stroke(Color.fcAccent.opacity(0.3), lineWidth: 1)
                                )
                                .clipShape(Capsule())
                        }
                    }
                }

                // Color palette
                if !trend.colors.isEmpty {
                    HStack(spacing: 8) {
                        Text("Colors:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.fcTextSecondary)
                        ForEach(trend.colors.prefix(4), id: \.self) { color in
                            Text(color)
                                .font(.system(size: 12))
                                .foregroundColor(.fcTextPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.fcSurface2)
                                .cornerRadius(8)
                        }
                    }
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: {
                        selectedTrend = trend
                        showDetail = true
                    }) {
                        Text("See Full Trend")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color.fcAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.fcAccentCream)
                            .cornerRadius(14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.fcAccent.opacity(0.35), lineWidth: 1.5))
                    }
                    .buttonStyle(HapticButtonStyle(style: .light))

                    Button(action: { appState.showCheckFlow = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13))
                            Text("Apply")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(Color.fcAccentCream)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.fcAccent)
                        .cornerRadius(14)
                    }
                    .buttonStyle(HapticButtonStyle())
                }
            }
            .padding(20)
            .background(Color.fcSurface)
            .cornerRadius(20, corners: [.bottomLeft, .bottomRight])
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.fcShadow, radius: 20, y: 8)
    }

    private var pastTrendsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Past Trends")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)

            ForEach(pastTrends) { trend in
                Button(action: {
                    selectedTrend = trend
                    showDetail = true
                }) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.fcSurface2)
                                .frame(width: 50, height: 50)
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 20))
                                .foregroundColor(.fcAccent)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trend.title)
                                .font(.fcBodyBold)
                                .foregroundColor(.fcTextPrimary)
                                .lineLimit(1)
                            Text(trend.shortDescription)
                                .font(.fcCaption)
                                .foregroundColor(.fcTextSecondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.fcTextSecondary)
                    }
                    .padding(14)
                    .background(Color.fcSurface)
                    .cornerRadius(16)
                    .shadow(color: Color.fcShadow, radius: 10, y: 4)
                }
                .buttonStyle(HapticButtonStyle(style: .light))
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .tint(.fcAccent)
                .scaleEffect(1.5)
            Text("Loading trends...")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 60))
                .foregroundColor(.fcTextSecondary.opacity(0.3))
            Text("Trends Coming Soon")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)
            Text("Weekly fashion trends will appear here. Check back soon!")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Data

    private func loadTrends() async {
        do {
            let snapshot = try await db.collection("weekly_trends")
                .order(by: "weekStartDate", descending: true)
                .limit(to: 10)
                .getDocuments()

            var loaded: [WeeklyTrend] = []
            for doc in snapshot.documents {
                if let trend = try? doc.data(as: WeeklyTrend.self) {
                    loaded.append(trend)
                }
            }
            await MainActor.run {
                trends = loaded
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

// MARK: - Corner radius helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
