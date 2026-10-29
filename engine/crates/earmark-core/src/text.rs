//! Foundation's character sets, so trimming matches the Swift code exactly.

/// `CharacterSet.whitespaces`: Unicode general category Zs, and tab.
pub fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// `CharacterSet.whitespacesAndNewlines`: the above plus newlines (U+000A–U+000D, U+0085,
/// U+2028, U+2029).
pub fn is_space_or_newline(c: char) -> bool {
    is_space(c)
        || matches!(
            c,
            '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

/// `trimmingCharacters(in: .whitespaces)`.
pub fn trim_spaces(s: &str) -> &str {
    s.trim_matches(is_space)
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim(s: &str) -> &str {
    s.trim_matches(is_space_or_newline)
}

/// Swift's `split(separator:maxSplits: 1).first ?? ""` (empty pieces are dropped).
pub fn first_piece(s: &str, separator: char) -> &str {
    s.splitn(2, separator).find(|p| !p.is_empty()).unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trimming() {
        assert_eq!(trim_spaces("\t a b \u{A0}"), "a b");
        assert_eq!(trim_spaces("\na\n"), "\na\n");
        assert_eq!(trim(" \r\n a \u{2028}"), "a");
        assert_eq!(first_piece("-x-y", '-'), "x-y");
        assert_eq!(first_piece("AMB-x", '-'), "AMB");
        assert_eq!(first_piece("", '_'), "");
    }
}
