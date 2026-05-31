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
    static let background = Color.black
    static let sidebar = Color.black
    static let surface = Color.white.opacity(0.055)
    static let selected = Color.white.opacity(0.115)
    static let divider = Color.white.opacity(0.075)
    static let primary = Color.white.opacity(0.9)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let settingsActive = Color(red: 0.28, green: 0.86, blue: 0.48)
    static let success = settingsActive
    static let destructive = Color(red: 1.0, green: 0.36, blue: 0.38)
    static let notchAccent = Color.white.opacity(0.9)
    static let settingsControl = Color.white.opacity(0.085)
    static let settingsControlPressed = Color.white.opacity(0.14)

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

enum SettingsLayout {
    static let labelWidth: CGFloat = 150
    static let rowGap: CGFloat = 12
    static let controlWidth: CGFloat = 286
    static let compactControlWidth: CGFloat = 258
    static let dividerInset: CGFloat = labelWidth + rowGap
    static let providerLogoFrame: CGFloat = 24
    static let providerLogoSize: CGFloat = 17
    static let compactProviderLogoFrame: CGFloat = 18
    static let compactProviderLogoSize: CGFloat = 15
}

struct SettingsMenuOption<Value: Hashable>: Identifiable {
    var id: String
    var value: Value
    var title: String
    var subtitle: String?
    var systemImage: String?
    var assetName: String?
    var monogram: String?
    var isUnavailable: Bool

    init(
        id: String? = nil,
        value: Value,
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        assetName: String? = nil,
        monogram: String? = nil,
        isUnavailable: Bool = false
    ) {
        self.id = id ?? String(describing: value)
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.assetName = assetName
        self.monogram = monogram
        self.isUnavailable = isUnavailable
    }
}

struct SettingsMenuSelector<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [SettingsMenuOption<Value>]
    var width: CGFloat = SettingsLayout.controlWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var selectedOption: SettingsMenuOption<Value>? {
        options.first { $0.value == selection } ?? options.first
    }

    var body: some View {
        Menu {
            if options.isEmpty {
                Text("No options")
            } else {
                ForEach(options) { option in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.88)) {
                            selection = option.value
                        }
                    } label: {
                        HStack(spacing: 8) {
                            SettingsOptionIcon(option: option, size: SettingsLayout.providerLogoSize)
                            Text(option.title)
                            if option.value == selection {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                if let selectedOption {
                    SettingsOptionIcon(option: selectedOption, size: SettingsLayout.providerLogoSize)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedOption.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(selectedOption.isUnavailable ? MinimalTheme.tertiary : MinimalTheme.primary)
                            .lineLimit(1)
                        if let subtitle = selectedOption.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(MinimalTheme.tertiary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("Select")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(MinimalTheme.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovering ? MinimalTheme.primary : MinimalTheme.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? MinimalTheme.settingsControlPressed : MinimalTheme.settingsControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovering ? Color.white.opacity(0.16) : MinimalTheme.divider, lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }
}

struct SettingsSegmentedSelector<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [SettingsMenuOption<Value>]
    var width: CGFloat = SettingsLayout.controlWidth

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) {
                        selection = option.value
                    }
                } label: {
                    HStack(spacing: 6) {
                        if option.systemImage != nil || option.assetName != nil || option.monogram != nil {
                            SettingsOptionIcon(option: option, size: SettingsLayout.compactProviderLogoSize, framed: false)
                        }
                        Text(option.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(selection == option.value ? MinimalTheme.primary : MinimalTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background {
                        if selection == option.value {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(MinimalTheme.settingsControlPressed)
                                .matchedGeometryEffect(id: "settings-segment", in: namespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(width: width, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(MinimalTheme.settingsControl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(MinimalTheme.divider, lineWidth: 0.7)
        )
    }
}

struct SettingsSecureField: View {
    @Binding var text: String
    var width: CGFloat = SettingsLayout.controlWidth

    var body: some View {
        SecureField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MinimalTheme.primary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .frame(width: width, height: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MinimalTheme.settingsControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MinimalTheme.divider, lineWidth: 0.7)
            )
    }
}

struct NotchlySwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? MinimalTheme.settingsActive.opacity(0.88) : MinimalTheme.settingsControlPressed)
                    .overlay(
                        Capsule()
                            .stroke(configuration.isOn ? MinimalTheme.settingsActive.opacity(0.34) : MinimalTheme.divider, lineWidth: 0.7)
                    )

                Circle()
                    .fill(configuration.isOn ? Color.white.opacity(0.94) : Color.white.opacity(0.62))
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.black.opacity(configuration.isOn ? 0.22 : 0.1), radius: 5, x: 0, y: 2)
                    .padding(3)
            }
            .frame(width: 42, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }
}

private struct SettingsOptionIcon<Value: Hashable>: View {
    var option: SettingsMenuOption<Value>
    var size: CGFloat
    var framed = true

    var body: some View {
        ZStack {
            if framed {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.075))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                    )
            }

            iconContent
                .frame(width: size, height: size)
        }
        .frame(
            width: framed ? SettingsLayout.providerLogoFrame : SettingsLayout.compactProviderLogoFrame,
            height: framed ? SettingsLayout.providerLogoFrame : SettingsLayout.compactProviderLogoFrame
        )
        .opacity(option.isUnavailable ? 0.54 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var iconContent: some View {
        if let assetName = option.assetName {
            Image(assetName)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipped()
        } else if let systemImage = option.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(MinimalTheme.primary)
        } else if let monogram = option.monogram {
            Text(monogram)
                .font(.system(size: size * 0.58, weight: .bold, design: .rounded))
                .foregroundStyle(MinimalTheme.primary)
                .minimumScaleFactor(0.7)
        } else {
            Circle()
                .fill(MinimalTheme.primary.opacity(0.82))
                .frame(width: size * 0.42, height: size * 0.42)
        }
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
