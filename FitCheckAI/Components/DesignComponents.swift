import SwiftUI

// MARK: - AppCard ViewModifier

struct AppCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.fcSurface)
            .cornerRadius(20)
            .shadow(color: Color.fcShadow, radius: 16, x: 0, y: 6)
    }
}

extension View {
    func appCard() -> some View {
        modifier(AppCard())
    }
}

// MARK: - PrimaryButtonStyle

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fcBodyBold)
            .foregroundColor(Color.fcAccentCream)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.fcAccent.opacity(configuration.isPressed ? 0.8 : 1.0))
            .cornerRadius(14)
            .shadow(color: Color.fcShadow, radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - SecondaryButtonStyle

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fcBodyBold)
            .foregroundColor(Color.fcAccent)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.fcAccentCream.opacity(configuration.isPressed ? 0.8 : 1.0))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.fcAccent.opacity(0.4), lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundColor(Color.fcTextSecondary.opacity(0.5))
            Text(title)
                .font(.fcTitle)
                .foregroundColor(Color.fcTextPrimary)
            Text(subtitle)
                .font(.fcBody)
                .foregroundColor(Color.fcTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - FCSectionTitle

struct FCSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.fcTitle)
            .foregroundColor(Color.fcTextPrimary)
    }
}
