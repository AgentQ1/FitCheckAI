import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCheckFlow = false

    var body: some View {
        ZStack(alignment: .bottom) {
            tabContent
                .environmentObject(appState)

            CustomTabBar(showCheckFlow: $showCheckFlow)
                .environmentObject(appState)
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $showCheckFlow) {
            CheckFlowView().environmentObject(appState)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch appState.selectedTab {
        case .home:
            HomeView()
        case .fitCheck:
            HomeView() // FAB handles this; tab bar triggers sheet instead
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
    @Binding var showCheckFlow: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TabItem.allCases, id: \.self) { tab in
                if tab.isFAB {
                    Spacer()
                    Button(action: { showCheckFlow = true }) {
                        ZStack {
                            Circle()
                                .fill(Color.fcAccent)
                                .frame(width: 56, height: 56)
                                .shadow(color: Color.fcAccent.opacity(0.5), radius: 12)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.fcBackground)
                        }
                    }
                    .buttonStyle(HapticButtonStyle())
                    .offset(y: -14)
                    Spacer()
                } else {
                    tabButton(for: tab)
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, safeAreaBottom())
        .background(
            Color.fcSurface
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(for tab: TabItem) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                appState.selectedTab = tab
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20))
                    .foregroundColor(appState.selectedTab == tab ? .fcAccent : .fcTextSecondary)
                Text(tab.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(appState.selectedTab == tab ? .fcAccent : .fcTextSecondary)
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
