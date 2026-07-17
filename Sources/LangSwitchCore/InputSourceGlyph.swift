import Foundation

/// Derives the short label the near-cursor HUD renders for an input
/// source, from its primary language code with a fallback to its localized name.
public func indicatorGlyph(languageCode: String?, localizedName: String) -> String {
    let code = languageCode?.lowercased()
    switch code {
    case "th": return "ก"
    case "en": return "Aa"
    default: break
    }
    if let code, !code.isEmpty {
        return String(code.prefix(while: { $0 != "-" })).uppercased()
    }
    return localizedName.first.map(String.init) ?? "?"
}
