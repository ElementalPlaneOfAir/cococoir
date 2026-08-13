// SPDX-License-Identifier: AGPL-3.0-or-later
//! Lossless round-trip parser for the dashboard's Nix config file.
//!
//! The dashboard must read a NixOS-style config file (function header,
//! `let ... in`, nested attrsets — like `nixosConfigurations/vmtest.nix`),
//! let the user change the fields it knows about, and write the file back
//! without destroying anything it does not model.
//!
//! Round-trip law: `parse(source)` then `to_source()` with no edits returns
//! the exact input. An edit replaces only the byte span of one value node;
//! comments, formatting, and every other binding survive byte-for-byte.
//!
//! The parser is shape-agnostic: it finds values by attribute path
//! (`cococoir.services.jellyfin.enable`) inside the lossless CST from
//! `rnix`. The [`ConfigSchema`] decides which paths are "known" — when the
//! config language changes, only the schema's path list changes.

use std::collections::{BTreeMap, BTreeSet};

use rnix::ast::{self, HasEntry, InterpolPart};
use rnix::{SyntaxNode, TextRange};
use rowan::ast::AstNode;

/// Parse failures. Reported to the dashboard as "this file is not Nix".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NixParseError {
    message: String,
}

impl std::fmt::Display for NixParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "nix parse error: {}", self.message)
    }
}

impl std::error::Error for NixParseError {}

/// Failures from an edit. The file is never modified on error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetError {
    /// The attrpath exists but does not end at a value node.
    NotFound(String),
    /// The replacement text, once spliced in, would not parse as Nix.
    InvalidValue(String),
}

impl std::fmt::Display for SetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SetError::NotFound(path) => write!(f, "attrpath not found: {path}"),
            SetError::InvalidValue(value) => write!(f, "replacement would not parse: {value}"),
        }
    }
}

impl std::error::Error for SetError {}

/// The value of a node, interpreted as far as the dashboard needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NixValue {
    Bool(bool),
    Str(String),
    StrList(Vec<String>),
    /// Anything else (ints, paths, idents, interpolated strings, ...),
    /// kept as its raw source text.
    Other(String),
}

/// A value found at an attrpath: its interpretation plus its byte span.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocatedValue<'a> {
    pub value: NixValue,
    pub span: TextRange,
    pub raw: &'a str,
}

/// A parsed config file. Owns only the source; the CST is rebuilt on each
/// navigation so the type stays `Send`/`Sync` for the async dashboard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NixConfigFile {
    source: String,
}

impl NixConfigFile {
    pub fn parse(source: impl Into<String>) -> Result<Self, NixParseError> {
        let source = source.into();
        validate(&source)?;
        Ok(Self { source })
    }

    /// The current file contents. With no edits, byte-identical to the input.
    pub fn to_source(&self) -> &str {
        &self.source
    }

    /// Look up a value by attribute path. Returns `None` if the path is
    /// missing, lands mid-expression (e.g. `a` in `a.b = 1`), or crosses
    /// an `inherit`.
    pub fn find_attrpath(&self, path: &[&str]) -> Option<LocatedValue<'_>> {
        if path.is_empty() {
            return None;
        }
        let root = parse_root(&self.source)?;
        let node = find_value_node(&root, path)?;
        let span = node.text_range();
        let raw = slice_at(&self.source, span);
        Some(LocatedValue {
            value: interpret(&node, raw),
            span,
            raw,
        })
    }

    /// The names bound directly under the attrset at `path`
    /// (e.g. usernames under `users.users`). Used by the schema layer to
    /// enumerate users without hardcoding them.
    pub fn attrset_keys(&self, path: &[&str]) -> Option<Vec<String>> {
        let root = parse_root(&self.source)?;
        let node = find_value_node(&root, path)?;
        let attrset = ast::AttrSet::cast(node)?;
        let mut keys = Vec::new();
        for entry in attrset.entries() {
            if let ast::Entry::AttrpathValue(kv) = entry {
                if let Some(attrpath) = kv.attrpath() {
                    if let Some(first) = attrpath.attrs().next() {
                        if let Some(name) = attr_name(&first) {
                            keys.push(name);
                        }
                    }
                }
            }
        }
        keys.sort();
        Some(keys)
    }

    /// Replace the value at `path` with `replacement` (raw Nix text).
    /// Only that value's byte span changes. Missing paths are an error,
    /// not an insertion — this arc does not create bindings.
    pub fn set_attrpath(&mut self, path: &[&str], replacement: &str) -> Result<(), SetError> {
        let root = parse_root(&self.source).ok_or_else(|| {
            SetError::InvalidValue("source file does not parse".to_string())
        })?;
        let node = find_value_node(&root, path)
            .ok_or_else(|| SetError::NotFound(path.join(".")))?;
        let span = node.text_range();
        let (start, end): (usize, usize) = (span.start().into(), span.end().into());

        let mut candidate = String::with_capacity(self.source.len() + replacement.len());
        candidate.push_str(&self.source[..start]);
        candidate.push_str(replacement);
        candidate.push_str(&self.source[end..]);

        validate(&candidate).map_err(|_| {
            SetError::InvalidValue(format!("{} at path {}", replacement, path.join(".")))
        })?;
        self.source = candidate;
        Ok(())
    }
}

