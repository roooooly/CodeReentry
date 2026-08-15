import AppKit
import SwiftUI

/// DevHub's visual language is intentionally quiet: a warm canvas establishes
/// hierarchy, white paper surfaces contain work, and semantic colors are saved
/// for state. This keeps dense operational screens readable without turning
/// every control into a competing grey rectangle.
enum DevHubTheme {
    static let accent = adaptive(
        light: NSColor(red: 0.43, green: 0.10, blue: 0.14, alpha: 1),
        dark: NSColor(red: 0.92, green: 0.48, blue: 0.52, alpha: 1)
    )
    static let deepAccent = adaptive(
        light: NSColor(red: 0.28, green: 0.055, blue: 0.08, alpha: 1),
        dark: NSColor(red: 0.98, green: 0.69, blue: 0.71, alpha: 1)
    )
    static let gold = adaptive(
        light: NSColor(red: 0.78, green: 0.49, blue: 0.13, alpha: 1),
        dark: NSColor(red: 0.96, green: 0.72, blue: 0.30, alpha: 1)
    )
    static let teal = adaptive(
        light: NSColor(red: 0.08, green: 0.43, blue: 0.39, alpha: 1),
        dark: NSColor(red: 0.33, green: 0.78, blue: 0.72, alpha: 1)
    )
    static let green = adaptive(
        light: NSColor(red: 0.16, green: 0.52, blue: 0.32, alpha: 1),
        dark: NSColor(red: 0.38, green: 0.79, blue: 0.51, alpha: 1)
    )
    static let blue = adaptive(
        light: NSColor(red: 0.18, green: 0.36, blue: 0.68, alpha: 1),
        dark: NSColor(red: 0.46, green: 0.64, blue: 0.98, alpha: 1)
    )
    static let ink = adaptive(
        light: NSColor(red: 0.12, green: 0.105, blue: 0.095, alpha: 1),
        dark: NSColor(red: 0.95, green: 0.93, blue: 0.90, alpha: 1)
    )
    static let secondaryInk = adaptive(
        light: NSColor(red: 0.35, green: 0.32, blue: 0.29, alpha: 1),
        dark: NSColor(red: 0.72, green: 0.69, blue: 0.65, alpha: 1)
    )
    static let canvasTop = adaptive(
        light: NSColor(red: 0.994, green: 0.986, blue: 0.968, alpha: 1),
        dark: NSColor(red: 0.105, green: 0.10, blue: 0.095, alpha: 1)
    )
    static let canvasBottom = adaptive(
        light: NSColor(red: 0.969, green: 0.949, blue: 0.905, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.072, blue: 0.069, alpha: 1)
    )
    static let card = adaptive(
        light: NSColor(white: 1, alpha: 0.92),
        dark: NSColor(red: 0.145, green: 0.14, blue: 0.135, alpha: 0.96)
    )
    static let subtleFill = adaptive(
        light: NSColor(red: 0.972, green: 0.958, blue: 0.93, alpha: 1),
        dark: NSColor(red: 0.19, green: 0.18, blue: 0.17, alpha: 1)
    )
    static let divider = adaptive(
        light: NSColor.black.withAlphaComponent(0.075),
        dark: NSColor.white.withAlphaComponent(0.10)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct DevHubPaperBackground: View {
    var body: some View {
        LinearGradient(
            colors: [DevHubTheme.canvasTop, DevHubTheme.canvasBottom.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct DevHubSectionHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.7)
                .foregroundStyle(DevHubTheme.accent)
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(DevHubTheme.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(DevHubTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DevHubCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(DevHubTheme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(DevHubTheme.divider, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.028), radius: 6, y: 2)
    }
}

struct DevHubMetricCard: View {
    let value: String
    let label: String
    let detail: String
    let systemImage: String
    var accent: Color = DevHubTheme.accent

    var body: some View {
        DevHubCard(padding: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(DevHubTheme.ink)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DevHubTheme.ink)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }
    }
}

struct DevHubPill: View {
    let text: String
    var color: Color = DevHubTheme.accent

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct DevHubLocalBadge: View {
    var body: some View {
        Label(String(localized: "本地资源台"), systemImage: "macwindow")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DevHubTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(DevHubTheme.accent.opacity(0.08), in: Capsule())
    }
}

private struct DevHubSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                DevHubTheme.card,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DevHubTheme.divider, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.028), radius: 6, y: 2)
    }
}

extension View {
    func devHubSurface(cornerRadius: CGFloat = 13) -> some View {
        modifier(DevHubSurfaceModifier(cornerRadius: cornerRadius))
    }
}
