# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cococoir doc-refs check.
#
# L1: pure file-existence check. Catches the class of bug
# where AGENTS.md, PLAN.md, or a README points at a path
# that no longer exists. Cheap to run (just `test -e`),
# catches the "spec/" rot class of lie at every CI run.
#
# Strategy: scan the configured doc files for path-like
# substrings, and assert each path exists at the repo
# root. Paths that don't exist cause the build to fail
# with a clear error message.
#
# Why a derivation, not a shell command: the check must
# be a derivation so `nix flake check` runs it. The
# derivation's build script does the assertions and
# writes a human-readable report to $out.
{pkgs}:
let
  lib = pkgs.lib;

  # The doc files we scan. Adding a new doc file with
  # path references: add it here.
  docFiles = [
    ../AGENTS.md
    ../PLAN.md
  ];

  # Extract path-like substrings from a file. We use a
  # simple regex; full Markdown parsing is overkill for
  # what amounts to "find ./x, ../x, /x references".
  extractPaths = path: builtins.filter (s: lib.hasPrefix "/" s || lib.hasPrefix "./" s) (
    lib.splitString "\n" (builtins.readFile path)
  );
in
pkgs.runCommand "cococoir-doc-refs" {
  inherit docFiles;
  passAsFile = ["docFiles"];
} ''
  fail=0
  out_report=$out
  : > $out_report

  for doc in ${lib.concatMapStringsSep " " (p: "\"${toString p}\"") docFiles}; do
    echo "scanning $doc" >> $out_report
    # Grep for paths that look like ./x, ../x, or /x/y references.
    # Filter out URLs (https://, http://) and absolute system paths
    # like /nix/store which are not "this repo" references.
    grep -oE '`?\./[A-Za-z0-9._/-]+`?|`?\.\./[A-Za-z0-9._/-]+`?' "$doc" \
      | tr -d '`' \
      | sort -u > "$doc.paths" || true
    # Also pick up things like \`./foo\` (we strip backticks above).

    while IFS= read -r p; do
      [ -z "$p" ] && continue
      # Resolve relative to the doc file's directory.
      doc_dir="$(dirname "$doc")"
      resolved="$(realpath -m --relative-to=. "$doc_dir/$p" 2>/dev/null || echo "$doc_dir/$p")"
      if [ -e "$resolved" ]; then
        echo "  ok: $p" >> $out_report
      else
        echo "FAIL: $doc references $p which does not exist (resolved: $resolved)" >> $out_report
        fail=1
      fi
    done < "$doc.paths"
  done

  if [ "$fail" -ne 0 ]; then
    echo "cococoir doc-refs: FAIL" >> $out_report
    cat $out_report >&2
    exit 1
  fi

  echo "cococoir doc-refs: PASS" >> $out_report
  echo "  docs: ${lib.length docFiles}" >> $out_report
''
