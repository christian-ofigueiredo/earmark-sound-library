import Foundation

/// How a sound is named and found, the same in the app and the MCP server.
extension SoundRecord {
    /// The FX name if the file has one, else the file name without its extension.
    public var displayName: String {
        if let fxName, !fxName.isEmpty { return fxName }
        return url.deletingPathExtension().lastPathComponent
    }

    /// "Footsteps / Human".
    public var categoryText: String { ucsLabel?.capitalized ?? "" }

    /// "96 kHz · 24-bit · Stereo".
    public var formatText: String {
        var parts: [String] = []
        if let sr = sampleRate, sr > 0 {
            parts.append(sr.truncatingRemainder(dividingBy: 1000) == 0
                ? "\(Int(sr / 1000)) kHz" : String(format: "%.1f kHz", sr / 1000))
        }
        if let bits = bitsPerSample, bits > 0 { parts.append("\(bits)-bit") }
        if let ch = channels, ch > 0 { parts.append(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch) ch") }
        return parts.joined(separator: " · ")
    }

    /// What the search looks in, lowercased: the search matches sounds containing every word.
    public var searchText: String {
        [fileName, fxName, details, keywords, category, subcategory, catID, vendorLibrary, manufacturer, designer, folder]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }
}
