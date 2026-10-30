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

/// Swift's `Character`s: extended grapheme clusters ("e" + a combining accent is one).
pub fn characters(s: &str) -> Vec<&str> {
    use unicode_segmentation::UnicodeSegmentation;
    s.graphemes(true).collect()
}

/// `Character.isLetter`: the first scalar is alphabetic.
pub fn is_letter(c: &str) -> bool {
    c.chars().next().is_some_and(char::is_alphabetic)
}

/// `Character.isNumber`: the first scalar has a numeric type.
pub fn is_number(c: &str) -> bool {
    c.chars().next().is_some_and(char::is_numeric)
}

/// `Character.isUppercase`: changed by lowercasing, not by uppercasing.
pub fn is_uppercase(c: &str) -> bool {
    c.to_lowercase() != c && c.to_uppercase() == c
}

/// `Character.isLowercase`: changed by uppercasing, not by lowercasing.
pub fn is_lowercase(c: &str) -> bool {
    c.to_uppercase() != c && c.to_lowercase() == c
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
        assert_eq!(characters("cafe\u{301}!"), ["c", "a", "f", "e\u{301}", "!"]);
        assert!(is_letter("e\u{301}") && !is_letter("1") && is_number("7"));
        assert!(is_uppercase("A") && !is_uppercase("a") && !is_uppercase("1") && is_lowercase("ß"));
    }
}

/// `String.capitalized`: each word's first letter in upper case, the rest in lower. A letter
/// starts a word unless it follows a letter or an apostrophe ("Don't", "Rock-N-Roll", "3D").
pub fn capitalized(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_word = false;
    for c in s.chars() {
        if c.is_alphabetic() {
            if in_word {
                out.extend(c.to_lowercase());
            } else {
                out.extend(c.to_uppercase());
            }
            in_word = true;
        } else {
            in_word = in_word && matches!(c, '\'' | '’');
            out.push(c);
        }
    }
    out
}

/// Sorts as `localizedStandardCompare` does, the way Finder lists names: numbers by their value;
/// spaces, then punctuation, symbols, digits, letters; accents and then case (lower first) only
/// decide between names otherwise the same. Compare two keys with `<`.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct StandardKey {
    primary: Vec<u32>,
    secondary: Vec<u32>,
    tertiary: Vec<u32>,
    text: String,
}

/// Spaces, punctuation and symbols in the order Foundation sorts them, the ASCII ones checked
/// against it; the others take their places in the Unicode collation order Foundation follows.
const MARKS_ORDER: &str =
    " _‿-‐‑‒–—―,;:!¡?¿.…·'‘’‚‹›\"“”„«»()[]{}§¶@*/\\&#%‰†‡•`´˜^¯¨°©®+±÷×<=>¬|¦~¤¢$£¥€";
/// How accents sort.
const ACCENTS_ORDER: [u32; 13] = [
    0x301, 0x300, 0x306, 0x302, 0x30C, 0x30A, 0x308, 0x30B, 0x303, 0x307, 0x328, 0x327, 0x304,
];

const DIGITS: u32 = 1000;
const LETTERS: u32 = 2000;
const OTHER_LETTERS: u32 = 10_000;

/// Letters that aren't a base letter and an accent, but sort as if they were (or between letters).
fn special_letter(c: char) -> Option<(&'static str, u32, u32)> {
    // Base letters, secondary, tertiary.
    Some(match c {
        'ß' => ("ss", 0, 2),
        'æ' => ("ae", 0, 2),
        'œ' => ("oe", 0, 2),
        'ø' => ("o", 0x338, 0),
        'đ' => ("d", 0x335, 0),
        'ł' => ("l", 0x335, 0),
        _ => return None,
    })
}

fn latin(c: char) -> Option<u32> {
    match c {
        'a'..='z' => Some(LETTERS + (c as u32 - 'a' as u32) * 100),
        // Between the letters they follow.
        'ð' => Some(LETTERS + 3 * 100 + 50),
        'ı' => Some(LETTERS + 8 * 100 + 50),
        'ŋ' => Some(LETTERS + 13 * 100 + 50),
        'þ' => Some(LETTERS + 25 * 100 + 50),
        _ => None,
    }
}

