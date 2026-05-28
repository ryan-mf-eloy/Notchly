import SwiftUI

private struct IslandDesignModeEnvironmentKey: EnvironmentKey {
    static let defaultValue: IslandDesignMode = .solid
}

extension EnvironmentValues {
    var islandDesignMode: IslandDesignMode {
        get { self[IslandDesignModeEnvironmentKey.self] }
        set { self[IslandDesignModeEnvironmentKey.self] = newValue }
    }
}

enum MinimalTheme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.055)
    static let sidebar = Color(red: 0.075, green: 0.075, blue: 0.075)
    static let surface = Color.white.opacity(0.055)
    static let selected = Color.white.opacity(0.115)
    static let divider = Color.white.opacity(0.075)
    static let primary = Color.white.opacity(0.9)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let success = Color(red: 0.32, green: 0.78, blue: 0.48)

    static let historyChrome = Color(red: 0.055, green: 0.052, blue: 0.050)
    static let historyChromeRaised = Color(red: 0.092, green: 0.087, blue: 0.083)
    static let historyChromeText = Color.white.opacity(0.92)
    static let historyChromeMuted = Color.white.opacity(0.52)
    static let historyCanvas = Color(red: 0.818, green: 0.796, blue: 0.742)
    static let historySurface = Color(red: 0.915, green: 0.895, blue: 0.842)
    static let historyCard = Color(red: 0.965, green: 0.947, blue: 0.902)
    static let historyCardPressed = Color(red: 0.888, green: 0.858, blue: 0.794)
    static let historyBorder = Color(red: 0.625, green: 0.572, blue: 0.489).opacity(0.26)
    static let historyInk = Color(red: 0.105, green: 0.095, blue: 0.078)
    static let historyText = Color(red: 0.248, green: 0.226, blue: 0.188)
    static let historyMuted = Color(red: 0.438, green: 0.397, blue: 0.327)
    static let historyFaint = Color(red: 0.606, green: 0.552, blue: 0.462)
    static let historyAccent = Color(red: 0.782, green: 0.339, blue: 0.151)
    static let historyAccentSoft = Color(red: 0.930, green: 0.644, blue: 0.445).opacity(0.30)
    static let historyShadow = Color.black.opacity(0.16)
}

struct IslandGlassFill<S: Shape>: View {
    var shape: S
    var mode: IslandDesignMode
    var solidOpacity: Double
    var glassTintOpacity: Double
    var glassFallbackOpacity: Double
    var interactive = true

    var body: some View {
        if mode == .liquidGlass {
            liquidGlassFill
        } else {
            shape.fill(Color.white.opacity(solidOpacity))
        }
    }

    @ViewBuilder
    private var liquidGlassFill: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                Color.clear
                    .glassEffect(
                        .regular
                            .tint(Color.white.opacity(glassTintOpacity))
                            .interactive(interactive),
                        in: shape
                    )
            }
            .background {
                shape.fill(Color.white.opacity(glassFallbackOpacity))
            }
        } else {
            shape.fill(Color.white.opacity(glassFallbackOpacity))
        }
    }
}

struct MinimalButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isDestructive ? MinimalTheme.primary : MinimalTheme.primary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? Color.white.opacity(0.14) : Color.white.opacity(isDestructive ? 0.1 : 0.075))
            )
            .overlay(Capsule().stroke(MinimalTheme.divider, lineWidth: 0.6))
            .contentShape(Rectangle())
    }
}

struct MinimalIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MinimalTheme.secondary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(configuration.isPressed ? Color.white.opacity(0.14) : Color.white.opacity(0.075)))
            .overlay(Circle().stroke(MinimalTheme.divider, lineWidth: 0.6))
            .contentShape(Rectangle())
    }
}

struct HistoryToolbarButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isDestructive ? MinimalTheme.historyAccent : MinimalTheme.historyChromeText)
            .padding(.horizontal, 12)
            .frame(height: 31)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? Color.white.opacity(0.16) : Color.white.opacity(isDestructive ? 0.075 : 0.095))
            )
            .overlay(
                Capsule()
                    .stroke(isDestructive ? MinimalTheme.historyAccent.opacity(0.34) : Color.white.opacity(0.12), lineWidth: 0.7)
            )
            .contentShape(Rectangle())
    }
}

struct MinimalSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MinimalTheme.tertiary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MinimalTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MinimalTheme.divider, lineWidth: 0.6)
            )
        }
    }
}

struct MinimalDivider: View {
    var body: some View {
        Rectangle()
            .fill(MinimalTheme.divider)
            .frame(height: 0.6)
            .padding(.leading, 38)
    }
}
