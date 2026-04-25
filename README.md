# linux-dsa-feature-overview

Generate a CSV overview of Linux DSA driver feature support by parsing:

- `linux/include/net/dsa.h` for `struct dsa_switch_ops` feature definitions
- `linux/drivers/net/dsa/**/*.c` for driver `dsa_switch_ops` initializers

Optionally, include OpenWrt kernel patch-based DSA drivers and mark them with
an `openwrt:` prefix in the matrix.

The generator marks a feature as supported (`x`) when a driver initializes the
corresponding callback in its `struct dsa_switch_ops` initializer.

The repository also includes a second generator that consumes the transposed
feature matrix and writes one chip-list row per driver.

## Generator

Script:

- `scripts/generate_dsa_feature_matrix.py`
- `scripts/generate_dsa_driver_chip_list.py`

The script uses Python standard-library parsing only (no shell commands invoked
inside the Python code).

## Usage

Create and use a virtual environment in the repository root:

```bash
python -m venv .venv
source .venv/bin/activate
```

From repository root:

```bash
python scripts/generate_dsa_feature_matrix.py \
	--linux-root linux \
	--out dsa_feature_matrix.csv \
	--column-mode relative
```

### Swap rows and columns (drivers as rows)

```bash
python scripts/generate_dsa_feature_matrix.py \
	--linux-root linux \
	--out dsa_feature_matrix.csv \
	--column-mode relative \
	--transpose
```

### Include OpenWrt-patched and OpenWrt-only DSA drivers

```bash
python scripts/generate_dsa_feature_matrix.py \
	--linux-root linux \
	--include-openwrt \
	--openwrt-root openwrt \
	--out dsa_feature_matrix_openwrt.csv \
	--column-mode relative \
	--transpose
```

### Generate a chip-list CSV per driver

The chip-list generator expects a transposed input CSV whose first column is
`driver`, like `dsa_feature_matrix.csv` in this repository.

```bash
python scripts/generate_dsa_driver_chip_list.py \
	--input-csv dsa_feature_matrix.csv \
	--linux-root linux \
	--openwrt-root openwrt \
	--out dsa_driver_chip_list.csv
```

It resolves each driver row back to Linux or OpenWrt source files and extracts
chip names from chip tables, device-tree match tables, bus-specific device IDs,
and chip-ID macros. The output schema is:

```text
driver,chips
```

The `chips` field is a single CSV cell containing a delimiter-separated list of
chip names.

### Generate per-version matrix and chip-list files (6.8 to 7.0)

Use the wrapper script to download Linux source archives, generate one feature
matrix CSV and one driver chip-list CSV per minor line from 6.8 through 7.0,
and clean up extracted source trees.

```bash
scripts/generate_dsa_versioned_reports.sh
```

By default, generated files are written to:

```text
out/matrices/dsa_feature_matrix_linux_<version>.csv
out/matrices/dsa_driver_chip_list_linux_<version>.csv
```

Examples:

```bash
# Generate drivers-as-rows matrix output for each version
scripts/generate_dsa_versioned_reports.sh --transpose

# Process only a specific kernel version
scripts/generate_dsa_versioned_reports.sh --version 6.8

# Process versions from 6.10 through 6.15
scripts/generate_dsa_versioned_reports.sh --from 6.10 --to 6.15

# Keep output in a custom directory
scripts/generate_dsa_versioned_reports.sh --output-dir ./out/versioned-matrices

# Delete downloaded archives after each run
scripts/generate_dsa_versioned_reports.sh --no-cache

# Pass unresolved-row warnings to chip-list generation
scripts/generate_dsa_versioned_reports.sh --warn-unresolved-chips
```

## Browser Viewer

The repository includes a static browser-only viewer at `web/index.html`.
It loads both CSV files in the browser and renders a filterable driver-feature
matrix with an additional chips column.

### What it does

- consumes `dsa_feature_matrix.csv` (drivers as rows)
- consumes `dsa_driver_chip_list.csv` (chips per driver)
- joins both by the `driver` column
- supports feature filters (multi-select, match all selected features)
- keeps all data processing in client-side JavaScript (no backend)

### Run locally

From repository root:

```bash
python -m http.server 8000
```

Then open:

- `http://localhost:8000/web/`

The viewer first tries to load CSV files from repository root:

- `../dsa_feature_matrix.csv`
- `../dsa_driver_chip_list.csv`

and falls back to optional `web/data/*.csv` copies if present.

### Update workflow

1. Regenerate or replace `dsa_feature_matrix.csv`.
2. Regenerate or replace `dsa_driver_chip_list.csv`.
3. Refresh the browser page.

No HTML/JavaScript code changes are required if the CSV schema remains:

- feature matrix header starts with `driver`
- chip list header is `driver,chips`
- support cells are `x` (supported) or empty

## Arguments

- `--linux-root`: path to Linux source tree root (default: `./linux`)
- `--out`: output CSV path (default: `./dsa_feature_matrix.csv`)
- `--column-mode`: naming scheme for driver columns
	- `relative`: `drivers/net/dsa/...` path
	- `basename`: filename only
	- `ops-symbol`: `relative_path:ops_symbol`
- `--transpose`: swap matrix axes (rows become drivers, columns become features)
- `--warn-unknown-designators`: report initializer designators not found in
	`struct dsa_switch_ops`
- `--include-openwrt`: include OpenWrt DSA drivers parsed from OpenWrt kernel
	patches under `target/linux`
- `--openwrt-root`: path to OpenWrt source tree root (default: `./openwrt`)
- `--openwrt-exclude-do-not-submit`: exclude patch files containing
	`DO-NOT-SUBMIT` in filename

Chip-list generator arguments:

- `--input-csv`: transposed driver-first feature matrix to consume
- `--linux-root`: path to Linux source tree root (default: `./linux`)
- `--openwrt-root`: path to OpenWrt source tree root (default: `./openwrt`)
- `--out`: output CSV path (default: `./dsa_driver_chip_list.csv`)
- `--chip-delimiter`: delimiter used inside the `chips` field
- `--warn-unresolved`: print warnings for unresolved or ambiguous rows

## Disclaimer

This code was generated with AI assistance.
