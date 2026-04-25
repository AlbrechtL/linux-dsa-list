#!/usr/bin/env python3
"""Generate a CSV matrix of Linux DSA driver feature usage.

Rows are dsa_switch_ops callback names from include/net/dsa.h.
Columns are DSA driver source files under drivers/net/dsa.
A cell contains "x" if that driver initializes the callback in a
struct dsa_switch_ops initializer.

Optionally, the script can parse OpenWrt kernel patch files and extend the
matrix with OpenWrt-patched/new DSA drivers. These entries are labeled with an
"openwrt:" prefix.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Sequence, Set, Tuple


STRUCT_NAME = "dsa_switch_ops"
HEADER_REL = Path("include/net/dsa.h")
DRIVERS_REL = Path("drivers/net/dsa")
OPENWRT_PATCH_ROOT_REL = Path("target/linux")


def strip_c_comments(text: str) -> str:
    """Remove C // and /* */ comments while preserving literals."""
    out: List[str] = []
    i = 0
    n = len(text)
    in_line_comment = False
    in_block_comment = False
    in_string = False
    in_char = False

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if c == "\n":
                in_line_comment = False
                out.append(c)
            i += 1
            continue

        if in_block_comment:
            if c == "*" and nxt == "/":
                in_block_comment = False
                i += 2
            else:
                if c == "\n":
                    out.append(c)
                i += 1
            continue

        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue

        if in_char:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == "'":
                in_char = False
            i += 1
            continue

        if c == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue

        if c == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue

        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue

        if c == "'":
            in_char = True
            out.append(c)
            i += 1
            continue

        out.append(c)
        i += 1

    return "".join(out)


def find_matching_brace(text: str, open_brace_pos: int) -> int:
    """Return index of matching closing brace for text[open_brace_pos] == '{'."""
    if open_brace_pos < 0 or open_brace_pos >= len(text) or text[open_brace_pos] != "{":
        raise ValueError("open_brace_pos must point to '{'")

    depth = 0
    i = open_brace_pos
    n = len(text)
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1

    raise ValueError("no matching closing brace found")


def extract_struct_block(text: str, struct_name: str) -> str:
    """Extract body of 'struct <name> { ... }'."""
    m = re.search(rf"\bstruct\s+{re.escape(struct_name)}\s*\{{", text)
    if not m:
        raise ValueError(f"could not find definition for 'struct {struct_name}'")

    brace_open = m.end() - 1

    brace_close = find_matching_brace(text, brace_open)
    return text[brace_open + 1 : brace_close]


def parse_dsa_switch_ops_features(header_text: str) -> List[str]:
    """Parse function-pointer member names from struct dsa_switch_ops."""
    cleaned = strip_c_comments(header_text)
    block = extract_struct_block(cleaned, STRUCT_NAME)

    features: List[str] = []
    seen: Set[str] = set()

    # Match names from declarations like: int (*setup)(...);
    for match in re.finditer(r"\(\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\(", block, flags=re.S):
        name = match.group(1)
        if name not in seen:
            seen.add(name)
            features.append(name)

    if not features:
        raise ValueError("no dsa_switch_ops features were parsed from header")

    return features


