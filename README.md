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
