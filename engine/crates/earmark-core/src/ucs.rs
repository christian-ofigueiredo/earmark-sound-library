//! The Universal Category System (UCS v8.2.1, public domain). Port of `UCS.swift`.

use crate::csv;
use crate::text::{first_piece, trim_spaces};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::sync::OnceLock;

/// The list Earmark ships with, shared with the Swift app.
const BUNDLED: &str = include_str!("../../../../app/Sources/EarmarkCore/Resources/ucs_v8.2.1.csv");

/// One subcategory.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UcsEntry {
    pub category: String,
    pub subcategory: String,
    #[serde(rename = "catID")]
    pub cat_id: String,
    pub cat_short: String,
    pub explanation: String,
    pub synonyms: Vec<String>,
}

impl UcsEntry {
    pub fn label(&self) -> String {
        format!("{} / {}", self.category, self.subcategory)
    }
}

/// A UCS-style filename: `CatID_FXName_CreatorID_SourceID[_UserData]`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UcsFilename<'a> {
    pub entry: &'a UcsEntry,
    pub fx_name: Option<String>,
    pub creator_id: Option<String>,
    pub source_id: Option<String>,
    pub user_data: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum UcsError {
    BadHeader,
}

pub struct UcsCatalog {
    pub entries: Vec<UcsEntry>,
    by_lower_cat_id: HashMap<String, usize>,
    by_category: BTreeMap<String, Vec<usize>>,
}

