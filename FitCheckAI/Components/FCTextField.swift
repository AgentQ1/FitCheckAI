import SwiftUI

struct FCTextField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(isFocused ? .fcAccent : .fcTextSecondary)
                .frame(width: 20)
            TextField(placeholder, text: $text)
                .font(.fcBody)
                .foregroundColor(.fcTextPrimary)
                .tint(.fcAccent)
                .autocorrectionDisabled()
                .focused($isFocused)
        }
        .padding(14)
        .background(Color.fcSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Color.fcAccent : Color.fcTextSecondary.opacity(0.2), lineWidth: 1.5)
        )
        .cornerRadius(12)
        .animation(.spring(response: 0.3), value: isFocused)
    }
}
