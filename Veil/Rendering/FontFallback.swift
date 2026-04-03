import CoreText

/// Resolves font fallback for characters missing from the primary font.
///
/// CoreText's `CTFontCreateForString` handles most fallback (e.g. CJK → PingFang),
/// but returns LastResort for BMP Private Use Area characters (U+E000-U+F8FF) even
/// when an installed Nerd Font covers them. To work around this, we probe for a
/// Nerd Font at startup using supplementary PUA characters (which CoreText handles
/// correctly), then use the discovered font for BMP PUA fallback.
nonisolated enum FontFallback {
    nonisolated(unsafe) private(set) static var nerdFontName: String?

    /// Probe for an installed Nerd Font by trying supplementary PUA characters
    /// from niche to popular. A font that covers niche characters is more likely
    /// to be a comprehensive Nerd Font with full icon coverage.
    static func probe() {
        if nerdFontName != nil { return }
        let probe = CTFontCreateWithName(
            ".AppleSystemUIFontMonospaced-Regular" as CFString, 16, nil)
        let probeChars: [Character] = [
            "\u{F1064}",  // 󱁤 nf-md-expand_all (deep supplementary PUA)
            "\u{F0A19}",  // 󰨙 nf-md-star (mid-range supplementary PUA)
            "\u{F0001}",  // 󰀁 nf-md-ab_testing (early supplementary PUA)
        ]
        for ch in probeChars {
            let text = String(ch)
            let fallback = CTFontCreateForString(
                probe, text as CFString,
                CFRange(location: 0, length: text.utf16.count))
            let name = CTFontCopyPostScriptName(fallback) as String
            if name != "LastResort" {
                nerdFontName = name
                return
            }
        }
    }

    /// Returns a font suitable for rendering the given text. If the provided font
    /// lacks glyphs, falls back to a system font or the probed Nerd Font.
    static func resolveFont(_ font: CTFont, for text: String) -> CTFont {
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        if CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) {
            return font
        }
        let fallback = CTFontCreateForString(
            font, text as CFString,
            CFRange(location: 0, length: utf16.count))
        let fallbackName = CTFontCopyPostScriptName(fallback) as String
        if fallbackName != "LastResort" {
            return fallback
        }
        if let cachedName = nerdFontName {
            return CTFontCreateWithName(cachedName as CFString, CTFontGetSize(font), nil)
        }
        return fallback
    }
}
