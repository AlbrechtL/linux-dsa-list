#!/usr/bin/env bash
# Generate one DSA feature-matrix CSV and one chip-list CSV per Linux kernel
# release line from 6.8 through 7.0.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MATRIX_GENERATOR="${REPO_ROOT}/scripts/generate_dsa_feature_matrix.py"
CHIP_GENERATOR="${REPO_ROOT}/scripts/generate_dsa_driver_chip_list.py"

OUTPUT_DIR="${REPO_ROOT}/data"
CACHE_DIR="${REPO_ROOT}/.cache/kernel-archives"
KEEP_ARCHIVES=1
STOP_ON_ERROR=0
TRANSPOSE=0
WARN_UNRESOLVED_CHIPS=0
CHIP_DELIMITER='; '

START_MINOR=8
END_MAJOR=7
END_MINOR=0
SINGLE_VERSION=""
FROM_VERSION=""
TO_VERSION=""

print_usage() {
	cat <<'EOF'
Usage:
  scripts/generate_dsa_versioned_reports.sh [options]

Options:
  --version X.Y            Process only a specific kernel version (e.g., 6.8).
  --from X.Y               Start version (default: 6.8).
  --to X.Y                 End version (default: 7.0).
  --output-dir PATH        Directory for generated CSV files.
                           Default: ./out/matrices
  --cache-dir PATH         Directory for downloaded kernel archives.
                           Default: ./.cache/kernel-archives
  --no-cache               Delete archives after each successful version run.
  --stop-on-error          Stop immediately when one version fails.
  --transpose              Generate transposed matrix CSV (drivers as rows).
  --warn-unresolved-chips  Pass --warn-unresolved to chip-list generator.
  --chip-delimiter TEXT    Delimiter inside chips cell. Default: '; '
  -h, --help               Show this help.

Outputs per version:
  dsa_feature_matrix_linux_<version>.csv
  dsa_driver_chip_list_linux_<version>.csv

Examples:
  # Process only version 6.8
  scripts/generate_dsa_versioned_reports.sh --version 6.8

  # Process versions 6.10 through 6.15
  scripts/generate_dsa_versioned_reports.sh --from 6.10 --to 6.15

Scope:
  - Linux-only generation (no OpenWrt parsing)
  - Exact release tar archives only
EOF
}

log() {
	printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

err() {
	printf 'Error: %s\n' "$*" >&2
}

require_cmd() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		err "missing required command: ${cmd}"
		exit 1
	fi
}

url_exists() {
	local url="$1"
	if command -v curl >/dev/null 2>&1; then
		curl -fsI "$url" >/dev/null
		return $?
	fi
	wget -q --spider "$url"
}

choose_archive_format() {
	local version="$1"
	local major="${version%%.*}"
	local base="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${version}.tar"

	if url_exists "${base}.xz"; then
		printf 'xz'
		return 0
	fi
	if url_exists "${base}.gz"; then
		printf 'gz'
		return 0
	fi

	return 1
}

download_archive() {
	local url="$1"
	local out_path="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fL "$url" -o "$out_path"
		return $?
	fi
	wget -O "$out_path" "$url"
}

run_matrix_generator() {
	local linux_root="$1"
	local out_csv="$2"
	local transpose="$3"

	if [[ "$transpose" -eq 1 ]]; then
		python3 "$MATRIX_GENERATOR" \
			--linux-root "$linux_root" \
			--out "$out_csv" \
			--column-mode relative \
			--transpose
		return $?
	fi

	python3 "$MATRIX_GENERATOR" \
		--linux-root "$linux_root" \
		--out "$out_csv" \
		--column-mode relative
}

run_chip_generator() {
	local linux_root="$1"
	local input_csv="$2"
	local out_csv="$3"

	if [[ "$WARN_UNRESOLVED_CHIPS" -eq 1 ]]; then
		python3 "$CHIP_GENERATOR" \
			--input-csv "$input_csv" \
			--linux-root "$linux_root" \
			--out "$out_csv" \
			--chip-delimiter "$CHIP_DELIMITER" \
			--warn-unresolved
		return $?
	fi

	python3 "$CHIP_GENERATOR" \
		--input-csv "$input_csv" \
		--linux-root "$linux_root" \
		--out "$out_csv" \
		--chip-delimiter "$CHIP_DELIMITER"
}

