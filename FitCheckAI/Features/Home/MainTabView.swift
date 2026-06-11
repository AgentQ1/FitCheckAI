import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            tabContent
                .environmentObject(appState)

            if !appState.hideTabBar {
                CustomTabBar()
                    .environmentObject(appState)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: appState.hideTabBar)
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $appState.showCheckFlow) {
            CheckFlowView().environmentObject(appState)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch appState.selectedTab {
        case .home:
            HomeView()
        case .fitCheck:
            // FAB owns the camera flow; if a tab ever lands here, just show Home.
            HomeView()
        case .arena:
            ArenaView()
        case .trends:
            TrendsView()
        case .saved:
            SavedLooksView()
        case .profile:
            ProfileView()
        }
    }
}

struct CustomTabBar: View {
    @EnvironmentObject var appState: AppState

    private let visibleTabs: [TabItem] = [.home, .arena, .fitCheck, .profile]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                if tab.isFAB {
                    Spacer()
                    fabButton
                    Spacer()
                } else {
                    tabButton(for: tab)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, safeAreaBottom())
        .background(
            Color.fcSurface2
                .overlay(
                    Rectangle()
                        .fill(Color.fcTextSecondary.opacity(0.15))
                        .frame(height: 1),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var fabButton: some View {
        Button(action: { appState.showCheckFlow = true }) {
            ZStack {
                Circle()
                    .fill(Color.fcAccent)
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.fcShadow, radius: 14, y: 4)
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Color.fcAccentCream)
            }
        }
        .buttonStyle(HapticButtonStyle())
        .offset(y: -20)
    }

    private func tabButton(for tab: TabItem) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                appState.selectedTab = tab
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 22))
                    .foregroundColor(appState.selectedTab == tab ? .fcAccent : Color.fcTextSecondary.opacity(0.7))
                Text(tab.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(appState.selectedTab == tab ? .fcAccent : Color.fcTextSecondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private func safeAreaBottom() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first?.safeAreaInsets.bottom ?? 0
    }
}