/// Fails on any rnix parse error so a malformed file is never edited.
fn validate(source: &str) -> Result<(), NixParseError> {
    let parsed = rnix::Root::parse(source);
    if let Some(error) = parsed.errors().first() {
        return Err(NixParseError {
            message: error.to_string(),
        });
    }
    Ok(())
}

fn parse_root(source: &str) -> Option<rnix::Root> {
    let parsed = rnix::Root::parse(source);
    if parsed.errors().is_empty() {
        Some(parsed.tree())
    } else {
        None
    }
}

/// Unwrap the file's expression down to its top-level attrset: through a
/// function header (`{ config, ... }: body`), a `let ... in` body, and
/// parentheses.
fn root_expr_to_attrset(expr: ast::Expr) -> Option<ast::AttrSet> {
    match expr {
        ast::Expr::AttrSet(set) => Some(set),
        ast::Expr::Lambda(lambda) => lambda.body().and_then(root_expr_to_attrset),
        ast::Expr::LetIn(let_in) => let_in.body().and_then(root_expr_to_attrset),
        ast::Expr::Paren(paren) => paren.expr().and_then(root_expr_to_attrset),
        _ => None,
    }
}

/// Find the value node for `path`, handling both dotted keys
/// (`a.b.c = v`) and nested attrsets (`a = { b = { c = v; }; }`).
fn find_value_node(root: &rnix::Root, path: &[&str]) -> Option<SyntaxNode> {
    let attrset = root.expr().and_then(root_expr_to_attrset)?;
    find_in_attrset(&attrset, path)
}

fn find_in_attrset(attrset: &ast::AttrSet, path: &[&str]) -> Option<SyntaxNode> {
    for entry in attrset.entries() {
        let ast::Entry::AttrpathValue(kv) = entry else {
            continue;
        };
        let attrpath = kv.attrpath()?;
        let names: Vec<String> = attrpath.attrs().filter_map(|a| attr_name(&a)).collect();
        if names.is_empty() || names.len() > path.len() {
            continue;
        }
        if !names.iter().zip(path.iter()).all(|(name, segment)| name == segment) {
            continue;
        }
        let value = kv.value()?;
        if names.len() == path.len() {
            return Some(value.syntax().clone());
        }
        if let ast::Expr::AttrSet(inner) = value {
            if let Some(found) = find_in_attrset(&inner, &path[names.len()..]) {
                return Some(found);
            }
        }
    }
    None
}

fn attr_name(attr: &ast::Attr) -> Option<String> {
    match attr {
        ast::Attr::Ident(ident) => Some(ident.syntax().text().to_string()),
        ast::Attr::Str(str) => literal_string(str).map(|s| s.to_string()),
        ast::Attr::Dynamic(_) => None,
    }
}

/// The literal value of a `Str` node, or `None` if it contains an
/// interpolation (dynamic at runtime, so not a stable config value).
fn literal_string(str: &ast::Str) -> Option<String> {
    let parts = str.normalized_parts();
    if parts.iter().any(|p| matches!(p, InterpolPart::Interpolation(_))) {
        return None;
    }
    Some(
        parts
            .into_iter()
            .filter_map(|p| match p {
                InterpolPart::Literal(s) => Some(s),
                InterpolPart::Interpolation(_) => None,
            })
            .collect(),
    )
}

