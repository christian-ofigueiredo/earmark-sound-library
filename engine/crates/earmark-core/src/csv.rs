//! Minimal RFC 4180 CSV parser: quoted fields, doubled quotes, commas and newlines inside quotes.
//! Port of `CSV.swift`.

pub fn parse(text: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut in_quotes = false;
    let mut chars = text.chars().peekable();

    while let Some(c) = chars.next() {
        if in_quotes {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    in_quotes = false;
                }
            } else if c == '\r' && chars.peek() == Some(&'\n') {
                // Swift reads "\r\n" as one character.
                chars.next();
                field.push_str("\r\n");
            } else {
                field.push(c);
            }
        } else {
            match c {
                '"' => in_quotes = true,
                ',' => row.push(std::mem::take(&mut field)),
                '\n' | '\r' => {
                    if c == '\r' && chars.peek() == Some(&'\n') {
                        chars.next();
                    }
                    row.push(std::mem::take(&mut field));
                    rows.push(std::mem::take(&mut row));
                }
                _ => field.push(c),
            }
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn quotes_and_line_ends() {
        assert_eq!(
            parse("a,b\r\nc,\"d,\"\"e\"\"\nf\"\rg"),
            vec![
                vec!["a".to_string(), "b".into()],
                vec!["c".into(), "d,\"e\"\nf".into()],
                vec!["g".into()],
            ]
        );
        assert_eq!(parse("x,\n"), vec![vec!["x".to_string(), "".into()]]);
        assert!(parse("").is_empty());
    }
}
