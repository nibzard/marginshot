import SwiftUI

// ABOUTME: Environment key for theme colors that adapt to color scheme
private struct ThemeColorsEnvironmentKey: EnvironmentKey {
    static let defaultValue: ThemeColors = ThemeColors(scheme: .light)
}

extension EnvironmentValues {
    var themeColors: ThemeColors {
        get { self[ThemeColorsEnvironmentKey.self] }
        set { self[ThemeColorsEnvironmentKey.self] = newValue }
    }
}

// ABOUTME: Adaptive theme colors that respond to iOS dark mode
struct ThemeColors {
    let scheme: ColorScheme
    var increasedContrast = false

    var accent: Color {
        if increasedContrast { return scheme == .dark ? Color(red: 0.5, green: 0.95, blue: 0.88) : Color(red: 0.0, green: 0.3, blue: 0.27) }
        return scheme == .dark ? Color(red: 0.35, green: 0.83, blue: 0.76) : Color(red: 0.02, green: 0.40, blue: 0.36)
    }

    var accentDeep: Color {
        Color(red: 0.11, green: 0.45, blue: 0.43)
    }

    var ink: Color { Color.primary }

    var surface: Color { Color(uiColor: .secondarySystemBackground) }

    var surfaceStrong: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    var glassBorder: Color {
        scheme == .dark
            ? Color.white.opacity(0.12)
            : Color.white.opacity(0.35)
    }

    var shadow: Color {
        scheme == .dark
            ? Color.black.opacity(0.4)
            : Color.black.opacity(0.18)
    }

    var overlayDark: Color {
        scheme == .dark
            ? Color.black.opacity(0.6)
            : Color.black.opacity(0.45)
    }

    var overlayLight: Color {
        scheme == .dark
            ? Color.white.opacity(0.15)
            : Color.white.opacity(0.25)
    }

    var backgroundTop: Color { Color(uiColor: .systemBackground) }

    var backgroundBottom: Color { Color(uiColor: .systemBackground) }

    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// ABOUTME: View modifier that injects theme colors into environment
private struct ThemeColorsModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var contrast

    func body(content: Content) -> some View {
        content
            .environment(\.themeColors, ThemeColors(scheme: colorScheme, increasedContrast: contrast == .increased))
    }
}

// ABOUTME: Static API for accessing theme colors that adapt to color scheme
enum AppTheme {
    static var accent: Color { Color(red: 0.16, green: 0.58, blue: 0.52) }
    static var accentDeep: Color { Color(red: 0.11, green: 0.45, blue: 0.43) }
    static var ink: Color { .primary }
    static var surface: Color { Color.white.opacity(0.82) }
    static var surfaceStrong: Color { Color.white.opacity(0.9) }
    static var glassBorder: Color { Color.white.opacity(0.35) }
    static var shadow: Color { Color.black.opacity(0.18) }
    static var overlayDark: Color { Color.black.opacity(0.45) }
    static var overlayLight: Color { Color.white.opacity(0.25) }
    static var backgroundTop: Color { Color(uiColor: .systemBackground) }
    static var backgroundBottom: Color { Color(uiColor: .systemBackground) }

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// ABOUTME: Helper to apply adaptive theme to any view
extension View {
    func themed() -> some View {
        self.modifier(ThemeColorsModifier())
    }
}

enum AppTypography {
    static let hero = Font.largeTitle.bold()
    static let title = Font.title2.bold()
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let caption = Font.caption
    static let captionBold = Font.caption.weight(.semibold)
    static let mono = Font.system(.caption, design: .monospaced)
}

enum AppSpacing {
    static let content: CGFloat = 20
    static let section: CGFloat = 24
    static let item: CGFloat = 12
}

struct SettingsToolbar: ViewModifier {
    @State private var presented = false
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { presented = true }
                    .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $presented) { SettingsView() }
    }
}

extension View {
    func settingsToolbar() -> some View { modifier(SettingsToolbar()) }
}