def find_ops_initializers(cleaned_c_text: str) -> List[Tuple[str, str]]:
    """Return list of (symbol, initializer_body) for dsa_switch_ops objects."""
    pattern = re.compile(
        r"(?:^|[;\n])\s*(?:static\s+)?(?:const\s+)?struct\s+dsa_switch_ops\s+"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{",
        flags=re.M,
    )

    results: List[Tuple[str, str]] = []
    for match in pattern.finditer(cleaned_c_text):
        symbol = match.group(1)
        open_brace = cleaned_c_text.find("{", match.end() - 1)
        if open_brace == -1:
            continue
        try:
            close_brace = find_matching_brace(cleaned_c_text, open_brace)
        except ValueError:
            continue
        body = cleaned_c_text[open_brace + 1 : close_brace]
        results.append((symbol, body))

    return results


_IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def extract_top_level_designators(initializer_body: str) -> Set[str]:
    """Extract top-level .field = designators from an initializer body."""
    found: Set[str] = set()
    i = 0
    n = len(initializer_body)
    brace_depth = 0
    paren_depth = 0
    bracket_depth = 0

    while i < n:
        c = initializer_body[i]

        if c == "{":
            brace_depth += 1
            i += 1
            continue
        if c == "}":
            brace_depth = max(0, brace_depth - 1)
            i += 1
            continue
        if c == "(":
            paren_depth += 1
            i += 1
            continue
        if c == ")":
            paren_depth = max(0, paren_depth - 1)
            i += 1
            continue
        if c == "[":
            bracket_depth += 1
            i += 1
            continue
        if c == "]":
            bracket_depth = max(0, bracket_depth - 1)
            i += 1
            continue

        at_top = brace_depth == 0 and paren_depth == 0 and bracket_depth == 0
        if at_top and c == ".":
            m = _IDENTIFIER_RE.match(initializer_body, i + 1)
            if m:
                name = m.group(0)
                j = m.end()
                while j < n and initializer_body[j].isspace():
                    j += 1
                if j < n and initializer_body[j] == "=":
                    found.add(name)
                i = m.end()
                continue

        i += 1

    return found


def collect_linux_driver_feature_usage(
    linux_root: Path,
    known_features: Set[str],
    column_mode: str,
) -> Tuple[Dict[str, Set[str]], Dict[str, Set[str]]]:
    """Collect per-column feature sets and per-column unknown designators."""
    drivers_dir = linux_root / DRIVERS_REL
    if not drivers_dir.is_dir():
        raise FileNotFoundError(f"drivers directory not found: {drivers_dir}")

    feature_map: Dict[str, Set[str]] = {}
    unknown_map: Dict[str, Set[str]] = {}

    for c_file in sorted(drivers_dir.rglob("*.c")):
        text = c_file.read_text(encoding="utf-8", errors="ignore")

        # Cheap Python-only prefilter before deeper parsing.
        if "struct dsa_switch_ops" not in text or "=" not in text:
            continue

        cleaned = strip_c_comments(text)
        initializers = find_ops_initializers(cleaned)
        if not initializers:
            continue

        rel_path = c_file.relative_to(linux_root).as_posix()
        merged_features: Set[str] = set()
        merged_unknown: Set[str] = set()

        for symbol, body in initializers:
            designators = extract_top_level_designators(body)
            present = designators & known_features
            unknown = designators - known_features

            if column_mode == "ops-symbol":
                key = f"{rel_path}:{symbol}"
                feature_map[key] = set(present)
                if unknown:
                    unknown_map[key] = set(unknown)
            else:
                merged_features.update(present)
                merged_unknown.update(unknown)

        if column_mode != "ops-symbol":
            key = c_file.name if column_mode == "basename" else rel_path
            feature_map[key] = merged_features
            if merged_unknown:
                unknown_map[key] = merged_unknown

    return feature_map, unknown_map


def iter_openwrt_patch_files(openwrt_root: Path) -> Sequence[Path]:
    """Return sorted OpenWrt kernel patch files from target/linux tree."""
    patch_root = openwrt_root / OPENWRT_PATCH_ROOT_REL
    if not patch_root.is_dir():
        return []
    return sorted(patch_root.rglob("*.patch"))


def parse_patch_target_path(diff_header_line: str) -> str:
    """Extract normalized path from a +++ line in a unified diff."""
    # Examples:
    # +++ b/drivers/net/dsa/qca/qca8k-8xxx.c
    # +++ /dev/null
    value = diff_header_line[4:].strip()
    if value == "/dev/null":
        return ""
    if value.startswith("a/") or value.startswith("b/"):
        return value[2:]
    return value


def parse_openwrt_patch_driver_designator_deltas(
    patch_text: str,
    known_features: Set[str],
) -> Tuple[Dict[str, Set[str]], Dict[str, Set[str]], Dict[str, Set[str]]]:
    """Parse per-driver feature add/remove deltas from one patch.

    Returns (adds, removes, unknown_adds), all keyed by drivers/net/dsa/*.c path.
    """
    adds: Dict[str, Set[str]] = {}
    removes: Dict[str, Set[str]] = {}
    unknown_adds: Dict[str, Set[str]] = {}

    current_target = ""
    is_dsa_c_target = False
    in_ops = False
    brace_depth = 0

    for raw_line in patch_text.splitlines():
        if raw_line.startswith("@@"):
            # Hunk headers are a robust boundary for parser state.
            in_ops = False
            brace_depth = 0

            # Context snippet in hunk header can reveal dsa_switch_ops even
            # when the declaration line itself is not in the hunk body.
            if is_dsa_c_target and "struct dsa_switch_ops" in raw_line:
                in_ops = True
                brace_depth = 1
            continue

        if raw_line.startswith("+++"):
            current_target = parse_patch_target_path(raw_line)
            is_dsa_c_target = (
                current_target.startswith("drivers/net/dsa/")
                and current_target.endswith(".c")
            )
            in_ops = False
            brace_depth = 0
            continue

        # We only track content lines from unified diff hunks.
        if (
            not is_dsa_c_target
            or not raw_line
            or raw_line[0] not in (" ", "+", "-")
        ):
            continue
        if raw_line.startswith("+++") or raw_line.startswith("---"):
            continue

        line = raw_line[1:]

        # Enter dsa_switch_ops parsing when declaration appears in hunk body.
        if not in_ops and "struct dsa_switch_ops" in line:
            in_ops = True
            brace_depth = 0

        if not in_ops:
            continue

        # Track braces while in dsa_switch_ops initializer context.
        brace_depth += line.count("{") - line.count("}")

        m = re.match(r"\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m and raw_line[0] in ("+", "-"):
            name = m.group(1)
            if name in known_features:
                if raw_line[0] == "+":
                    adds.setdefault(current_target, set()).add(name)
                else:
                    removes.setdefault(current_target, set()).add(name)
            elif raw_line[0] == "+":
                unknown_adds.setdefault(current_target, set()).add(name)

        # Leave context when initializer closes.
        if brace_depth <= 0 and "}" in line:
            in_ops = False
            brace_depth = 0

    return adds, removes, unknown_adds


def format_openwrt_column_key(target_path: str, column_mode: str) -> str:
    """Build column key for an OpenWrt-derived driver entry."""
    if column_mode == "basename":
        return f"openwrt:{Path(target_path).name}"
    if column_mode == "ops-symbol":
        return f"openwrt:{target_path}:patched"
    return f"openwrt:{target_path}"


def iter_openwrt_source_files(openwrt_root: Path) -> Sequence[Tuple[Path, str]]:
    """Yield (c_file_path, normalized_dsa_path) for OpenWrt pre-applied source files.
    
    Scans target/linux/**/files-*/**/*.c and returns paths with normalized
    drivers/net/dsa/... paths for drivers that contain dsa_switch_ops.
    
    Returns (file_path, normalized_path) tuples where normalized_path is like:
      drivers/net/dsa/rtl83xx/dsa.c
    """
    patch_root = openwrt_root / OPENWRT_PATCH_ROOT_REL
    if not patch_root.is_dir():
        return []
    
    results: List[Tuple[Path, str]] = []
    for c_file in sorted(patch_root.rglob("*.c")):
        # Only look in files-*/ directories, not patch-*/ directories
        if "/files-" not in c_file.as_posix():
            continue
        
        text = c_file.read_text(encoding="utf-8", errors="ignore")
        if "struct dsa_switch_ops" not in text or "=" not in text:
            continue
        
        # Extract drivers/net/dsa/... path from file location.
        # E.g., target/linux/realtek/files-6.18/drivers/net/dsa/rtl83xx/dsa.c
        #   -> drivers/net/dsa/rtl83xx/dsa.c
        try:
            rel_to_root = c_file.relative_to(patch_root)
            parts = rel_to_root.parts
            
            # Find 'drivers' in path parts
            try:
                drivers_idx = parts.index("drivers")
                normalized = "/".join(parts[drivers_idx:])
                results.append((c_file, normalized))
            except ValueError:
                # No 'drivers' in path, skip
                continue
        except ValueError:
            continue
    
    return results


def collect_openwrt_source_driver_feature_usage(
    openwrt_root: Path,
    known_features: Set[str],
    column_mode: str,
) -> Tuple[Dict[str, Set[str]], Dict[str, Set[str]]]:
    """Collect DSA driver features from OpenWrt pre-applied source files in files-*/ dirs."""
    feature_map: Dict[str, Set[str]] = {}
    unknown_map: Dict[str, Set[str]] = {}

    for c_file, normalized_path in iter_openwrt_source_files(openwrt_root):
        text = c_file.read_text(encoding="utf-8", errors="ignore")
        cleaned = strip_c_comments(text)
        initializers = find_ops_initializers(cleaned)
        if not initializers:
            continue

        merged_features: Set[str] = set()
        merged_unknown: Set[str] = set()

        for symbol, body in initializers:
            designators = extract_top_level_designators(body)
            present = designators & known_features
            unknown = designators - known_features

            if column_mode == "ops-symbol":
                key = format_openwrt_column_key(f"{normalized_path}:{symbol}", column_mode)
                feature_map[key] = set(present)
                if unknown:
                    unknown_map[key] = set(unknown)
            else:
                merged_features.update(present)
                merged_unknown.update(unknown)

        if column_mode != "ops-symbol":
            key = format_openwrt_column_key(normalized_path, column_mode)
            feature_map[key] = merged_features
            if merged_unknown:
                unknown_map[key] = merged_unknown

    return feature_map, unknown_map


def collect_openwrt_driver_feature_usage(
    openwrt_root: Path,
    known_features: Set[str],
    linux_feature_map: Dict[str, Set[str]],
    column_mode: str,
    exclude_do_not_submit: bool,
) -> Tuple[Dict[str, Set[str]], Dict[str, Set[str]]]:
    """Collect OpenWrt-patched/new DSA driver features from patch files and source files."""
    feature_by_target: Dict[str, Set[str]] = {}
    unknown_by_target: Dict[str, Set[str]] = {}

    # Phase 1: Parse OpenWrt kernel patches
    for patch_file in iter_openwrt_patch_files(openwrt_root):
        if exclude_do_not_submit and "DO-NOT-SUBMIT" in patch_file.name:
            continue

        text = patch_file.read_text(encoding="utf-8", errors="ignore")
        adds, removes, unknown_adds = parse_openwrt_patch_driver_designator_deltas(
            text, known_features
        )

        touched_targets = set(adds.keys()) | set(removes.keys()) | set(unknown_adds.keys())
        for target in touched_targets:
            current = feature_by_target.setdefault(target, set())

            # Initialize from Linux baseline when available.
            if not current:
                baseline = linux_feature_map.get(target)
                if baseline:
                    current.update(baseline)

            current.update(adds.get(target, set()))
            current.difference_update(removes.get(target, set()))

            if target in unknown_adds:
                unknown_by_target.setdefault(target, set()).update(unknown_adds[target])

    # Phase 2: Parse OpenWrt pre-applied source files from files-*/ directories
    source_feature_map, source_unknown_map = collect_openwrt_source_driver_feature_usage(
        openwrt_root, known_features, column_mode
    )
    
    # Merge source file results into main feature map
    for key, feats in source_feature_map.items():
        # Extract normalized target path from key for deduplication check
        # Keys are like "openwrt:drivers/net/dsa/..." or "drivers/net/dsa/..."
        if key.startswith("openwrt:"):
            target_for_check = key[8:]  # strip "openwrt:" prefix
        else:
            target_for_check = key
        
        # Only add if not already present from patches (patches take precedence)
        if target_for_check not in feature_by_target:
            feature_by_target[target_for_check] = feats
            if key in source_unknown_map:
                unknown_by_target[target_for_check] = source_unknown_map[key]

    feature_map: Dict[str, Set[str]] = {}
    unknown_map: Dict[str, Set[str]] = {}
    for target, feats in feature_by_target.items():
        key = format_openwrt_column_key(target, column_mode)
        feature_map[key] = feats
        if target in unknown_by_target:
            unknown_map[key] = unknown_by_target[target]

    return feature_map, unknown_map


def get_linux_version(linux_root: Path) -> str:
    """Extract Linux kernel version from Makefile."""
    makefile = linux_root / "Makefile"
    if not makefile.is_file():
        return "unknown"
    
    text = makefile.read_text(encoding="utf-8", errors="ignore")
    version = None
    patchlevel = None
    sublevel = None
    
    for line in text.split("\n")[:30]:  # Check first 30 lines
        if line.startswith("VERSION"):
            m = re.search(r"=\s*(\d+)", line)
            if m:
                version = m.group(1)
        elif line.startswith("PATCHLEVEL"):
            m = re.search(r"=\s*(\d+)", line)
            if m:
                patchlevel = m.group(1)
        elif line.startswith("SUBLEVEL"):
            m = re.search(r"=\s*(\d+)", line)
            if m:
                sublevel = m.group(1)
    
    if version and patchlevel and sublevel:
        return f"{version}.{patchlevel}.{sublevel}"
    return "unknown"


def get_openwrt_version(openwrt_root: Path) -> str:
    """Extract OpenWrt version from git HEAD or VERSION file."""
    # Try to read git HEAD file for commit hash
    git_head = openwrt_root / ".git" / "HEAD"
    if git_head.is_file():
        try:
            head_content = git_head.read_text(encoding="utf-8", errors="ignore").strip()
            # HEAD typically contains "ref: refs/heads/master" or a commit hash
            if head_content.startswith("ref:"):
                # Read the actual ref file
                ref_path = head_content.split(":", 1)[1].strip()
                ref_file = openwrt_root / ".git" / ref_path
                if ref_file.is_file():
                    commit = ref_file.read_text(encoding="utf-8", errors="ignore").strip()[:7]
                    return f"git:{commit}"
            elif len(head_content) >= 7:
                # Direct commit hash in HEAD
                return f"git:{head_content[:7]}"
        except Exception:
            pass
    
    # Try VERSION file
    version_file = openwrt_root / "VERSION"
    if version_file.is_file():
        content = version_file.read_text(encoding="utf-8", errors="ignore").strip()
        if content:
            return content

    # Fallback for archive-based OpenWrt trees without .git metadata.
    version_mk = openwrt_root / "include" / "version.mk"
    if version_mk.is_file():
        text = version_mk.read_text(encoding="utf-8", errors="ignore")
        match = re.search(r"VERSION_NUMBER:=\$\(if\s+\$\(VERSION_NUMBER\),\$\(VERSION_NUMBER\),([^\)]+)\)", text)
        if match:
            inferred = match.group(1).strip()
            if inferred:
                return inferred
    
    return "unknown"


def current_utc_timestamp() -> str:
    """Return an ISO-8601 UTC timestamp for metadata comments."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def write_csv(
    out_path: Path,
    features: Sequence[str],
    columns: Sequence[str],
    feature_map: Dict[str, Set[str]],
    transpose: bool = False,
    linux_root: Path | None = None,
    openwrt_root: Path | None = None,
    include_openwrt: bool = False,
    openwrt_version_override: str | None = None,
) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        
        # Write metadata comments at the top
        if linux_root:
            linux_ver = get_linux_version(linux_root)
            writer.writerow([f"# Linux: {linux_ver}"])
        
        if include_openwrt and openwrt_root:
            openwrt_ver = openwrt_version_override or get_openwrt_version(openwrt_root)
            writer.writerow([f"# OpenWrt: {openwrt_ver}"])

        writer.writerow([f"# Generated: {current_utc_timestamp()}"])
        
        # Write empty line before header
        writer.writerow([])
        
        if not transpose:
            writer.writerow(["feature", *columns])
            for feat in features:
                row = [feat]
                for col in columns:
                    row.append("x" if feat in feature_map.get(col, set()) else "")
                writer.writerow(row)
            return

        writer.writerow(["driver", *features])
        for col in columns:
            row = [col]
            present = feature_map.get(col, set())
            for feat in features:
                row.append("x" if feat in present else "")
            writer.writerow(row)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--linux-root",
        type=Path,
        default=Path("linux"),
        help="Path to Linux source root (default: ./linux)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("dsa_feature_matrix.csv"),
        help="Output CSV path (default: ./dsa_feature_matrix.csv)",
    )
    parser.add_argument(
        "--column-mode",
        choices=("relative", "basename", "ops-symbol"),
        default="relative",
        help="How to name CSV columns (default: relative)",
    )
    parser.add_argument(
        "--warn-unknown-designators",
        action="store_true",
        help="Print designators found in ops initializers but absent from dsa_switch_ops",
    )
    parser.add_argument(
        "--transpose",
        action="store_true",
        help="Swap matrix axes: rows become drivers, columns become features",
    )
    parser.add_argument(
        "--include-openwrt",
        action="store_true",
        help="Include OpenWrt-patched/new DSA drivers from OpenWrt kernel patches",
    )
    parser.add_argument(
        "--openwrt-root",
        type=Path,
        default=Path("openwrt"),
        help="Path to OpenWrt source tree root (default: ./openwrt)",
    )
    parser.add_argument(
        "--openwrt-exclude-do-not-submit",
        action="store_true",
        help="Exclude OpenWrt patches with DO-NOT-SUBMIT in filename",
    )
    parser.add_argument(
        "--openwrt-version",
        default=None,
        help="Optional OpenWrt version string override for CSV metadata",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    linux_root = args.linux_root.resolve()

    header_path = linux_root / HEADER_REL
    if not header_path.is_file():
        print(f"error: header not found: {header_path}", file=sys.stderr)
        return 1

    header_text = header_path.read_text(encoding="utf-8", errors="ignore")
    features = parse_dsa_switch_ops_features(header_text)
    known_features = set(features)

    feature_map, unknown_map = collect_linux_driver_feature_usage(
        linux_root, known_features, args.column_mode
    )

    if args.include_openwrt:
        openwrt_root = args.openwrt_root.resolve()
        owrt_feature_map, owrt_unknown_map = collect_openwrt_driver_feature_usage(
            openwrt_root,
            known_features,
            feature_map,
            args.column_mode,
            args.openwrt_exclude_do_not_submit,
        )
        feature_map.update(owrt_feature_map)
        for key, values in owrt_unknown_map.items():
            unknown_map.setdefault(key, set()).update(values)

    columns = sorted(feature_map.keys())
    out_path = args.out
    if not out_path.is_absolute():
        out_path = Path.cwd() / out_path

    openwrt_root_for_csv = args.openwrt_root if args.include_openwrt else None
    write_csv(
        out_path,
        features,
        columns,
        feature_map,
        transpose=args.transpose,
        linux_root=linux_root,
        openwrt_root=openwrt_root_for_csv,
        include_openwrt=args.include_openwrt,
        openwrt_version_override=args.openwrt_version,
    )

    populated = sum(
        1
        for feat in features
        for col in columns
        if feat in feature_map.get(col, set())
    )
    print(
        f"wrote {out_path} | features={len(features)} drivers={len(columns)} marked_cells={populated}"
    )

    if args.warn_unknown_designators and unknown_map:
        print("unknown designators (not present in struct dsa_switch_ops):", file=sys.stderr)
        for col in sorted(unknown_map.keys()):
            vals = ", ".join(sorted(unknown_map[col]))
            print(f"  {col}: {vals}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