/// Interpret a node as far as the dashboard needs; anything else keeps its
/// raw source text.
fn interpret(node: &SyntaxNode, raw: &str) -> NixValue {
    if let Some(ident) = ast::Ident::cast(node.clone()) {
        return match ident.syntax().text().to_string().as_str() {
            "true" => NixValue::Bool(true),
            "false" => NixValue::Bool(false),
            _ => NixValue::Other(raw.to_string()),
        };
    }
    if let Some(str) = ast::Str::cast(node.clone()) {
        return literal_string(&str).map_or(NixValue::Other(raw.to_string()), NixValue::Str);
    }
    if let Some(list) = ast::List::cast(node.clone()) {
        let items: Option<Vec<String>> = list
            .items()
            .map(|item| {
                let ast::Expr::Str(str) = item else {
                    return None;
                };
                literal_string(&str)
            })
            .collect();
        return items.map_or(NixValue::Other(raw.to_string()), NixValue::StrList);
    }
    NixValue::Other(raw.to_string())
}

fn slice_at(source: &str, span: TextRange) -> &str {
    let (start, end): (usize, usize) = (span.start().into(), span.end().into());
    &source[start..end]
}

/// Which attrpaths the dashboard treats as known. A plain struct so the
/// mapping can change with the config language without touching the parser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigSchema {
    pub hostname: Vec<&'static str>,
    pub root_domain: Vec<&'static str>,
    pub services_root: Vec<&'static str>,
    pub users_root: Vec<&'static str>,
}

impl Default for ConfigSchema {
    /// Matches the current NixOS module shape (see `vmtest.nix`).
    fn default() -> Self {
        Self {
            hostname: vec!["networking", "hostName"],
            root_domain: vec!["cococoir", "baseDomain"],
            services_root: vec!["cococoir", "services"],
            users_root: vec!["users", "users"],
        }
    }
}

/// A service the dashboard can render, paired with its on-disk name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceInfo {
    pub nixname: &'static str,
    pub display_name: &'static str,
    pub description: &'static str,
}

pub const SERVICE_LIST: &[ServiceInfo] = &[
    ServiceInfo {
        nixname: "jellyfin",
        display_name: "Jellyfin",
        description: "Netflix, but for your own movies",
    },
    ServiceInfo {
        nixname: "cryptpad",
        display_name: "Cryptpad",
        description: "Google docs, but fully self-encrypted",
    },
    ServiceInfo {
        nixname: "radarr",
        display_name: "Radarr",
        description: "Movie download automation",
    },
    ServiceInfo {
        nixname: "sonarr",
        display_name: "Sonarr",
        description: "TV show download automation",
    },
    ServiceInfo {
        nixname: "lidarr",
        display_name: "Lidarr",
        description: "Music download automation",
    },
    ServiceInfo {
        nixname: "prowlarr",
        display_name: "Prowlarr",
        description: "Indexer manager for the *arrs",
    },
];

/// One user as declared in the config file.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct CocoUser {
    pub username: String,
    pub hashed_password: Option<String>,
    pub groups: BTreeSet<String>,
}

impl CocoUser {
    pub fn is_admin(&self) -> bool {
        self.groups.contains("wheel")
    }
}

/// A read-only snapshot of the fields the dashboard knows about. Everything
/// not covered by a known span is "extra config" and survives any edit
/// because [`NixConfigFile`] splices, never regenerates.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CococoirConfig {
    pub hostname: Option<String>,
    pub root_domain: Option<String>,
    pub services_enabled: BTreeMap<&'static str, bool>,
    pub users: BTreeMap<String, CocoUser>,
}

