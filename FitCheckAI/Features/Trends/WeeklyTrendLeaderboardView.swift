import SwiftUI

// MARK: - Avatar

/// Circular profile photo with an initials fallback, matching the app's
/// beige/olive palette.
struct LeaderboardAvatar: View {
    let photoURL: String?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.fcAccent.opacity(0.15))

            if let urlString = photoURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView().tint(.fcTextSecondary)
                    default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        Text(String(name.prefix(1).uppercased()))
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundColor(.fcAccent)
    }
}

// MARK: - Rank Badge

/// Rank number, gold-tinted for the top three.
private struct RankBadge: View {
    let rank: Int

    var body: some View {
        Text("#\(rank)")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundColor(rank <= 3 ? .fcGold : .fcTextSecondary)
            .frame(minWidth: 30, alignment: .leading)
    }
}

// MARK: - Leaderboard Row

/// One user's row. `detailed` adds the "best score" stat for the full page.
struct LeaderboardRow: View {
    let rank: Int
    let entry: WeeklyLeaderboardEntry
    var detailed: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            RankBadge(rank: rank)
            LeaderboardAvatar(photoURL: entry.photoURL, name: entry.name, size: detailed ? 48 : 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.fitsLabel)
                    if detailed {
                        Text("•")
                        Text(String(format: "best %.1f", entry.bestScore))
                    }
                }
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
            }

            Spacer()

            Text(entry.pointsLabel)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.fcAccent)
        }
    }
}

// MARK: - Home Preview

/// Compact "This Week's Trend" leaderboard shown on the Home screen.
struct WeeklyTrendPreviewView: View {
    private let previewLimit = 3

    @EnvironmentObject var appState: AppState
    @State private var entries: [WeeklyLeaderboardEntry] = []
    @State private var isLoading = true
    @State private var showLeaderboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                FCSectionTitle(text: "This Week's Trend")
                Spacer()
                if !entries.isEmpty {
                    Button(action: { showLeaderboard = true }) {
                        HStack(spacing: 4) {
                            Text("View All")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.fcAccent)
                    }
                    .buttonStyle(HapticButtonStyle(style: .light))
                }
            }

            content
        }
        .navigationDestination(isPresented: $showLeaderboard) {
            WeeklyTrendLeaderboardView()
        }
        .task { await load() }
        // Reload the moment a new check finishes (CheckFlow bumps this once the
        // backend has written the new standing) so the score shows without a
        // manual pull-to-refresh.
        .onChange(of: appState.weeklyTrendRefreshToken) { _, _ in
            Task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.fcSurface)
                .frame(height: 150)
                .overlay(ProgressView().tint(.fcTextSecondary))
        } else if entries.isEmpty {
            emptyState
        } else {
            Button(action: { showLeaderboard = true }) {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(previewLimit).enumerated()), id: \.element.id) { index, entry in
                        LeaderboardRow(rank: index + 1, entry: entry)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        if index < min(previewLimit, entries.count) - 1 {
                            Divider().background(Color.fcTextSecondary.opacity(0.12))
                                .padding(.leading, 18)
                        }
                    }
                }
                .padding(.vertical, 4)
                .appCard()
            }
            .buttonStyle(HapticButtonStyle(style: .light))
        }
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "trophy")
                .font(.system(size: 26))
                .foregroundColor(.fcTextSecondary.opacity(0.5))
            Text("No weekly trend yet. Upload your fit to enter the leaderboard.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .appCard()
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            entries = try await WeeklyLeaderboardService.fetchTopEntries(limit: previewLimit)
        } catch {
            print("[WeeklyTrendPreview] load failed: \(error.localizedDescription)")
            entries = []
        }
        isLoading = false
    }
}

// MARK: - Full Leaderboard Page

/// Full weekly leaderboard, ranked by total rating points earned this week.
struct WeeklyTrendLeaderboardView: View {
    private let pageLimit = 50

    @State private var entries: [WeeklyLeaderboardEntry] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(.fcAccent).scaleEffect(1.4)
            } else if entries.isEmpty {
                EmptyStateView(
                    icon: "trophy",
                    title: "No weekly trend yet",
                    subtitle: "Upload your fit to enter the leaderboard."
                )
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            LeaderboardRow(rank: index + 1, entry: entry, detailed: true)
                                .padding(16)
                                .appCard()
                        }
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("This Week's Trend")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            entries = try await WeeklyLeaderboardService.fetchTopEntries(limit: pageLimit)
        } catch {
            print("[WeeklyTrendLeaderboard] load failed: \(error.localizedDescription)")
            entries = []
        }
        isLoading = false
    }
}
