import SwiftUI

struct PremiumLockOverlay: View {
    var label: String = "Premium"
    var onUpgrade: (() -> Void)?

    var body: some View {
        ZStack {
            Color.fcBackground.opacity(0.85)
                .blur(radius: 2)

            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.fcGold)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.fcGold)
                if let onUpgrade {
                    Button("Unlock ✦") {
                        onUpgrade()
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.fcBackground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.fcGold)
                    .clipShape(Capsule())
                }
            }
        }
    }
}

struct PremiumUpsellBanner: View {
    var message: String = "Unlock all lens scores + AI outfit upgrades"
    var onUpgrade: (() -> Void)

    var body: some View {
        HStack(spacing: 12) {
            Text("✦")
                .font(.system(size: 20))
                .foregroundColor(.fcGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Go Premium")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.fcGold)
                Text(message)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }
            Spacer()
            Button(action: onUpgrade) {
                Text("Upgrade →")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.fcBackground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.fcGold)
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(Color.fcGold.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.fcGold.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(14)
    }
}