impl CococoirConfig {
    /// Extract the known fields from a file using `schema`'s paths.
    pub fn extract(file: &NixConfigFile, schema: &ConfigSchema) -> Self {
        let hostname = file
            .find_attrpath(&schema.hostname)
            .and_then(|located| match located.value {
                NixValue::Str(s) => Some(s),
                _ => None,
            });
        let root_domain = file
            .find_attrpath(&schema.root_domain)
            .and_then(|located| match located.value {
                NixValue::Str(s) => Some(s),
                _ => None,
            });

        let mut services_enabled = BTreeMap::new();
        for service in SERVICE_LIST {
            let mut path = schema.services_root.clone();
            path.push(service.nixname);
            path.push("enable");
            if let Some(located) = file.find_attrpath(&path) {
                if let NixValue::Bool(enabled) = located.value {
                    services_enabled.insert(service.nixname, enabled);
                }
            }
        }

        let mut users = BTreeMap::new();
        if let Some(names) = file.attrset_keys(&schema.users_root) {
            for name in names {
                let mut hashed_password = None;
                let mut hash_path = schema.users_root.clone();
                hash_path.push(&name);
                hash_path.push("hashedPassword");
                if let Some(located) = file.find_attrpath(&hash_path) {
                    if let NixValue::Str(s) = located.value {
                        hashed_password = Some(s);
                    }
                }

                let mut groups = BTreeSet::new();
                let mut groups_path = schema.users_root.clone();
                groups_path.push(&name);
                groups_path.push("groups");
                if let Some(located) = file.find_attrpath(&groups_path) {
                    if let NixValue::StrList(list) = located.value {
                        groups = list.into_iter().collect();
                    }
                }

                users.insert(
                    name.clone(),
                    CocoUser {
                        username: name,
                        hashed_password,
                        groups,
                    },
                );
            }
        }

        Self {
            hostname,
            root_domain,
            services_enabled,
            users,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A config in the shape the parser must survive: function header,
    /// `let ... in`, nested attrsets, dotted keys, comments, extra bindings.
    const VMTEST_STYLE: &str = r#"{ config, lib, pkgs, inputs, ... }:
let
  domain = "vmtest.local";
in {
  imports = [ (import ../nix/nixos-modules) ];

  # The platform domain. Services derive subdomains from it.
  cococoir = {
    baseDomain = "vmtest.local";
    services.jellyfin = {
      enable = true;
      public = true;
    };
    services.cryptpad = {
      enable = true;
      public = true;
    };
    services.radarr.enable = false;
  };

  networking.hostName = "vmtest";
  services.caddy.enable = true;

  users.users = {
    nicole = {
      hashedPassword = "$2b$10$abcdefghijklmnopqrstuv";
      groups = [ "wheel" "storage" ];
    };
  };
}
"#;

    #[test]
    fn round_trip_identity() {
        let file = NixConfigFile::parse(VMTEST_STYLE.to_string()).expect("valid fixture");
        assert_eq!(file.to_source(), VMTEST_STYLE);
    }

    #[test]
    fn rejects_malformed_input_without_panicking() {
        for garbage in ["", "{", "}{", "cococoir = ", "not nix at all !!!", "}"] {
            assert!(NixConfigFile::parse(garbage).is_err(), "should reject {garbage:?}");
        }
    }

    #[test]
    fn find_nested_and_dotted_paths() {
        let file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();

        let hostname = file
            .find_attrpath(&["networking", "hostName"])
            .expect("hostname present");
        assert_eq!(hostname.value, NixValue::Str("vmtest".to_string()));
        assert_eq!(hostname.raw, "\"vmtest\"");

        let domain = file
            .find_attrpath(&["cococoir", "baseDomain"])
            .expect("domain present");
        assert_eq!(domain.value, NixValue::Str("vmtest.local".to_string()));

        let jellyfin = file
            .find_attrpath(&["cococoir", "services", "jellyfin", "enable"])
            .expect("jellyfin enable present");
        assert_eq!(jellyfin.value, NixValue::Bool(true));

        let radarr = file
            .find_attrpath(&["cococoir", "services", "radarr", "enable"])
            .expect("radarr enable present");
        assert_eq!(radarr.value, NixValue::Bool(false));

        let groups = file
            .find_attrpath(&["users", "users", "nicole", "groups"])
            .expect("groups present");
        assert_eq!(
            groups.value,
            NixValue::StrList(vec!["wheel".to_string(), "storage".to_string()])
        );
    }

    #[test]
    fn find_missing_path_is_none() {
        let file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        assert!(file.find_attrpath(&["cococoir", "nope"]).is_none());
        assert!(file.find_attrpath(&["nope"]).is_none());
        assert!(file.find_attrpath(&["cococoir", "services", "sonarr", "enable"]).is_none());
        assert!(file.find_attrpath(&[]).is_none());
    }

    #[test]
    fn path_landing_mid_expression_is_none() {
        let file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        assert!(
            file.find_attrpath(&["cococoir", "services", "jellyfin"])
                .is_some(),
            "an attrset at a path is still a value"
        );
        assert!(
            file.find_attrpath(&["cococoir", "services", "jellyfin", "enable", "deeper"])
                .is_none(),
            "descending past a scalar value is not found"
        );
    }

    #[test]
    fn inherit_is_skipped_without_panicking() {
        let file = NixConfigFile::parse("{ config, ... }: { inherit config; }").unwrap();
        assert!(file.find_attrpath(&["config"]).is_none());
    }

    #[test]
    fn plain_attrset_file_parses_without_header() {
        let file = NixConfigFile::parse("{ hostname = \"plain\"; }").unwrap();
        let located = file.find_attrpath(&["hostname"]).expect("hostname present");
        assert_eq!(located.value, NixValue::Str("plain".to_string()));
    }

    #[test]
    fn set_replaces_only_the_target_span() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        file.set_attrpath(&["cococoir", "services", "jellyfin", "enable"], "false")
            .expect("edit succeeds");

        let updated = file.to_source();
        let jellyfin_block_after = "services.jellyfin = {\n      enable = false;\n      public = true;\n    };";
        let jellyfin_block_before = "services.jellyfin = {\n      enable = true;\n      public = true;\n    };";
        assert!(
            updated.contains(jellyfin_block_after),
            "only the value changed, surrounding text survives"
        );
        assert!(
            !updated.contains(jellyfin_block_before),
            "old value must be gone"
        );

        let reparse = NixConfigFile::parse(updated.to_string()).expect("edit stays valid nix");
        let jellyfin = reparse
            .find_attrpath(&["cococoir", "services", "jellyfin", "enable"])
            .expect("still findable");
        assert_eq!(jellyfin.value, NixValue::Bool(false));
    }

    #[test]
    fn set_replaces_string_values() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        file.set_attrpath(&["networking", "hostName"], "\"other\"")
            .expect("edit succeeds");
        let reparse = NixConfigFile::parse(file.to_source().to_string()).unwrap();
        let hostname = reparse
            .find_attrpath(&["networking", "hostName"])
            .expect("hostname present");
        assert_eq!(hostname.value, NixValue::Str("other".to_string()));
    }