impl StandardKey {
    pub fn new(s: &str) -> StandardKey {
        use unicode_normalization::UnicodeNormalization;
        use unicode_normalization::char::is_combining_mark;
        let mut key = StandardKey {
            primary: Vec::with_capacity(s.len()),
            secondary: Vec::with_capacity(s.len()),
            tertiary: Vec::with_capacity(s.len()),
            text: s.to_string(),
        };
        let chars: Vec<char> = s.nfd().collect();
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            i += 1;
            if c.is_ascii_digit() {
                let from = i - 1;
                while i < chars.len() && chars[i].is_ascii_digit() {
                    i += 1;
                }
                let run = &chars[from..i];
                let zeros = run.iter().take_while(|&&d| d == '0').count();
                let digits = if zeros == run.len() {
                    &run[run.len() - 1..]
                } else {
                    &run[zeros..]
                };
                key.primary.push(DIGITS);
                key.primary.push(digits.len() as u32);
                key.primary.extend(digits.iter().map(|&d| d as u32));
                key.secondary.push(0);
                key.tertiary.push(zeros as u32);
                continue;
            }
            if is_combining_mark(c) {
                let cp = c as u32;
                let weight = ACCENTS_ORDER
                    .iter()
                    .position(|&a| a == cp)
                    .map_or(cp, |p| p as u32 + 1);
                key.secondary.push(weight);
                continue;
            }
            if c.is_control() && !c.is_whitespace() {
                continue;
            }
            // Compatibility forms (full-width, ligatures, no-break spaces) sort after the plain ones.
            let plain: Vec<char> = std::iter::once(c).nfkd().collect();
            let compatible = plain.len() != 1 || plain[0] != c;
            for p in plain {
                key.push(p, compatible);
            }
        }
        key
    }

    fn push(&mut self, c: char, compatible: bool) {
        let lower = c.to_lowercase().next().unwrap_or(c);
        let upper = u32::from(lower != c);
        let tertiary = upper + if compatible { 2 } else { 0 };
        if let Some((letters, secondary, extra)) = special_letter(lower) {
            for (n, l) in letters.chars().enumerate() {
                self.primary.push(latin(l).unwrap_or(LETTERS));
                self.secondary.push(0);
                if n == 0 && secondary != 0 {
                    self.secondary.push(secondary);
                }
                self.tertiary.push(tertiary + extra);
            }
            return;
        }
        let primary = if let Some(p) = MARKS_ORDER.chars().position(|m| m == lower) {
            p as u32 + 1
        } else if c.is_whitespace() {
            1
        } else if let Some(l) = latin(lower) {
            l
        } else if lower.is_alphanumeric() {
            OTHER_LETTERS + lower as u32
        } else {
            // Other symbols, after those listed and before the digits.
            let listed = MARKS_ORDER.chars().count() as u32 + 1;
            listed + (lower as u32 % (DIGITS - listed))
        };
        self.primary.push(primary);
        self.secondary.push(0);
        self.tertiary.push(tertiary);
    }
}

#[cfg(test)]
mod names {
    use super::*;

    #[test]
    fn capitalised_as_foundation() {
        for (text, expected) in [
            ("don't stop", "Don't Stop"),
            ("rock-n-roll", "Rock-N-Roll"),
            ("3d sound", "3D Sound"),
            ("a_b c/d", "A_B C/D"),
            ("FOOD & DRINK / eat", "Food & Drink / Eat"),
            ("(paren) 2nd", "(Paren) 2Nd"),
            ("éa ÉB ñu", "Éa Éb Ñu"),
            ("mp3player", "Mp3Player"),
        ] {
            assert_eq!(capitalized(text), expected);
        }
    }

    #[test]
    fn sorted_as_foundation() {
        // Each pair as `localizedStandardCompare` orders it.
        for (a, b) in [
            ("a b", "ab"),
            ("a-b", "ab"),
            ("a_b", "a-b"),
            ("a.b", "ab"),
            ("a'b", "ab"),
            ("ab", "AB"),
            ("aB", "Ab"),
            ("a1", "a01"),
            ("a01", "a001"),
            ("a2", "a10"),
            ("e", "é"),
            ("é", "f"),
            ("ea", "éa"),
            ("éa", "eb"),
            ("a 2", "a 10"),
            ("a1.5", "a1.10"),
            ("a", "A"),
            ("a", "B"),
            ("1", "a"),
            ("-", "1"),
            ("a b c", "ab"),
            ("ss", "ß"),
            ("oe", "œ"),
            ("o", "ø"),
            ("ø", "p"),
            ("i", "ı"),
            ("1", "１"),
            ("a", "Ａ"),
            ("a", "日本"),
            ("z", "я"),
            ("", "a"),
            ("0", "00"),
            ("9", "10"),
            ("7", "007"),
        ] {
            assert!(StandardKey::new(a) < StandardKey::new(b), "{a} < {b}");
        }
    }
}
