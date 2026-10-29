//! File names and folders as the Swift app stores them. Foundation's file URLs give names in the
//! Mac file system's decomposed form (HFS+): "é" as "e" + a combining accent, except in
//! U+2000–U+2FFF, U+F900–U+FAFF and U+2F800–U+2FAFF, which stay as they are. The path itself is
//! kept as given. Checked against Foundation on macOS 27 (2026-10-29).

use std::path::Path;
use unicode_normalization::UnicodeNormalization;

fn kept_as_is(c: char) -> bool {
    matches!(c as u32, 0x2000..=0x2FFF | 0xF900..=0xFAFF | 0x2F800..=0x2FAFF)
}

/// The string decomposed as the Mac file system spells names.
pub fn file_system_form(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    let mut run = String::new();
    for c in s.chars() {
        if kept_as_is(c) {
            out.extend(run.nfd());
            run.clear();
            out.push(c);
        } else {
            run.push(c);
        }
    }
    out.extend(run.nfd());
    out
}

/// Text as Swift's `String ==` and dictionaries see it: canonically equivalent strings match.
pub fn canonical(s: &str) -> String {
    s.nfc().collect()
}

/// `URL(fileURLWithPath:).lastPathComponent`.
pub fn file_name(path: &str) -> String {
    file_system_form(
        &Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
    )
}

/// `URL.standardizedFileURL.path`: "." and ".." resolved, no trailing slash, in file-system form.
pub fn standardized(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            p => parts.push(p),
        }
    }
    file_system_form(&format!("/{}", parts.join("/")))
}

/// The folder of `file` inside `root`, e.g. "TSK-03/Footsteps/Gravel" ("" at the top, or when
/// the file isn't under `root`). `SoundRecord.relativeFolder`.
pub fn relative_folder(file: &str, root: &str) -> String {
    let parent = match file.rfind('/') {
        Some(0) => "/",
        Some(i) => &file[..i],
        None => "",
    };
    let dir = standardized(parent);
    let base = standardized(root);
    match dir.strip_prefix(&base) {
        Some(rest) => rest.trim_matches('/').to_string(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn as_foundation_spells_names() {
        // The same string as the Foundation check: É, Hangul and the rest decomposed, but ﬁ,
        // U+3008, U+F900 and U+2126 left alone.
        let name = file_name("/tmp/Café Ré/sub ö/Ève 한글 ﬁ 〈x〉 \u{F900} \u{2126}.mp3");
        let scalars: Vec<String> = name.chars().map(|c| format!("{:x}", c as u32)).collect();
        assert_eq!(
            scalars.join(" "),
            "45 300 76 65 20 1112 1161 11ab 1100 1173 11af 20 fb01 20 3008 78 3009 20 f900 20 2126 2e 6d 70 33"
        );
        assert_eq!(canonical("e\u{301}"), "é");
    }

    #[test]
    fn folders() {
        assert_eq!(relative_folder("/Lib/A/B/x.wav", "/Lib"), "A/B");
        assert_eq!(relative_folder("/Lib/x.wav", "/Lib/"), "");
        assert_eq!(relative_folder("/Other/x.wav", "/Lib"), "");
        assert_eq!(relative_folder("/Lib/./A/../B/x.wav", "/Lib"), "B");
        assert_eq!(relative_folder("/Café/Ré/x.wav", "/Café"), "Re\u{301}");
    }
}
