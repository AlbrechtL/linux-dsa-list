#!/usr/bin/env bash
# Generate one DSA feature-matrix CSV and one chip-list CSV per Linux kernel
# release line, or per OpenWrt stable release line.

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
OPENWRT_RELEASES=0
OPENWRT_FROM=""
OPENWRT_TO=""
OPENWRT_RELEASES_URL="https://downloads.openwrt.org/releases/"
OPENWRT_SNAPSHOT=0
OPENWRT_SNAPSHOT_BRANCH="main"
OPENWRT_SNAPSHOT_LABEL="snapshot"

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
  --openwrt-releases       Process OpenWrt stable release lines.
  --openwrt-from X.Y       Start OpenWrt release line (default: 23.05).
  --openwrt-to X.Y|latest  End OpenWrt release line (default: latest).
  --openwrt-snapshot       Process OpenWrt main (unstable/master) branch.
  --output-dir PATH        Directory for generated CSV files.
                           Default: ./data
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

Outputs per OpenWrt release line:
  dsa_feature_matrix_openwrt_<release_line>.csv
  dsa_driver_chip_list_openwrt_<release_line>.csv

Outputs for OpenWrt snapshot:
	dsa_feature_matrix_openwrt_snapshot.csv
	dsa_driver_chip_list_openwrt_snapshot.csv

Examples:
  # Process only version 6.8
  scripts/generate_dsa_versioned_reports.sh --version 6.8

  # Process versions 6.10 through 6.15
  scripts/generate_dsa_versioned_reports.sh --from 6.10 --to 6.15

  # Process OpenWrt stable release lines from 23.05 to latest
  scripts/generate_dsa_versioned_reports.sh --openwrt-releases --openwrt-from 23.05 --openwrt-to latest

	# Process OpenWrt main (unstable) branch
	scripts/generate_dsa_versioned_reports.sh --openwrt-snapshot

Scope:
  - Linux release-line generation from kernel.org archives
  - OpenWrt release-line generation from OpenWrt stable lines
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

version_line_to_int() {
	local v="$1"
	local major minor
	major="${v%%.*}"
	minor="${v##*.}"
	printf '%d\n' "$((10#${major} * 100 + 10#${minor}))"
}