    #[test]
    fn set_missing_path_is_not_found_error() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        let result = file.set_attrpath(&["cococoir", "nonexistent"], "true");
        assert!(matches!(result, Err(SetError::NotFound(path)) if path == "cococoir.nonexistent"));
        assert_eq!(file.to_source(), VMTEST_STYLE, "failed edit must not touch the file");
    }

    #[test]
    fn set_invalid_value_is_rejected() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        let result = file.set_attrpath(&["networking", "hostName"], "}");
        assert!(matches!(result, Err(SetError::InvalidValue(_))));
        assert_eq!(file.to_source(), VMTEST_STYLE, "invalid edit must not touch the file");
    }

    #[test]
    fn set_then_set_back_round_trips() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        file.set_attrpath(&["cococoir", "services", "jellyfin", "enable"], "false").unwrap();
        file.set_attrpath(&["cococoir", "services", "jellyfin", "enable"], "true").unwrap();
        assert_eq!(file.to_source(), VMTEST_STYLE);
    }

    #[test]
    fn extract_known_fields() {
        let file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        let config = CococoirConfig::extract(&file, &ConfigSchema::default());

        assert_eq!(config.hostname.as_deref(), Some("vmtest"));
        assert_eq!(config.root_domain.as_deref(), Some("vmtest.local"));
        assert_eq!(config.services_enabled.get("jellyfin"), Some(&true));
        assert_eq!(config.services_enabled.get("cryptpad"), Some(&true));
        assert_eq!(config.services_enabled.get("radarr"), Some(&false));
        assert_eq!(config.services_enabled.get("sonarr"), None, "not declared in file");

        let nicole = config.users.get("nicole").expect("nicole present");
        assert_eq!(nicole.hashed_password.as_deref(), Some("$2b$10$abcdefghijklmnopqrstuv"));
        assert!(nicole.is_admin());
        assert!(config.users.get("carl").is_none());
    }

    #[test]
    fn extract_missing_fields_are_none() {
        let file = NixConfigFile::parse("{}").unwrap();
        let config = CococoirConfig::extract(&file, &ConfigSchema::default());
        assert_eq!(config.hostname, None);
        assert_eq!(config.root_domain, None);
        assert!(config.services_enabled.is_empty());
        assert!(config.users.is_empty());
    }

    #[test]
    fn user_admin_flag_matches_wheel_group() {
        let mut user = CocoUser {
            username: "bob".to_string(),
            hashed_password: None,
            groups: BTreeSet::new(),
        };
        assert!(!user.is_admin());
        user.groups.insert("wheel".to_string());
        assert!(user.is_admin());
    }
}