discover_versions() {
	local versions=()
	local minor="$START_MINOR"
	local candidate
	local from_minor="$START_MINOR"
	local from_major=6
	local to_minor="$END_MINOR"
	local to_major="$END_MAJOR"

	# Parse --from and --to if set
	if [[ -n "$FROM_VERSION" ]]; then
		from_major="${FROM_VERSION%%.*}"
		from_minor="${FROM_VERSION##*.}"
	fi
	if [[ -n "$TO_VERSION" ]]; then
		to_major="${TO_VERSION%%.*}"
		to_minor="${TO_VERSION##*.}"
	fi

	# Single version mode
	if [[ -n "$SINGLE_VERSION" ]]; then
		if choose_archive_format "$SINGLE_VERSION" >/dev/null; then
			versions+=("$SINGLE_VERSION")
		else
			err "version ${SINGLE_VERSION} not found on kernel CDN"
			return 1
		fi
		printf '%s\n' "${versions[@]}"
		return 0
	fi

	# Range mode
	if [[ "$from_major" -eq 6 ]]; then
		minor="$from_minor"
		while :; do
			candidate="6.${minor}"
			# Stop if we've passed the end version
			if [[ "$to_major" -eq 6 && "$minor" -gt "$to_minor" ]]; then
				break
			fi
			if choose_archive_format "$candidate" >/dev/null; then
				versions+=("$candidate")
				minor=$((minor + 1))
				continue
			fi
			break
		done
	fi

	# Add 7.0 if not already in 6.x range and within bounds
	if [[ "$to_major" -ge 7 ]]; then
		candidate="7.0"
		if choose_archive_format "$candidate" >/dev/null; then
			versions+=("$candidate")
		fi
	fi

	if [[ ${#versions[@]} -eq 0 ]]; then
		err "no versions found in specified range"
		return 1
	fi

	printf '%s\n' "${versions[@]}"
}

find_extracted_root() {
	local work_dir="$1"
	local expected_version="$2"
	local expected="${work_dir}/linux-${expected_version}"
	if [[ -d "$expected" ]]; then
		printf '%s\n' "$expected"
		return 0
	fi

	local first_dir
	first_dir="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
	if [[ -n "$first_dir" ]]; then
		printf '%s\n' "$first_dir"
		return 0
	fi

	return 1
}

process_version() {
	local version="$1"
	local archive_ext archive_url archive_name archive_path
	local work_dir linux_root matrix_csv chip_csv chip_input_csv temp_transposed_csv

	archive_ext="$(choose_archive_format "$version")" || {
		err "could not find archive format for ${version}"
		return 1
	}

	archive_name="linux-${version}.tar.${archive_ext}"
	archive_url="https://cdn.kernel.org/pub/linux/kernel/v${version%%.*}.x/${archive_name}"
	archive_path="${CACHE_DIR}/${archive_name}"

	if [[ ! -f "$archive_path" ]]; then
		log "Downloading ${archive_url}"
		if ! download_archive "$archive_url" "$archive_path"; then
			err "download failed for ${version}"
			return 1
		fi
	else
		log "Reusing cached archive ${archive_name}"
	fi

	work_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-dsa-${version}.XXXXXX")"

	if ! tar -xf "$archive_path" -C "$work_dir"; then
		err "failed to extract ${archive_name}"
		rm -rf "$work_dir"
		return 1
	fi

	linux_root="$(find_extracted_root "$work_dir" "$version")" || {
		err "could not find extracted root for ${version}"
		rm -rf "$work_dir"
		return 1
	}

	if [[ ! -f "${linux_root}/Makefile" ]] || [[ ! -f "${linux_root}/include/net/dsa.h" ]]; then
		err "invalid linux source tree for ${version}: ${linux_root}"
		rm -rf "$work_dir"
		return 1
	fi

	matrix_csv="${OUTPUT_DIR}/dsa_feature_matrix_linux_${version}.csv"
	chip_csv="${OUTPUT_DIR}/dsa_driver_chip_list_linux_${version}.csv"
	log "Generating ${matrix_csv}"

	if ! run_matrix_generator "$linux_root" "$matrix_csv" "$TRANSPOSE"; then
		err "feature matrix generation failed for ${version}"
		rm -rf "$work_dir"
		return 1
	fi

	chip_input_csv="$matrix_csv"
	if [[ "$TRANSPOSE" -ne 1 ]]; then
		temp_transposed_csv="${work_dir}/dsa_feature_matrix_linux_${version}_transpose.csv"
		log "Generating temporary transposed matrix for chip extraction"
		if ! run_matrix_generator "$linux_root" "$temp_transposed_csv" 1; then
			err "temporary transposed matrix generation failed for ${version}"
			rm -rf "$work_dir"
			return 1
		fi
		chip_input_csv="$temp_transposed_csv"
	fi

	log "Generating ${chip_csv}"
	if ! run_chip_generator "$linux_root" "$chip_input_csv" "$chip_csv"; then
		err "chip-list generation failed for ${version}"
		rm -rf "$work_dir"
		return 1
	fi

	rm -rf "$work_dir"

	if [[ "$KEEP_ARCHIVES" -eq 0 ]]; then
		rm -f "$archive_path"
	fi

	return 0
}

main() {
	local versions_text
	local -a versions=()
	local -a ok_versions=()
	local -a failed_versions=()
	local version

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--version)
				SINGLE_VERSION="$2"
				shift 2
				;;
			--from)
				FROM_VERSION="$2"
				shift 2
				;;
			--to)
				TO_VERSION="$2"
				shift 2
				;;
			--output-dir)
				OUTPUT_DIR="$2"
				shift 2
				;;
			--cache-dir)
				CACHE_DIR="$2"
				shift 2
				;;
			--no-cache)
				KEEP_ARCHIVES=0
				shift
				;;
			--stop-on-error)
				STOP_ON_ERROR=1
				shift
				;;
			--transpose)
				TRANSPOSE=1
				shift
				;;
			--warn-unresolved-chips)
				WARN_UNRESOLVED_CHIPS=1
				shift
				;;
			--chip-delimiter)
				CHIP_DELIMITER="$2"
				shift 2
				;;
			-h|--help)
				print_usage
				exit 0
				;;
			*)
				err "unknown argument: $1"
				print_usage
				exit 1
				;;
		esac
	done

	require_cmd python3
	require_cmd tar
	require_cmd mktemp
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		err "either curl or wget is required"
		exit 1
	fi
	if [[ ! -f "$MATRIX_GENERATOR" ]]; then
		err "matrix generator script not found: ${MATRIX_GENERATOR}"
		exit 1
	fi
	if [[ ! -f "$CHIP_GENERATOR" ]]; then
		err "chip-list generator script not found: ${CHIP_GENERATOR}"
		exit 1
	fi

	mkdir -p "$OUTPUT_DIR"
	mkdir -p "$CACHE_DIR"

	if ! versions_text="$(discover_versions)"; then
		exit 1
	fi
	mapfile -t versions <<<"$versions_text"

	log "Discovered versions: ${versions[*]}"

	for version in "${versions[@]}"; do
		if process_version "$version"; then
			ok_versions+=("$version")
		else
			failed_versions+=("$version")
			if [[ "$STOP_ON_ERROR" -eq 1 ]]; then
				break
			fi
		fi
	done

	log "Completed: ${#ok_versions[@]} success, ${#failed_versions[@]} failed"
	for version in "${ok_versions[@]}"; do
		printf '  OK     %s -> %s/dsa_feature_matrix_linux_%s.csv\n' \
			"$version" "$OUTPUT_DIR" "$version"
		printf '         %s/dsa_driver_chip_list_linux_%s.csv\n' \
			"$OUTPUT_DIR" "$version"
	done
	for version in "${failed_versions[@]}"; do
		printf '  FAILED %s\n' "$version"
	done

	if [[ ${#failed_versions[@]} -gt 0 ]]; then
		exit 1
	fi
}

main "$@"
