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
//! (`fortress.services.jellyfin.enable`) inside the lossless CST from
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

impl NixValue {
    /// Render this value as Nix source text, ready to be spliced by
    /// [`NixConfigFile::set_attrpath`]. `Other` values carry their raw
    /// source, so re-emitting them is lossless by construction.
    pub fn to_source(&self) -> String {
        match self {
            NixValue::Bool(true) => "true".to_string(),
            NixValue::Bool(false) => "false".to_string(),
            NixValue::Str(s) => quote_nix_string(s),
            NixValue::StrList(items) => {
                let rendered: Vec<String> = items.iter().map(|s| quote_nix_string(s)).collect();
                format!("[ {} ]", rendered.join(" "))
            }
            NixValue::Other(raw) => raw.clone(),
        }
    }
}

/// Quote a string as a Nix double-quoted string literal. Escapes the
/// characters Nix supports (`\"`, `\\`, `\n`, `\t`, `\r`); everything
/// else is emitted verbatim. Used for hostname/domain/group values,
/// which never contain control characters.
fn quote_nix_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
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
    /// enumerate users without hardcoding them. Handles both nested
    /// (`users.users = { nicole = {...}; }`) and dotted
    /// (`users.users.nicole = {...}`) key forms: a dotted key whose
    /// prefix matches `path` contributes the segment at `path.len()`.
    /// Returns `None` when nothing at `path` exists.
    pub fn attrset_keys(&self, path: &[&str]) -> Option<Vec<String>> {
        let root = parse_root(&self.source)?;
        let attrset = root.expr().and_then(root_expr_to_attrset)?;
        let mut keys = Vec::new();
        if collect_child_keys(&attrset, path, &mut keys) {
            keys.sort();
            keys.dedup();
            Some(keys)
        } else {
            None
        }
    }

    /// Set the value at `path` to `replacement` (raw Nix text), creating
    /// the binding when it is absent.
    ///
    /// Two splice shapes, both byte-local so the lossless round-trip law
    /// holds for every other span in the file:
    ///   - the path already resolves to a value: only that value's span
    ///     is replaced;
    ///   - it does not: one new `<remaining> = <replacement>;` entry is
    ///     spliced into the deepest existing attrset on the path.
    ///
    /// [`SetError::NotFound`] means the path is *blocked* — some
    /// ancestor is a non-attrset value, or an existing entry already
    /// owns an overlapping name — so no insertion could be valid.
    pub fn set_attrpath(&mut self, path: &[&str], replacement: &str) -> Result<(), SetError> {
        assert!(!path.is_empty(), "set_attrpath requires a non-empty path");
        let root = parse_root(&self.source)
            .ok_or_else(|| SetError::InvalidValue("source file does not parse".to_string()))?;
        let candidate = match find_value_node(&root, path) {
            Some(node) => splice_span(&self.source, &node, replacement),
            None => {
                let point = insert_point(&root, path)
                    .ok_or_else(|| SetError::NotFound(path.join(".")))?;
                splice_entry(&self.source, &point, replacement)
            }
        };
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
        if !names
            .iter()
            .zip(path.iter())
            .all(|(name, segment)| name == segment)
        {
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

/// Replace `node`'s span in `source` with `replacement`, byte for byte.
fn splice_span(source: &str, node: &SyntaxNode, replacement: &str) -> String {
    let span = node.text_range();
    let (start, end): (usize, usize) = (span.start().into(), span.end().into());
    let mut candidate = String::with_capacity(source.len() + replacement.len());
    candidate.push_str(&source[..start]);
    candidate.push_str(replacement);
    candidate.push_str(&source[end..]);
    candidate
}

/// A missing binding's home: the deepest existing attrset on the path,
/// plus the suffix of the path that is not yet bound underneath it.
struct InsertPoint {
    attrset: ast::AttrSet,
    remaining: Vec<String>,
}

/// Walk `path` as deep as existing attrsets allow. `None` when the path
/// is blocked: an ancestor is a non-attrset value, or an existing entry
/// already owns an overlapping name (Nix would reject the result).
fn insert_point(root: &rnix::Root, path: &[&str]) -> Option<InsertPoint> {
    let attrset = root.expr().and_then(root_expr_to_attrset)?;
    descend(attrset, path)
}

fn descend(attrset: ast::AttrSet, path: &[&str]) -> Option<InsertPoint> {
    for entry in attrset.entries() {
        let ast::Entry::AttrpathValue(kv) = entry else {
            continue;
        };
        let Some(attrpath) = kv.attrpath() else {
            continue;
        };
        let names: Vec<String> = attrpath.attrs().filter_map(|a| attr_name(&a)).collect();
        if names.is_empty() || names.len() > path.len() {
            // A longer name is only a conflict when the requested path is
            // a strict prefix of it (`fortress` vs `fortress.baseDomain`).
            if !names.is_empty() && is_strict_prefix(path, &names) {
                return None;
            }
            continue;
        }
        if !names
            .iter()
            .zip(path.iter())
            .all(|(name, segment)| name == segment)
        {
            continue;
        }
        let Some(value) = kv.value() else {
            continue;
        };
        if names.len() == path.len() {
            // `find_value_node` already handled "resolves to a value", so
            // landing here means the entry's value is not something we
            // can extend.
            return None;
        }
        let ast::Expr::AttrSet(inner) = value else {
            // `fortress = 5;` blocks `fortress.services.…`.
            return None;
        };
        return descend(inner, &path[names.len()..]);
    }
    Some(InsertPoint {
        attrset,
        remaining: path.iter().map(|s| s.to_string()).collect(),
    })
}

/// Is `short` a strict prefix of `long`?
fn is_strict_prefix(short: &[&str], long: &[String]) -> bool {
    short.len() < long.len()
        && short
            .iter()
            .zip(long.iter())
            .all(|(a, b)| a == b)
}

/// Splice a brand-new `remaining = replacement;` entry into `point`'s
/// attrset. Everything outside that one insertion stays byte-identical.
fn splice_entry(source: &str, point: &InsertPoint, replacement: &str) -> String {
    assert!(
        !point.remaining.is_empty(),
        "insert point must carry an unbound path suffix"
    );
    let range = point.attrset.syntax().text_range();
    let (open, close): (usize, usize) = (range.start().into(), range.end().into());
    assert!(
        source[open..close].starts_with('{') && source[open..close].ends_with('}'),
        "insert target must be an attrset literal"
    );

    // Insert after the last entry (or just after `{` when empty), so the
    // closing brace keeps its own line untouched.
    let insert_at: usize = point
        .attrset
        .entries()
        .map(|e| {
            let end = e.syntax().text_range().end();
            usize::from(end)
        })
        .last()
        .unwrap_or(open + 1);

    let indent = entry_indent(source, open, insert_at);
    let dotted = point.remaining.join(".");
    let addition = format!("\n{indent}{dotted} = {replacement};");

    let mut candidate = String::with_capacity(source.len() + addition.len());
    candidate.push_str(&source[..insert_at]);
    candidate.push_str(&addition);
    candidate.push_str(&source[insert_at..]);
    candidate
}

/// Indentation for a new entry: match the first existing entry's line, or
/// sit two spaces inside the braces when the attrset is empty.
fn entry_indent(source: &str, open: usize, insert_at: usize) -> String {
    let body = &source[open..insert_at];
    if let Some(line_start) = body.rfind('\n') {
        let line = &body[line_start + 1..];
        let trimmed = line.trim_start();
        if !trimmed.is_empty() {
            return " ".repeat(line.len() - trimmed.len());
        }
    }
    "  ".to_string()
}

/// Collect the names bound directly under `attrset` at `path`. Each
/// matching entry contributes the segment at `path.len()` (for a dotted
/// key that extends past the target) or recurses (for a nested or
/// shorter prefix). Returns `false` when nothing at `path` exists.
fn collect_child_keys(attrset: &ast::AttrSet, path: &[&str], keys: &mut Vec<String>) -> bool {
    let mut found = false;
    for entry in attrset.entries() {
        let ast::Entry::AttrpathValue(kv) = entry else {
            continue;
        };
        let Some(attrpath) = kv.attrpath() else {
            continue;
        };
        let names: Vec<String> = attrpath.attrs().filter_map(|a| attr_name(&a)).collect();
        if names.is_empty() {
            continue;
        }
        if !names
            .iter()
            .zip(path.iter())
            .all(|(name, segment)| name == segment)
        {
            continue;
        }
        let Some(value) = kv.value() else {
            continue;
        };
        if names.len() > path.len() {
            if let Some(child) = names.get(path.len()) {
                keys.push(child.clone());
            }
            found = true;
        } else if let ast::Expr::AttrSet(inner) = value {
            if collect_child_keys(&inner, &path[names.len()..], keys) {
                found = true;
            }
        }
    }
    found
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
    if parts
        .iter()
        .any(|p| matches!(p, InterpolPart::Interpolation(_)))
    {
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
            root_domain: vec!["fortress", "baseDomain"],
            services_root: vec!["fortress", "services"],
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
        nixname: "forgejo",
        display_name: "Forgejo",
        description: "Your own git forge, with single sign-on",
    },
    ServiceInfo {
        nixname: "media",
        display_name: "Media Automation",
        description: "One switch: search, request, download movies and TV",
    },
];

/// One user as declared in the config file.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct CocoUser {
    pub username: String,
    pub hashed_password: Option<String>,
    pub groups: BTreeSet<String>,
    /// Whether a `groups` binding exists in the file. When false, the
    /// dashboard renders the user read-only: the parser cannot insert a
    /// binding, so "editing" groups would silently do nothing.
    pub groups_declared: bool,
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
pub struct FortressConfig {
    pub hostname: Option<String>,
    pub root_domain: Option<String>,
    pub services_enabled: BTreeMap<&'static str, bool>,
    pub users: BTreeMap<String, CocoUser>,
}

impl FortressConfig {
    /// Extract the known fields from a file using `schema`'s paths.
    pub fn extract(file: &NixConfigFile, schema: &ConfigSchema) -> Self {
        let hostname =
            file.find_attrpath(&schema.hostname)
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
                let mut groups_declared = false;
                let mut groups_path = schema.users_root.clone();
                groups_path.push(&name);
                groups_path.push("groups");
                if let Some(located) = file.find_attrpath(&groups_path) {
                    if let NixValue::StrList(list) = located.value {
                        groups = list.into_iter().collect();
                        groups_declared = true;
                    }
                }

                users.insert(
                    name.clone(),
                    CocoUser {
                        username: name,
                        hashed_password,
                        groups,
                        groups_declared,
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
  fortress = {
    baseDomain = "vmtest.local";
    services.jellyfin = {
      enable = true;
      public = true;
    };
    services.cryptpad = {
      enable = true;
      public = true;
    };
    services.media.enable = false;
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
        for garbage in ["", "{", "}{", "fortress = ", "not nix at all !!!", "}"] {
            assert!(
                NixConfigFile::parse(garbage).is_err(),
                "should reject {garbage:?}"
            );
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
            .find_attrpath(&["fortress", "baseDomain"])
            .expect("domain present");
        assert_eq!(domain.value, NixValue::Str("vmtest.local".to_string()));

        let jellyfin = file
            .find_attrpath(&["fortress", "services", "jellyfin", "enable"])
            .expect("jellyfin enable present");
        assert_eq!(jellyfin.value, NixValue::Bool(true));

        let media = file
            .find_attrpath(&["fortress", "services", "media", "enable"])
            .expect("media enable present");
        assert_eq!(media.value, NixValue::Bool(false));

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
        assert!(file.find_attrpath(&["fortress", "nope"]).is_none());
        assert!(file.find_attrpath(&["nope"]).is_none());
        assert!(file
            .find_attrpath(&["fortress", "services", "sonarr", "enable"])
            .is_none());
        assert!(file.find_attrpath(&[]).is_none());
    }

    #[test]
    fn path_landing_mid_expression_is_none() {
        let file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        assert!(
            file.find_attrpath(&["fortress", "services", "jellyfin"])
                .is_some(),
            "an attrset at a path is still a value"
        );
        assert!(
            file.find_attrpath(&["fortress", "services", "jellyfin", "enable", "deeper"])
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
        file.set_attrpath(&["fortress", "services", "jellyfin", "enable"], "false")
            .expect("edit succeeds");

        let updated = file.to_source();
        let jellyfin_block_after =
            "services.jellyfin = {\n      enable = false;\n      public = true;\n    };";
        let jellyfin_block_before =
            "services.jellyfin = {\n      enable = true;\n      public = true;\n    };";
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
            .find_attrpath(&["fortress", "services", "jellyfin", "enable"])
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
    fn set_attrpath_inserts_a_missing_binding() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        file.set_attrpath(&["fortress", "services", "sonarr", "enable"], "true")
            .expect("insert succeeds");

        let updated = file.to_source();
        assert!(
            updated.contains("services.sonarr.enable = true;"),
            "binding must be created: {updated}"
        );
        let reparse = NixConfigFile::parse(updated.to_string()).expect("insert stays valid nix");
        let sonarr = reparse
            .find_attrpath(&["fortress", "services", "sonarr", "enable"])
            .expect("new binding is findable");
        assert_eq!(sonarr.value, NixValue::Bool(true));
    }

    /// The new entry lands in the deepest attrset already on the path,
    /// not at the file root — so it merges with `services.jellyfin`
    /// instead of re-declaring `fortress`. Indentation is the proof:
    /// root entries sit at two spaces, `fortress`'s at four.
    #[test]
    fn set_attrpath_inserts_into_the_deepest_existing_attrset() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        file.set_attrpath(&["fortress", "services", "sonarr", "enable"], "true")
            .expect("insert succeeds");

        let updated = file.to_source();
        assert!(
            updated.contains("\n    services.sonarr.enable = true;"),
            "entry must sit at the fortress block's four-space indent: {updated}"
        );
        assert!(
            !updated.contains("\n  services.sonarr.enable = true;"),
            "entry must not be re-declared at the file root: {updated}"
        );
    }

    /// Insertion is byte-local: the untouched text survives exactly.
    #[test]
    fn set_attrpath_insert_preserves_every_other_span() {
        let original = VMTEST_STYLE.to_string();
        let mut file = NixConfigFile::parse(original.clone()).unwrap();
        file.set_attrpath(&["fortress", "services", "sonarr", "enable"], "true")
            .expect("insert succeeds");

        let updated = file.to_source();
        assert!(
            updated.len() > original.len(),
            "an insertion can only grow the file"
        );
        for chunk in [
            "{ config, lib, pkgs, inputs, ... }:",
            "  domain = \"vmtest.local\";",
            "  baseDomain = \"vmtest.local\";",
            "  networking.hostName = \"vmtest\";",
            "    groups = [ \"wheel\" \"storage\" ];",
        ] {
            assert!(updated.contains(chunk), "span must survive: {chunk}");
        }
    }

    #[test]
    fn set_attrpath_inserts_a_whole_branch_under_a_dotted_prefix() {
        // `dashboard.nix` style: no `fortress = { … }` block, only dotted
        // keys at the root. The new branch must still be valid Nix.
        let source = "{\n  fortress.baseDomain = \"vmtest.local\";\n}\n";
        let mut file = NixConfigFile::parse(source.to_string()).unwrap();
        file.set_attrpath(&["fortress", "services", "sonarr", "enable"], "true")
            .expect("insert succeeds");

        let updated = file.to_source();
        assert!(
            updated.contains("fortress.services.sonarr.enable = true;"),
            "root-level dotted insertion: {updated}"
        );
        NixConfigFile::parse(updated.to_string()).expect("stays valid nix");
    }

    #[test]
    fn set_attrpath_fails_when_an_ancestor_is_not_an_attrset() {
        let source = "{ fortress.baseDomain = \"vmtest.local\"; }";
        let mut file = NixConfigFile::parse(source.to_string()).unwrap();
        // `fortress` is a namespace here; assigning to it would collide
        // with `fortress.baseDomain`.
        let result = file.set_attrpath(&["fortress"], "5");
        assert!(matches!(result, Err(SetError::NotFound(p)) if p == "fortress"));
        assert_eq!(file.to_source(), source, "blocked edit must not touch the file");
    }

    #[test]
    fn set_attrpath_fails_when_a_deeper_value_blocks_the_branch() {
        let source = "{\n  fortress.services = 5;\n}\n";
        let mut file = NixConfigFile::parse(source.to_string()).unwrap();
        let result = file.set_attrpath(&["fortress", "services", "sonarr", "enable"], "true");
        assert!(matches!(result, Err(SetError::NotFound(_))));
        assert_eq!(file.to_source(), source, "blocked edit must not touch the file");
    }

    #[test]
    fn set_invalid_value_is_rejected() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        let result = file.set_attrpath(&["networking", "hostName"], "}");
        assert!(matches!(result, Err(SetError::InvalidValue(_))));
        assert_eq!(
            file.to_source(),
            VMTEST_STYLE,
            "invalid edit must not touch the file"
        );
    }

    #[test]
    fn set_then_set_back_round_trips() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        file.set_attrpath(&["fortress", "services", "jellyfin", "enable"], "false")
            .unwrap();
        file.set_attrpath(&["fortress", "services", "jellyfin", "enable"], "true")
            .unwrap();
        assert_eq!(file.to_source(), VMTEST_STYLE);
    }

    #[test]
    fn extract_known_fields() {
        let file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        let config = FortressConfig::extract(&file, &ConfigSchema::default());

        assert_eq!(config.hostname.as_deref(), Some("vmtest"));
        assert_eq!(config.root_domain.as_deref(), Some("vmtest.local"));
        assert_eq!(config.services_enabled.get("jellyfin"), Some(&true));
        assert_eq!(config.services_enabled.get("cryptpad"), Some(&true));
        assert_eq!(config.services_enabled.get("media"), Some(&false));
        assert_eq!(
            config.services_enabled.get("sonarr"),
            None,
            "not declared in file"
        );

        let nicole = config.users.get("nicole").expect("nicole present");
        assert_eq!(
            nicole.hashed_password.as_deref(),
            Some("$2b$10$abcdefghijklmnopqrstuv")
        );
        assert!(nicole.is_admin());
        assert!(
            nicole.groups_declared,
            "nicole declares groups in the fixture"
        );
        assert!(config.users.get("carl").is_none());
    }

    #[test]
    fn extract_missing_fields_are_none() {
        let file = NixConfigFile::parse("{}").unwrap();
        let config = FortressConfig::extract(&file, &ConfigSchema::default());
        assert_eq!(config.hostname, None);
        assert_eq!(config.root_domain, None);
        assert!(config.services_enabled.is_empty());
        assert!(config.users.is_empty());
    }

    #[test]
    fn attrset_keys_handles_dotted_prefixes() {
        let dotted = NixConfigFile::parse(
            "{ users.users.nicole = { groups = [ \"wheel\" ]; }; users.users.carl = { }; }",
        )
        .expect("dotted keys parse");
        let keys = dotted
            .attrset_keys(&["users", "users"])
            .expect("users present under dotted prefix");
        assert_eq!(keys, vec!["carl".to_string(), "nicole".to_string()]);

        let nested = NixConfigFile::parse("{ users.users = { nicole = { }; carl = { }; }; }")
            .expect("nested keys parse");
        let keys = nested
            .attrset_keys(&["users", "users"])
            .expect("users present under nested prefix");
        assert_eq!(keys, vec!["carl".to_string(), "nicole".to_string()]);

        let absent = NixConfigFile::parse("{}").expect("empty parse");
        assert!(absent.attrset_keys(&["users", "users"]).is_none());
    }

    #[test]
    fn extract_reads_groups_from_dotted_user_keys() {
        let file = NixConfigFile::parse(
            "{ users.users.nicole = { groups = [ \"wheel\" \"storage\" ]; }; }",
        )
        .expect("dotted users parse");
        let config = FortressConfig::extract(&file, &ConfigSchema::default());
        let nicole = config.users.get("nicole").expect("nicole present");
        assert!(nicole.groups_declared);
        assert!(nicole.groups.contains("wheel"));
    }

    #[test]
    fn user_admin_flag_matches_wheel_group() {
        let mut user = CocoUser {
            username: "bob".to_string(),
            hashed_password: None,
            groups: BTreeSet::new(),
            groups_declared: true,
        };
        assert!(!user.is_admin());
        user.groups.insert("wheel".to_string());
        assert!(user.is_admin());
    }

    #[test]
    fn to_source_renders_bool_str_strlist() {
        assert_eq!(NixValue::Bool(true).to_source(), "true");
        assert_eq!(NixValue::Bool(false).to_source(), "false");
        assert_eq!(
            NixValue::Str("vmtest".to_string()).to_source(),
            "\"vmtest\""
        );
        assert_eq!(
            NixValue::StrList(vec!["wheel".to_string(), "storage".to_string()]).to_source(),
            "[ \"wheel\" \"storage\" ]"
        );
    }

    #[test]
    fn to_source_escapes_nix_string_characters() {
        assert_eq!(
            NixValue::Str("say \"hi\"".to_string()).to_source(),
            "\"say \\\"hi\\\"\""
        );
        assert_eq!(NixValue::Str("a\\b".to_string()).to_source(), "\"a\\\\b\"");
        assert_eq!(
            NixValue::Str("line\nbreak".to_string()).to_source(),
            "\"line\\nbreak\""
        );
    }

    #[test]
    fn to_source_other_is_lossless_raw() {
        assert_eq!(NixValue::Other("true".to_string()).to_source(), "true");
        assert_eq!(
            NixValue::Other("\"raw\"".to_string()).to_source(),
            "\"raw\""
        );
    }

    #[test]
    fn serialize_splice_reparse_round_trips() {
        for (value, expect) in [
            (NixValue::Bool(true), true),
            (NixValue::Bool(false), false),
            (NixValue::Str("other".to_string()), true),
        ] {
            let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
            file.set_attrpath(&["networking", "hostName"], &value.to_source())
                .unwrap();
            let reparse = NixConfigFile::parse(file.to_source().to_string()).unwrap();
            let reextract = reparse
                .find_attrpath(&["networking", "hostName"])
                .expect("field survives");
            match value {
                NixValue::Bool(b) => assert_eq!(reextract.value, NixValue::Bool(b)),
                NixValue::Str(s) => assert_eq!(reextract.value, NixValue::Str(s)),
                _ => unreachable!("string case only"),
            }
            let _ = expect;
        }
    }

    #[test]
    fn serialize_strlist_round_trips_through_groups() {
        let mut file = NixConfigFile::parse(VMTEST_STYLE.to_string()).unwrap();
        let groups = NixValue::StrList(vec!["wheel".to_string(), "docker".to_string()]);
        file.set_attrpath(&["users", "users", "nicole", "groups"], &groups.to_source())
            .unwrap();
        let reparse = NixConfigFile::parse(file.to_source().to_string()).unwrap();
        let located = reparse
            .find_attrpath(&["users", "users", "nicole", "groups"])
            .expect("groups survive");
        assert_eq!(located.value, groups);
    }
}
