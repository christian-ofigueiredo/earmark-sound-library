//! Flattens XML (iXML, XMP) into `{"BWFXML/USER/DESCRIPTION": "text"}`. Repeated paths are
//! joined with " | "; attributes become `path@name`. Port of `XMLFlattener.swift`, which uses
//! Foundation's XMLParser with namespaces processed: names lose their prefixes, `xmlns`
//! attributes aren't reported, and parsing stops at the first error, keeping what it found.

use crate::text::trim;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use std::collections::HashMap;

fn local(name: &[u8]) -> String {
    let s = String::from_utf8_lossy(name);
    s.rsplit(':').next().unwrap_or("").to_string()
}

pub fn flatten(data: &[u8]) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut end = data.len();
    while end > 0 && matches!(data[end - 1], 0 | 0x20 | 0x0A | 0x0D) {
        end -= 1;
    }
    let mut bytes = &data[..end];
    if bytes.is_empty() {
        return out;
    }
    if let Some(lt) = bytes.iter().position(|&b| b == b'<') {
        bytes = &bytes[lt..];
    }

    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().check_end_names = true;
    let mut stack: Vec<String> = Vec::new();
    let mut text: Vec<String> = Vec::new();
    let mut has_children: Vec<bool> = Vec::new();
    let mut buf = Vec::new();

    let start = |e: &quick_xml::events::BytesStart,
                 stack: &mut Vec<String>,
                 text: &mut Vec<String>,
                 has_children: &mut Vec<bool>,
                 out: &mut HashMap<String, String>|
     -> bool {
        if let Some(last) = has_children.last_mut() {
            *last = true;
        }
        stack.push(local(e.name().as_ref()));
        text.push(String::new());
        has_children.push(false);
        let path = stack.join("/");
        for a in e.attributes() {
            let Ok(a) = a else { return false };
            let key = a.key.as_ref();
            if key == b"xmlns" || key.starts_with(b"xmlns:") {
                continue;
            }
            let Ok(v) = a.unescape_value() else {
                return false;
            };
            let value = trim(&v);
            if !value.is_empty() {
                out.insert(format!("{path}@{}", local(key)), value.to_string());
            }
        }
        true
    };
    let finish = |stack: &mut Vec<String>,
                  text: &mut Vec<String>,
                  has_children: &mut Vec<bool>,
                  out: &mut HashMap<String, String>| {
        let path = stack.join("/");
        let raw = text.pop().unwrap_or_default();
        let value = trim(&raw);
        let leaf = !has_children.pop().unwrap_or(false);
        if leaf && !value.is_empty() {
            match out.get_mut(&path) {
                Some(existing) => {
                    existing.push_str(" | ");
                    existing.push_str(value);
                }
                None => {
                    out.insert(path, value.to_string());
                }
            }
        }
        stack.pop();
    };

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                if !start(&e, &mut stack, &mut text, &mut has_children, &mut out) {
                    break;
                }
            }
            Ok(Event::Empty(e)) => {
                if !start(&e, &mut stack, &mut text, &mut has_children, &mut out) {
                    break;
                }
                finish(&mut stack, &mut text, &mut has_children, &mut out);
            }
            Ok(Event::End(_)) => finish(&mut stack, &mut text, &mut has_children, &mut out),
            Ok(Event::Text(t)) => {
                let Ok(s) = t.decode() else { break };
                let Ok(s) = quick_xml::escape::unescape(&s) else {
                    break;
                };
                if let Some(last) = text.last_mut() {
                    last.push_str(&s);
                }
            }
            Ok(Event::GeneralRef(r)) => {
                let Ok(name) = r.decode() else { break };
                let resolved = match &*name {
                    "amp" => Some("&".to_string()),
                    "lt" => Some("<".to_string()),
                    "gt" => Some(">".to_string()),
                    "quot" => Some("\"".to_string()),
                    "apos" => Some("'".to_string()),
                    _ => r.resolve_char_ref().ok().flatten().map(|c| c.to_string()),
                };
                let Some(s) = resolved else { break };
                if let Some(last) = text.last_mut() {
                    last.push_str(&s);
                }
            }
            Ok(Event::CData(c)) => {
                if let Some(last) = text.last_mut() {
                    last.push_str(&String::from_utf8_lossy(&c));
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            Ok(_) => {}
        }
        buf.clear();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::flatten;

    #[test]
    fn paths_attributes_and_repeats() {
        let x = br#"junk<?xml version="1.0"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:li xml:lang="en">A &amp; B</rdf:li><rdf:li>C</rdf:li><e a=" v "/></x:xmpmeta>"#;
        let f = flatten(x);
        assert_eq!(f["xmpmeta/li"], "A & B | C");
        assert_eq!(f["xmpmeta/li@lang"], "en");
        assert_eq!(f["xmpmeta/e@a"], "v");
        assert!(!f.contains_key("xmpmeta@x"));
        assert!(!f.keys().any(|k| k == "xmpmeta"));
    }

    #[test]
    fn stops_at_errors_keeping_what_it_found() {
        let f = flatten(b"<A><B>one</B><C>two</D></A>\0\0");
        assert_eq!(f.get("A/B").map(String::as_str), Some("one"));
        assert!(!f.contains_key("A/C"));
    }
}
