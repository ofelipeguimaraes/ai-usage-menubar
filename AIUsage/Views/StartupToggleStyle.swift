import SwiftUI

/// Draws both parts of the switch on the first frame inside the settings panel.
struct StartupToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.3))
                Circle()
                    .fill(.white)
                    .padding(2)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .frame(width: 44, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Launch at Login")
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
