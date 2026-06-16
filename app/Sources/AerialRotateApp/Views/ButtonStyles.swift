import SwiftUI

/// Hover feedback for borderless icon buttons. A soft rounded background fades in
/// under the label on hover (and deepens on press). The background is laid out
/// with negative padding so it grows OUTWARD from the label, meaning the icon or
/// text never moves, only a halo appears behind it.
struct HoverIconButtonStyle: ButtonStyle {
    var padding: CGFloat = 5
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, padding: padding, cornerRadius: cornerRadius)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let padding: CGFloat
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            let level = configuration.isPressed ? 0.16 : (hovering ? 0.10 : 0.0)
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(level))
                        .padding(-padding)
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A borderless control given just enough chrome to read as a button: a faint
/// always-on rounded fill (no border) that strengthens on hover and press. Same
/// negative-padding trick, so the label keeps its exact position.
struct SoftButtonStyle: ButtonStyle {
    var padding: CGFloat = 6
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        SoftBody(configuration: configuration, padding: padding, cornerRadius: cornerRadius)
    }

    private struct SoftBody: View {
        let configuration: ButtonStyleConfiguration
        let padding: CGFloat
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            let fill = configuration.isPressed ? 0.16 : (hovering ? 0.12 : 0.06)
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(fill))
                        .padding(-padding)
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
