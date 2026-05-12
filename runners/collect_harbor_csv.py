"""Collect Harbor trial results into the unified experiment CSV."""

from __future__ import annotations

import argparse
import csv
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any


HEADER = ["task", "reward", "n_input", "n_output", "n_cache", "elapsed_s"]


def parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def elapsed_seconds(result: dict[str, Any]) -> int:
    started = parse_time(result.get("started_at"))
    finished = parse_time(result.get("finished_at"))
    if started and finished:
        return max(0, int((finished - started).total_seconds()))
    return 0


def normalize_task_name(name: str, suffix_wo: str, suffix_ws: str) -> str:
    name = Path(name).name
    if "__" in name:
        name = name.split("__")[-1]
    name = re.sub(r"__[A-Za-z0-9]+$", "", name)
    for suffix in (suffix_wo, suffix_ws):
        if suffix and name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def load_existing(csv_path: Path) -> set[str]:
    if not csv_path.exists():
        return set()
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        return {row["task"] for row in reader if row.get("task")}


def iter_result_files(harbor_out: Path, job_name: str, mode: str) -> list[Path]:
    if mode == "exact":
        candidates = [harbor_out / job_name]
    elif mode == "indexed":
        candidates = sorted(
            path
            for path in harbor_out.glob(f"{job_name}_[0-9]*")
            if path.is_dir() and re.fullmatch(re.escape(job_name) + r"_[0-9]+", path.name)
        )
    else:
        raise ValueError(f"unknown mode {mode!r}")

    result_files: list[Path] = []
    for job_dir in candidates:
        if not job_dir.is_dir():
            continue
        result_files.extend(sorted(job_dir.glob("*/result.json")))
    return result_files


def row_from_result(path: Path, suffix_wo: str, suffix_ws: str) -> list[Any]:
    data = json.loads(path.read_text())
    config_task = ((data.get("config") or {}).get("task") or {}).get("path")
    raw_task = config_task or data.get("task_name") or path.parent.name
    task = normalize_task_name(str(raw_task), suffix_wo, suffix_ws)
    verifier_result = data.get("verifier_result") or {}
    agent_result = data.get("agent_result") or {}
    reward = (verifier_result.get("rewards") or {}).get("reward", "?")
    return [
        task,
        reward,
        agent_result.get("n_input_tokens", 0) or 0,
        agent_result.get("n_output_tokens", 0) or 0,
        agent_result.get("n_cache_tokens", 0) or 0,
        elapsed_seconds(data),
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--harbor-out", required=True)
    parser.add_argument("--job-name", required=True)
    parser.add_argument("--csv-log", required=True)
    parser.add_argument("--mode", choices=["exact", "indexed"], default="exact")
    parser.add_argument("--append", action="store_true")
    parser.add_argument("--suffix-wo", default="_wo")
    parser.add_argument("--suffix-ws", default="_ws")
    args = parser.parse_args()

    harbor_out = Path(args.harbor_out)
    csv_path = Path(args.csv_log)
    csv_path.parent.mkdir(parents=True, exist_ok=True)

    seen = load_existing(csv_path) if args.append else set()
    rows = []
    for result_file in iter_result_files(harbor_out, args.job_name, args.mode):
        row = row_from_result(result_file, args.suffix_wo, args.suffix_ws)
        if row[0] in seen:
            continue
        rows.append(row)
        seen.add(str(row[0]))

    write_header = not args.append or not csv_path.exists()
    mode = "a" if args.append else "w"
    with csv_path.open(mode, newline="") as f:
        writer = csv.writer(f)
        if write_header:
            writer.writerow(HEADER)
        writer.writerows(rows)

    print(f"wrote {len(rows)} rows to {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
