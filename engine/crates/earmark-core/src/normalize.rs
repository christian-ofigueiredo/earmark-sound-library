//! One normalised record per file: the useful fields, where each came from, and the UCS
//! category if the vendor gave one. Port of `MetadataNormalizer.swift`.

use crate::metadata::RawMetadata;
use crate::text::{trim, trim_spaces};
use crate::ucs::{UcsCatalog, UcsEntry};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MetadataField {
    Description,
    FxName,
    Category,
    Subcategory,
    #[serde(rename = "catID")]
    CatId,
    Keywords,
    Library,
    Manufacturer,
    Designer,
    Notes,
    Bpm,
    Key,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UcsAssignment {
    #[serde(rename = "catID")]
    pub cat_id: String,
    pub category: String,
    pub subcategory: String,
    /// Where it came from, e.g. "iXML USER/CATID", "UCS filename".
    pub source: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedMetadata {
    pub fields: BTreeMap<MetadataField, String>,
    pub sources: BTreeMap<MetadataField, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ucs: Option<UcsAssignment>,
}

impl NormalizedMetadata {
    pub fn get(&self, f: MetadataField) -> Option<&str> {
        self.fields.get(&f).map(String::as_str)
    }
}

/// iXML leaf names (case-insensitive), most specific first. Soundminer writes these under
/// USER; game audio uses ASWG. `None`: CategoryFull, used for the category if nothing else.
const IXML_NAMES: &[(Option<MetadataField>, &[&str])] = {
    use MetadataField::*;
    &[
        (
            Some(Description),
            &["DESCRIPTION", "BWF_DESCRIPTION", "NOTE"],
        ),
        (Some(FxName), &["FXNAME", "TRACKTITLE", "TITLE"]),
        (Some(Category), &["CATEGORY"]),
        (Some(Subcategory), &["SUBCATEGORY"]),
        (Some(CatId), &["CATID"]),
        (None, &["CATEGORYFULL"]),
        (Some(Keywords), &["KEYWORDS"]),
        (Some(Library), &["LIBRARY", "SHOW", "PROJECT"]),
        (
            Some(Manufacturer),
            &["MANUFACTURER", "VENDOR", "BWF_ORIGINATOR", "ORIGINATOR"],
        ),
        (Some(Designer), &["DESIGNER", "CREATORID", "RECORDIST"]),
        (Some(Notes), &["NOTES"]),
        (Some(Bpm), &["BPM", "TEMPO"]),
        (Some(Key), &["KEY", "MUSICALKEY", "INITIALKEY"]),
    ]
};
const SECTION_ORDER: &[&str] = &["USER", "ASWG", "STEINBERG", "BEXT", ""];

/// Web addresses, download-site watermarks and binary junk some packs put in the description.
pub fn is_junk(s: &str) -> bool {
    static JUNK: OnceLock<Regex> = OnceLock::new();
    JUNK.get_or_init(|| {
        Regex::new(r"(?i)(www\.|https?:|\.com\b|\.ru\b|\.net\b|GET MORE ASSETS|^[0-9A-Fa-f]{24,}$)")
            .unwrap()
    })
    .is_match(s)
}

fn ixml_find(ixml: &HashMap<String, String>, names: &[&str]) -> Option<(String, String)> {
    for name in names {
        let mut hits: Vec<(&String, &String)> = ixml
            .iter()
            .filter(|(k, v)| {
                !k.contains('@')
                    && k.split('/')
                        .rfind(|p| !p.is_empty())
                        .is_some_and(|last| last.to_uppercase() == *name)
                    && !trim_spaces(v).is_empty()
            })
            .collect();
        if hits.is_empty() {
            continue;
        }
        hits.sort_by(|a, b| a.0.cmp(b.0));
        for section in SECTION_ORDER {
            let found = hits.iter().find(|(k, _)| {
                if section.is_empty() {
                    return true;
                }
                let parts: Vec<&str> = k.split('/').filter(|p| !p.is_empty()).collect();
                parts[..parts.len().saturating_sub(1)]
                    .iter()
                    .any(|p| p.to_uppercase() == *section)
            });
            if let Some((k, v)) = found {
                return Some(((*v).clone(), (*k).clone()));
            }
        }
    }
    None
}

pub fn normalize(raw: &RawMetadata, path: &Path, catalog: &UcsCatalog) -> NormalizedMetadata {
    use MetadataField::*;
    let mut out = NormalizedMetadata::default();
    let mut category_full: Option<String> = None;

    fn put(out: &mut NormalizedMetadata, field: MetadataField, value: Option<&str>, source: &str) {
        let Some(v) = value.map(trim) else { return };
        if v.is_empty() || out.fields.contains_key(&field) {
            return;
        }
        if field == MetadataField::Description && is_junk(v) {
            return;
        }
        out.fields.insert(field, v.to_string());
        out.sources.insert(field, source.to_string());
    }

    for (field, names) in IXML_NAMES {
        let Some((value, path)) = ixml_find(&raw.ixml, names) else {
            continue;
        };
        match field {
            Some(f) => put(&mut out, *f, Some(&value), &format!("iXML {path}")),
            None => {
                if category_full.is_none() {
                    category_full = Some(value);
                }
            }
        }
    }
    put(
        &mut out,
        Description,
        raw.bext.get("Description").map(String::as_str),
        "bext Description",
    );
    put(
        &mut out,
        Manufacturer,
        raw.bext.get("Originator").map(String::as_str),
        "bext Originator",
    );

    let mut xmp: Vec<(&String, &String)> = raw.xmp.iter().collect();
    xmp.sort_by(|a, b| a.0.cmp(b.0));
    for (k, v) in xmp {
        if k.ends_with("description/Alt/li") {
            put(&mut out, Description, Some(v), &format!("XMP {k}"));
        } else if k.ends_with("title/Alt/li") {
            put(&mut out, FxName, Some(v), &format!("XMP {k}"));
        } else if k.ends_with("subject/Bag/li") {
            put(
                &mut out,
                Keywords,
                Some(&v.replace(" | ", ", ")),
                &format!("XMP {k}"),
            );
        }
    }

    let info = |k: &str| raw.info.get(k).map(String::as_str);
    put(&mut out, FxName, info("Title"), "INFO INAM");
    put(
        &mut out,
        Description,
        info("Comment").or(info("Subject")),
        "INFO ICMT/ISBJ",
    );
    put(&mut out, Keywords, info("Keywords"), "INFO IKEY");
    put(&mut out, Library, info("Product"), "INFO IPRD");
    put(
        &mut out,
        Designer,
        info("Artist").or(info("Engineer")),
        "INFO IART/IENG",
    );
    put(&mut out, Category, info("Genre"), "INFO IGNR");
    if let Some(acid) = &raw.acid
        && !acid.one_shot
        && acid.tempo > 0.0
    {
        put(
            &mut out,
            Bpm,
            Some(&format!("{:.2}", acid.tempo)),
            "acid chunk",
        );
    }
    put(
        &mut out,
        FxName,
        raw.aiff.get("Title").map(String::as_str),
        "AIFF NAME",
    );
    put(
        &mut out,
        Description,
        raw.aiff.get("Annotation").map(String::as_str),
        "AIFF ANNO",
    );
    put(
        &mut out,
        Designer,
        raw.aiff.get("Author").map(String::as_str),
        "AIFF AUTH",
    );

    // UCS: an explicit CatID, then Category/SubCategory text, then the filename, then folders.
    let mut entry: Option<&UcsEntry> = catalog.entry_by_cat_id(out.get(CatId));
    let mut source: Option<String> = entry.and_then(|_| out.sources.get(&CatId).cloned());
    if entry.is_none() {
        entry = catalog.entry_by_category(
            out.get(Category).or(category_full.as_deref()),
            out.get(Subcategory),
        );
        source = entry.and_then(|_| out.sources.get(&Category).cloned());
    }
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    if let Some(parsed) = catalog.parse_filename(&stem) {
        put(&mut out, FxName, parsed.fx_name.as_deref(), "UCS filename");
        put(
            &mut out,
            Designer,
            parsed.creator_id.as_deref(),
            "UCS filename",
        );
        put(
            &mut out,
            Library,
            parsed.source_id.as_deref(),
            "UCS filename",
        );
        if entry.is_none() {
            entry = Some(parsed.entry);
            source = Some("UCS filename".into());
        }
    }
    if entry.is_none() {
        let mut dir = path.parent();
        for _ in 0..3 {
            let Some(d) = dir else { break };
            let name = d
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            if let Some(e) = catalog.entry_by_folder_name(&name) {
                entry = Some(e);
                source = Some(format!("folder name '{name}'"));
                break;
            }
            dir = d.parent();
        }
    }
    if let Some(e) = entry {
        let src = source.unwrap_or_else(|| "metadata".into());
        out.ucs = Some(UcsAssignment {
            cat_id: e.cat_id.clone(),
            category: e.category.clone(),
            subcategory: e.subcategory.clone(),
            source: src.clone(),
        });
        for (field, value) in [
            (CatId, &e.cat_id),
            (Category, &e.category),
            (Subcategory, &e.subcategory),
        ] {
            out.fields.insert(field, value.clone());
            out.sources.entry(field).or_insert_with(|| src.clone());
        }
    }
    out
}
