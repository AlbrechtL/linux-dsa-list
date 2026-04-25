#!/usr/bin/env python3

import argparse
import json
import re
from pathlib import Path


FEATURE_RE = re.compile(r"^dsa_feature_matrix_(.+)\.csv$")
CHIP_RE = re.compile(r"^dsa_driver_chip_list_(.+)\.csv$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a static manifest for browser dataset discovery.",
    )
    parser.add_argument(
        "--data-dir",
        default="./data",
        help="Directory containing versioned CSV files (default: ./data)",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Output manifest path (default: <data-dir>/datasets.json)",
    )
    return parser.parse_args()


def parse_version_tuple(text: str) -> tuple[int, int] | None:
    match = re.match(r"^(\d+)\.(\d+)$", text)
    if not match:
        return None
    return (int(match.group(1)), int(match.group(2)))


def compare_dataset_key(dataset_id: str) -> tuple[int, int, tuple[int, int] | tuple[str, str]]:
    is_linux = dataset_id.startswith("linux_")
    is_snapshot = dataset_id.endswith("_snapshot") or dataset_id == "snapshot"
    version_text = dataset_id.split("_", 1)[1] if "_" in dataset_id else dataset_id
    version_tuple = parse_version_tuple(version_text)

    category_rank = 0 if is_linux else 1
    snapshot_rank = 0 if is_snapshot else 1
    version_rank: tuple[int, int] | tuple[str, str]
    if version_tuple is not None:
        version_rank = (-version_tuple[0], -version_tuple[1])
    else:
        version_rank = ("", version_text)

    return (category_rank, snapshot_rank, version_rank)


def dataset_label(dataset_id: str) -> str:
    if dataset_id.startswith("linux_"):
        return f"Linux {dataset_id[len('linux_') :]}"
    if dataset_id.startswith("openwrt_"):
        return f"OpenWrt {dataset_id[len('openwrt_') :]}"
    return dataset_id


def build_manifest(data_dir: Path) -> dict[str, list[dict[str, str]]]:
    feature_files: dict[str, str] = {}
    chip_files: dict[str, str] = {}

    for path in sorted(data_dir.iterdir()):
        if not path.is_file():
            continue

        feature_match = FEATURE_RE.match(path.name)
        if feature_match:
            feature_files[feature_match.group(1)] = path.name
            continue

        chip_match = CHIP_RE.match(path.name)
        if chip_match:
            chip_files[chip_match.group(1)] = path.name

    datasets = []
    for dataset_id, feature_name in feature_files.items():
        chip_name = chip_files.get(dataset_id)
        if not chip_name:
            continue

        datasets.append(
            {
                "id": dataset_id,
                "label": dataset_label(dataset_id),
                "feature": feature_name,
                "chip": chip_name,
            }
        )

    datasets.sort(key=lambda item: compare_dataset_key(item["id"]))
    return {"datasets": datasets}


def main() -> int:
    args = parse_args()
    data_dir = Path(args.data_dir).resolve()
    out_path = Path(args.out).resolve() if args.out else data_dir / "datasets.json"

    manifest = build_manifest(data_dir)
    out_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())