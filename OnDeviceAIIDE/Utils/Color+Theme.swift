// MARK: - Design System / Color Theme
// OnDeviceAIIDE/Utils/Color+Theme.swift
//
// Premium, distraction-free color palette.
// NO neon accents, NO glowing gradients, NO heavy purple.
// Palette: Muted Charcoal, Deep Crimson, Medium-Dark Greys.

import SwiftUI

// MARK: - App Colors

extension Color {
    // MARK: Backgrounds
    
    /// Deepest background layer (#1A1D21)
    static let appBackground = Color(hex: "#1A1D21")
    /// Panel/surface background (#22252A)
    static let appSurface = Color(hex: "#22252A")
    /// Elevated surface for cards/sections (#2A2E35)
    static let appSurfaceHighlight = Color(hex: "#2A2E35")
    /// Active/selected surface (#3A3F47)
    static let appSurfaceActive = Color(hex: "#3A3F47")
    /// Input field backgrounds (#32363D)
    static let appInputBackground = Color(hex: "#32363D")
    
    // MARK: Accents
    
    /// Primary accent - Deep Crimson (#8B0000)
    static let appCrimson = Color(hex: "#8B0000")
    /// Secondary accent - Dark Red (#4A0E17)
    static let appCrimsonDark = Color(hex: "#4A0E17")
    /// Accent hover/pressed state (#A01020)
    static let appCrimsonLight = Color(hex: "#A01020")
    /// Subtle accent for indicators (#6B0010)
    static let appCrimsonMuted = Color(hex: "#6B0010")
    
    // MARK: Text
    
    /// Primary text (#E8E6E3)
    static let appTextPrimary = Color(hex: "#E8E6E3")
    /// Secondary text (#9A9590)
    static let appTextSecondary = Color(hex: "#9A9590")
    /// Tertiary/muted text (#6B6560)
    static let appTextMuted = Color(hex: "#6B6560")
    /// Disabled text (#4A4540)
    static let appTextDisabled = Color(hex: "#4A4540")
    /// Inverted text on accent backgrounds
    static let appTextOnAccent = Color(hex: "#F5F3F0")
    
    // MARK: Semantic
    
    /// Success state
    static let appSuccess = Color(hex: "#2D6B2D")
    /// Warning state
    static let appWarning = Color(hex: "#8B6914")
    /// Error state
    static let appError = Color(hex: "#8B2020")
    /// Info state
    static let appInfo = Color(hex: "#1E4A6B")
    
    // MARK: Borders & Dividers
    
    /// Default border (#3A3F47)
    static let appBorder = Color(hex: "#3A3F47")
    /// Subtle divider (#2E3238)
    static let appDivider = Color(hex: "#2E3238")
    /// Focus ring (crimson-based)
    static let appFocusRing = Color(hex: "#8B0000").opacity(0.5)
    
    // MARK: Syntax Highlighting
    
    struct Syntax {
        static let keyword = Color(hex: "#C7455C")     // Crimson-tinted red
        static let string = Color(hex: "#7D9A6D")     // Muted sage green
        static let comment = Color(hex: "#6B6560")    // Grey
        static let type = Color(hex: "#8F9ABE")       // Dusty blue
        static let function = Color(hex: "#B89A6A")   // Warm amber
        static let number = Color(hex: "#9A7DB5")     // Muted lavender
        static let property = Color(hex: "#A0A8B8")   // Light steel
        static let `operator` = Color(hex: "#C7455C") // Same as keyword
        static let background = Color(hex: "#1A1D21") // Same as app background
    }
}

// MARK: - Hex Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - View Modifiers

/// Applies the app's dark theme surface styling
struct SurfaceModifier: ViewModifier {
    let isActive: Bool
    let isHovering: Bool
    
    func body(content: Content) -> some View {
        content
            .background(
                isActive ? Color.appSurfaceActive :
                isHovering ? Color.appSurfaceHighlight :
                Color.appSurface
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.appCrimson.opacity(0.3) : Color.appBorder, lineWidth: 0.5)
            )
    }
}

/// Primary button style with deep crimson accent
struct CrimsonButtonStyle: ButtonStyle {
    let isProminent: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .default))
            .foregroundColor(isProminent ? .appTextOnAccent : .appTextPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                isProminent
                ? (configuration.isPressed ? Color.appCrimsonLight : Color.appCrimson)
                : (configuration.isPressed ? Color.appSurfaceActive : Color.appSurfaceHighlight)
            )
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.appBorder.opacity(0.5), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Panel container with consistent styling
struct PanelContainer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.appSurface)
            .overlay(
                Rectangle()
                    .stroke(Color.appDivider, lineWidth: 0.5)
            )
    }
}

// MARK: - View Extensions

extension View {
    func surfaceStyle(isActive: Bool = false, isHovering: Bool = false) -> some View {
        modifier(SurfaceModifier(isActive: isActive, isHovering: isHovering))
    }
    
    func panelStyle() -> some View {
        modifier(PanelContainer())
    }
    
    func crimsonButton(isProminent: Bool = true) -> some View {
        buttonStyle(CrimsonButtonStyle(isProminent: isProminent))
    }
}

// MARK: - App Theme Environment

struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme()
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Central theme configuration
@Observable
class AppTheme {
    var colorScheme: ColorScheme = .dark
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 1.6
    var editorFontName: String = "SFMono-Regular"
    var uiFontName: String = "SFPro-Regular"
    
    var editorFont: Font {
        Font.custom(editorFontName, size: fontSize)
    }
    
    var editorUIFont: UIFont {
        UIFont(name: editorFontName, size: fontSize) ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