impl UcsCatalog {
    /// The bundled list.
    pub fn shared() -> &'static UcsCatalog {
        static SHARED: OnceLock<UcsCatalog> = OnceLock::new();
        SHARED.get_or_init(|| UcsCatalog::from_csv(BUNDLED).expect("the bundled UCS list is valid"))
    }

    pub fn from_csv(text: &str) -> Result<UcsCatalog, UcsError> {
        let rows = csv::parse(text);
        let header = rows.first().ok_or(UcsError::BadHeader)?;
        if header.len() < 3
            || header[0] != "Category"
            || header[1] != "SubCategory"
            || header[2] != "CatID"
        {
            return Err(UcsError::BadHeader);
        }
        let mut entries = Vec::new();
        for r in rows.iter().skip(1) {
            if r.len() < 6 || r[2].is_empty() {
                continue;
            }
            entries.push(UcsEntry {
                category: r[0].clone(),
                subcategory: r[1].clone(),
                cat_id: r[2].clone(),
                cat_short: r[3].clone(),
                explanation: r[4].clone(),
                synonyms: r[5]
                    .split(',')
                    .map(trim_spaces)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect(),
            });
        }
        let mut by_lower_cat_id = HashMap::new();
        let mut by_category: BTreeMap<String, Vec<usize>> = BTreeMap::new();
        for (i, e) in entries.iter().enumerate() {
            by_lower_cat_id.entry(e.cat_id.to_lowercase()).or_insert(i);
            by_category.entry(e.category.clone()).or_default().push(i);
        }
        Ok(UcsCatalog {
            entries,
            by_lower_cat_id,
            by_category,
        })
    }

    /// The categories, sorted.
    pub fn categories(&self) -> Vec<&str> {
        self.by_category.keys().map(String::as_str).collect()
    }

    pub fn subcategories(&self, category: &str) -> Vec<&UcsEntry> {
        self.by_category
            .get(category)
            .map(|v| v.iter().map(|&i| &self.entries[i]).collect())
            .unwrap_or_default()
    }

    pub fn entry_by_cat_id(&self, cat_id: Option<&str>) -> Option<&UcsEntry> {
        let id = trim_spaces(cat_id?);
        if id.is_empty() {
            return None;
        }
        self.by_lower_cat_id
            .get(&id.to_lowercase())
            .map(|&i| &self.entries[i])
    }

    /// Matches free-text Category/SubCategory fields, including the "CATEGORY-SUBCATEGORY"
    /// form CategoryFull uses.
    pub fn entry_by_category(
        &self,
        category: Option<&str>,
        subcategory: Option<&str>,
    ) -> Option<&UcsEntry> {
        let mut cat = trim_spaces(category?).to_uppercase();
        if cat.is_empty() {
            return None;
        }
        let mut sub = trim_spaces(subcategory.unwrap_or("")).to_uppercase();
        if sub.is_empty()
            && let Some(dash) = cat.find('-')
        {
            sub = trim_spaces(&cat[dash + 1..]).to_string();
            cat = trim_spaces(&cat[..dash]).to_string();
        }
        self.by_category
            .get(&cat)?
            .iter()
            .map(|&i| &self.entries[i])
            .find(|e| e.subcategory.to_uppercase() == sub)
    }

    /// Parses a UCS filename. The CatID must be exact-case ("AMBForst") or all capitals
    /// ("AMBFORST"), so ordinary words ("rain_01") don't count.
    pub fn parse_filename(&self, stem: &str) -> Option<UcsFilename<'_>> {
        let parts: Vec<&str> = stem.split('_').collect();
        if parts.len() < 2 {
            return None;
        }
        let cat_id = first_piece(parts[0], '-');
        let entry = self.entry_by_cat_id(Some(cat_id))?;
        if !(cat_id == entry.cat_id
            || (cat_id == cat_id.to_uppercase() && cat_id != cat_id.to_lowercase()))
        {
            return None;
        }
        let part = |i: usize| {
            parts
                .get(i)
                .map(|p| trim_spaces(p))
                .filter(|v| !v.is_empty())
                .map(str::to_string)
        };
        Some(UcsFilename {
            entry,
            fx_name: part(1),
            creator_id: part(2),
            source_id: part(3),
            user_data: if parts.len() > 4 {
                Some(parts[4..].join("_"))
            } else {
                None
            },
        })
    }

    /// Folder names only count when unmistakably UCS: an exact-case CatID ("WHSH",
    /// "AMBForst_Woods") or "CATEGORY-SUBCATEGORY" in capitals.
    pub fn entry_by_folder_name(&self, name: &str) -> Option<&UcsEntry> {
        let name = trim_spaces(name);
        let head = first_piece(name, '_');
        if let Some(e) = self.entry_by_cat_id(Some(head))
            && e.cat_id == head
        {
            return Some(e);
        }
        if name == name.to_uppercase() && name.contains('-') {
            return self.entry_by_category(Some(name), None);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::UcsCatalog;

    #[test]
    fn bundled_list_is_complete() {
        let ucs = UcsCatalog::shared();
        assert_eq!(ucs.entries.len(), 753);
        assert_eq!(ucs.categories().len(), 82);
        assert_eq!(
            ucs.entry_by_cat_id(Some("whsh")).unwrap().label(),
            "SWOOSHES / WHOOSH"
        );
    }

    #[test]
    fn filename_rules() {
        let ucs = UcsCatalog::shared();
        let id = |s: &str| ucs.parse_filename(s).map(|f| f.entry.cat_id.clone());
        assert_eq!(id("WHSH_Heavy Whoosh 01_SLAB_Lib").as_deref(), Some("WHSH"));
        assert_eq!(id("AMBFORST_Birds_SLAB_Lib").as_deref(), Some("AMBForst"));
        assert_eq!(id("rain_01"), None);
        assert_eq!(id("Test_take"), None);
        let f = ucs
            .parse_filename("DSGNImpt_Low Thud 03_SLAB_PackB_extra_more")
            .unwrap();
        assert_eq!(f.fx_name.as_deref(), Some("Low Thud 03"));
        assert_eq!(f.source_id.as_deref(), Some("PackB"));
        assert_eq!(f.user_data.as_deref(), Some("extra_more"));
    }

    #[test]
    fn folder_and_category_text() {
        let ucs = UcsCatalog::shared();
        let id = |s: &str| ucs.entry_by_folder_name(s).map(|e| e.cat_id.as_str());
        assert_eq!(id("WHSH"), Some("WHSH"));
        assert_eq!(id("AMBForst_Woods"), Some("AMBForst"));
        assert_eq!(id("SWOOSHES-WHOOSH"), Some("WHSH"));
        assert_eq!(id("test"), None);
        assert_eq!(id("Fire"), None);
        assert_eq!(
            ucs.entry_by_category(Some("designed"), Some("impact"))
                .map(|e| e.cat_id.as_str()),
            Some("DSGNImpt")
        );
    }
}