discover_openwrt_release_lines() {
	local page
	local line
	local -a found_lines=()
	local -A seen=()

	if command -v curl >/dev/null 2>&1; then
		page="$(curl -fsSL "$OPENWRT_RELEASES_URL")" || {
			err "failed to fetch OpenWrt releases index"
			return 1
		}
	else
		page="$(wget -q -O - "$OPENWRT_RELEASES_URL")" || {
			err "failed to fetch OpenWrt releases index"
			return 1
		}
	fi

	while IFS= read -r line; do
		if [[ -n "${line}" && -z "${seen[${line}]:-}" ]]; then
			seen["${line}"]=1
			found_lines+=("${line}")
		fi
	done < <(
		printf '%s\n' "$page" |
			sed -n 's/.*href="\([0-9]\+\.[0-9]\+[0-9]*\(\.[0-9]\+\)\?\)\/".*/\1/p' |
			sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' |
			sort -V
	)

	if [[ ${#found_lines[@]} -eq 0 ]]; then
		err "no OpenWrt stable release lines found"
		return 1
	fi

	printf '%s\n' "${found_lines[@]}"
}

discover_openwrt_versions() {
	local from_line="${OPENWRT_FROM:-23.05}"
	local to_line="$OPENWRT_TO"
	local -a all_lines=()
	local -a selected=()
	local lines_text
	local latest_line
	local from_i to_i curr_i
	local line

	if ! lines_text="$(discover_openwrt_release_lines)"; then
		return 1
	fi
	mapfile -t all_lines <<<"$lines_text"

	latest_line="${all_lines[-1]}"
	if [[ -z "$to_line" || "$to_line" == "latest" ]]; then
		to_line="$latest_line"
	fi

	from_i="$(version_line_to_int "$from_line")"
	to_i="$(version_line_to_int "$to_line")"
	if [[ "$from_i" -gt "$to_i" ]]; then
		err "invalid OpenWrt range: ${from_line} > ${to_line}"
		return 1
	fi

	for line in "${all_lines[@]}"; do
		curr_i="$(version_line_to_int "$line")"
		if [[ "$curr_i" -ge "$from_i" && "$curr_i" -le "$to_i" ]]; then
			selected+=("$line")
		fi
	done

	if [[ ${#selected[@]} -eq 0 ]]; then
		err "no OpenWrt release lines found in specified range"
		return 1
	fi

	printf '%s\n' "${selected[@]}"
}

detect_openwrt_kernel_version() {
	local openwrt_root="$1"
	local kv_file="${openwrt_root}/include/kernel-version.mk"
	local kernel_version

	if [[ -f "$kv_file" ]]; then
		kernel_version="$(sed -n 's/^KERNEL_PATCHVER[[:space:]]*[:?+]*=[[:space:]]*\([0-9]\+\.[0-9]\+\).*/\1/p' "$kv_file" | head -n 1)"
		if [[ -n "$kernel_version" ]]; then
			printf '%s\n' "$kernel_version"
			return 0
		fi
	fi

	# Fallback 1: infer from include/kernel-<major>.<minor> (pre-25.12 layout)
	kernel_version="$(find "${openwrt_root}/include" -maxdepth 1 -type f -name 'kernel-[0-9]*.[0-9]*' -printf '%f\n' 2>/dev/null | sed -n 's/^kernel-\([0-9]\+\.[0-9]\+\)$/\1/p' | sort -V | tail -n 1)"
	if [[ -n "$kernel_version" ]]; then
		printf '%s\n' "$kernel_version"
		return 0
	fi

	# Fallback 2: infer from target/linux/generic/kernel-<major>.<minor> (25.12+ layout)
	kernel_version="$(find "${openwrt_root}/target/linux/generic" -maxdepth 1 -type f -name 'kernel-[0-9]*.[0-9]*' -printf '%f\n' 2>/dev/null | sed -n 's/^kernel-\([0-9]\+\.[0-9]\+\)$/\1/p' | sort -V | tail -n 1)"
	if [[ -n "$kernel_version" ]]; then
		printf '%s\n' "$kernel_version"
		return 0
	fi

	return 1
}

run_matrix_generator() {
	local linux_root="$1"
	local out_csv="$2"
	local transpose="$3"
	local include_openwrt="${4:-0}"
	local openwrt_root="${5:-}"
	local openwrt_version="${6:-}"
	local -a cmd=(
		python3 "$MATRIX_GENERATOR"
		--linux-root "$linux_root"
		--out "$out_csv"
		--column-mode relative
	)

	if [[ "$transpose" -eq 1 ]]; then
		cmd+=(--transpose)
	fi
	if [[ "$include_openwrt" -eq 1 ]]; then
		cmd+=(--include-openwrt --openwrt-root "$openwrt_root")
		if [[ -n "$openwrt_version" ]]; then
			cmd+=(--openwrt-version "$openwrt_version")
		fi
	fi

	"${cmd[@]}"
}

run_chip_generator() {
	local linux_root="$1"
	local input_csv="$2"
	local out_csv="$3"
	local openwrt_root="${4:-}"
	local openwrt_version="${5:-}"
	local -a cmd=(
		python3 "$CHIP_GENERATOR"
		--input-csv "$input_csv"
		--linux-root "$linux_root"
		--out "$out_csv"
		--chip-delimiter "$CHIP_DELIMITER"
	)

	if [[ -n "$openwrt_root" ]]; then
		cmd+=(--openwrt-root "$openwrt_root")
	fi
	if [[ -n "$openwrt_version" ]]; then
		cmd+=(--openwrt-version "$openwrt_version")
	fi
	if [[ "$WARN_UNRESOLVED_CHIPS" -eq 1 ]]; then
		cmd+=(--warn-unresolved)
	fi

	"${cmd[@]}"
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

process_openwrt_release_line() {
	local release_line="$1"
	local branch="${2:-openwrt-${release_line}}"
	local label="${3:-${release_line}}"
	local openwrt_version_meta="${4:-${release_line}}"
	local openwrt_archive_name openwrt_archive_url openwrt_archive_path
	local openwrt_work_dir openwrt_root
	local linux_version linux_archive_ext linux_archive_name linux_archive_url linux_archive_path
	local linux_work_dir linux_root
	local matrix_csv chip_csv chip_input_csv temp_transposed_csv

	openwrt_archive_name="openwrt-${label}.tar.gz"
	openwrt_archive_url="https://github.com/openwrt/openwrt/archive/refs/heads/${branch}.tar.gz"
	openwrt_archive_path="${CACHE_DIR}/${openwrt_archive_name}"

	if [[ ! -f "$openwrt_archive_path" ]]; then
		log "Downloading ${openwrt_archive_url}"
		if ! download_archive "$openwrt_archive_url" "$openwrt_archive_path"; then
			err "download failed for OpenWrt ${label}"
			return 1
		fi
	else
		log "Reusing cached archive ${openwrt_archive_name}"
	fi

	openwrt_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-dsa-${release_line}.XXXXXX")"
	if ! tar -xf "$openwrt_archive_path" -C "$openwrt_work_dir"; then
		err "failed to extract ${openwrt_archive_name}"
		rm -rf "$openwrt_work_dir"
		return 1
	fi

	openwrt_root="$(find "$openwrt_work_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
	if [[ -z "$openwrt_root" ]]; then
		err "could not find extracted OpenWrt root for ${label}"
		rm -rf "$openwrt_work_dir"
		return 1
	fi

	linux_version="$(detect_openwrt_kernel_version "$openwrt_root")" || {
		err "could not detect kernel version for OpenWrt ${label}"
		rm -rf "$openwrt_work_dir"
		return 1
	}

	linux_archive_ext="$(choose_archive_format "$linux_version")" || {
		err "could not find Linux archive for detected kernel version ${linux_version} (OpenWrt ${label})"
		rm -rf "$openwrt_work_dir"
		return 1
	}

	linux_archive_name="linux-${linux_version}.tar.${linux_archive_ext}"
	linux_archive_url="https://cdn.kernel.org/pub/linux/kernel/v${linux_version%%.*}.x/${linux_archive_name}"
	linux_archive_path="${CACHE_DIR}/${linux_archive_name}"

	if [[ ! -f "$linux_archive_path" ]]; then
		log "Downloading ${linux_archive_url}"
		if ! download_archive "$linux_archive_url" "$linux_archive_path"; then
			err "download failed for Linux ${linux_version}"
			rm -rf "$openwrt_work_dir"
			return 1
		fi
	else
		log "Reusing cached archive ${linux_archive_name}"
	fi

	linux_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-dsa-${linux_version}.XXXXXX")"
	if ! tar -xf "$linux_archive_path" -C "$linux_work_dir"; then
		err "failed to extract ${linux_archive_name}"
		rm -rf "$openwrt_work_dir" "$linux_work_dir"
		return 1
	fi

	linux_root="$(find_extracted_root "$linux_work_dir" "$linux_version")" || {
		err "could not find extracted Linux root for ${linux_version} (OpenWrt ${label})"
		rm -rf "$openwrt_work_dir" "$linux_work_dir"
		return 1
	}

	matrix_csv="${OUTPUT_DIR}/dsa_feature_matrix_openwrt_${label}.csv"
	chip_csv="${OUTPUT_DIR}/dsa_driver_chip_list_openwrt_${label}.csv"
	log "Generating ${matrix_csv} (OpenWrt ${label} + Linux ${linux_version})"

	if ! run_matrix_generator "$linux_root" "$matrix_csv" "$TRANSPOSE" 1 "$openwrt_root" "$openwrt_version_meta"; then
		err "feature matrix generation failed for OpenWrt ${label}"
		rm -rf "$openwrt_work_dir" "$linux_work_dir"
		return 1
	fi

	chip_input_csv="$matrix_csv"
	if [[ "$TRANSPOSE" -ne 1 ]]; then
		temp_transposed_csv="${linux_work_dir}/dsa_feature_matrix_openwrt_${label}_transpose.csv"
		log "Generating temporary transposed matrix for chip extraction"
		if ! run_matrix_generator "$linux_root" "$temp_transposed_csv" 1 1 "$openwrt_root" "$openwrt_version_meta"; then
			err "temporary transposed matrix generation failed for OpenWrt ${label}"
			rm -rf "$openwrt_work_dir" "$linux_work_dir"
			return 1
		fi
		chip_input_csv="$temp_transposed_csv"
	fi

	log "Generating ${chip_csv}"
	if ! run_chip_generator "$linux_root" "$chip_input_csv" "$chip_csv" "$openwrt_root" "$openwrt_version_meta"; then
		err "chip-list generation failed for OpenWrt ${label}"
		rm -rf "$openwrt_work_dir" "$linux_work_dir"
		return 1
	fi

	rm -rf "$openwrt_work_dir" "$linux_work_dir"

	if [[ "$KEEP_ARCHIVES" -eq 0 ]]; then
		rm -f "$openwrt_archive_path"
		rm -f "$linux_archive_path"
	fi

	return 0
}

main() {
	local versions_text
	local -a versions=()
	local -a openwrt_lines=()
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
			--openwrt-releases)
				OPENWRT_RELEASES=1
				shift
				;;
			--openwrt-snapshot)
				OPENWRT_SNAPSHOT=1
				shift
				;;
			--openwrt-from)
				OPENWRT_FROM="$2"
				shift 2
				;;
			--openwrt-to)
				OPENWRT_TO="$2"
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
	if [[ "$OPENWRT_RELEASES" -eq 1 ]]; then
		if [[ -n "$SINGLE_VERSION" || -n "$FROM_VERSION" || -n "$TO_VERSION" ]]; then
			err "--openwrt-releases cannot be combined with Linux --version/--from/--to options"
			exit 1
		fi
		if [[ "$OPENWRT_SNAPSHOT" -eq 1 ]]; then
			err "--openwrt-releases cannot be combined with --openwrt-snapshot"
			exit 1
		fi
		if [[ -n "$OPENWRT_TO" && "$OPENWRT_TO" != "latest" && ! "$OPENWRT_TO" =~ ^[0-9]+\.[0-9]+$ ]]; then
			err "--openwrt-to must be X.Y or 'latest'"
			exit 1
		fi
		if [[ -n "$OPENWRT_FROM" && ! "$OPENWRT_FROM" =~ ^[0-9]+\.[0-9]+$ ]]; then
			err "--openwrt-from must be X.Y"
			exit 1
		fi
	fi
	if [[ "$OPENWRT_SNAPSHOT" -eq 1 ]]; then
		if [[ -n "$SINGLE_VERSION" || -n "$FROM_VERSION" || -n "$TO_VERSION" ]]; then
			err "--openwrt-snapshot cannot be combined with Linux --version/--from/--to options"
			exit 1
		fi
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

	if [[ "$OPENWRT_RELEASES" -eq 1 ]]; then
		if ! versions_text="$(discover_openwrt_versions)"; then
			exit 1
		fi
		mapfile -t openwrt_lines <<<"$versions_text"
		log "Discovered OpenWrt release lines: ${openwrt_lines[*]}"

		for version in "${openwrt_lines[@]}"; do
			if process_openwrt_release_line "$version"; then
				ok_versions+=("$version")
			else
				failed_versions+=("$version")
				if [[ "$STOP_ON_ERROR" -eq 1 ]]; then
					break
				fi
			fi
		done
	elif [[ "$OPENWRT_SNAPSHOT" -eq 1 ]]; then
		log "Processing OpenWrt snapshot (branch: ${OPENWRT_SNAPSHOT_BRANCH})"
		if process_openwrt_release_line "$OPENWRT_SNAPSHOT_LABEL" "$OPENWRT_SNAPSHOT_BRANCH" "$OPENWRT_SNAPSHOT_LABEL" "snapshot-$(date -u +%F)"; then
			ok_versions+=("$OPENWRT_SNAPSHOT_LABEL")
		else
			failed_versions+=("$OPENWRT_SNAPSHOT_LABEL")
		fi
	else
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
	fi

	log "Completed: ${#ok_versions[@]} success, ${#failed_versions[@]} failed"
	for version in "${ok_versions[@]}"; do
		if [[ "$OPENWRT_RELEASES" -eq 1 ]]; then
			printf '  OK     %s -> %s/dsa_feature_matrix_openwrt_%s.csv\n' \
				"$version" "$OUTPUT_DIR" "$version"
			printf '         %s/dsa_driver_chip_list_openwrt_%s.csv\n' \
				"$OUTPUT_DIR" "$version"
		elif [[ "$OPENWRT_SNAPSHOT" -eq 1 ]]; then
			printf '  OK     %s -> %s/dsa_feature_matrix_openwrt_%s.csv\n' \
				"$version" "$OUTPUT_DIR" "$version"
			printf '         %s/dsa_driver_chip_list_openwrt_%s.csv\n' \
				"$OUTPUT_DIR" "$version"
		else
			printf '  OK     %s -> %s/dsa_feature_matrix_linux_%s.csv\n' \
				"$version" "$OUTPUT_DIR" "$version"
			printf '         %s/dsa_driver_chip_list_linux_%s.csv\n' \
				"$OUTPUT_DIR" "$version"
		fi
	done
	for version in "${failed_versions[@]}"; do
		printf '  FAILED %s\n' "$version"
	done

	if [[ ${#failed_versions[@]} -gt 0 ]]; then
		exit 1
	fi
}

main "$@"
