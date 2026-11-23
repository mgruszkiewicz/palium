#!/usr/bin/env python3
"""Summarise Palia's own frame-time telemetry from its log, to compare launch setups.

Palia writes a telemetry snapshot to Saved/Logs/Palia.log about once a minute, with
the average and worst frame, game-thread, render-thread and RHI-thread times since
the previous snapshot. This script reads only those numbers and the renderer lines,
so it can compare e.g. a DirectX 11 session against a DirectX 12 one.

Usage:
    python3 scripts/palia_perf.py                 # every Palia*.log in Palium's prefix
    python3 scripts/palia_perf.py path/to/a.log path/to/b.log
    python3 scripts/palia_perf.py --save dx12     # also keep a labelled copy of Palia.log

Palia overwrites Palia.log on each start, so run this (or --save) after every session
you want to keep.
"""

import argparse
import glob
import os
import re
import shutil
import statistics
import sys

SUPPORT = os.path.expanduser("~/Library/Application Support/com.palium")
# The Wine 11 prefix first; the old GPTK prefix for logs from before the migration.
LOG_GLOBS = [
    os.path.join(SUPPORT, prefix, "drive_c/users/*/AppData/Local/Palia/Saved/Logs/Palia*.log")
    for prefix in ("prefix-w11", "prefix")
]
ARCHIVE_DIR = os.path.join(SUPPORT, "perf-logs")

FIELDS = [
    ("fps", "FPS"),
    ("frame_time_average", "Frame time, avg (ms)"),
    ("game_thread_time_average", "Game thread, avg (ms)"),
    ("render_thread_time_average", "Render thread, avg (ms)"),
    ("rhit_time_average", "RHI thread, avg (ms)"),
    ("frame_time_max", "Worst frame per snapshot (ms)"),
    ("render_thread_time_max", "Worst render thread (ms)"),
    ("rhit_time_max", "Worst RHI thread (ms)"),
]
NUMBER = re.compile(r"\b(" + "|".join(k for k, _ in FIELDS) + r"): (-?[\d.]+)")
MAP = re.compile(r'map_name: "([^"]+)"')
STAMP = re.compile(r"^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):\d+\]")
RHI = re.compile(r"LogRHI: Loading RHI module (\w+)")
ENGINE = re.compile(r"LogInit: Engine Version: (\S+)")
# Only engine/renderer categories: other lines can carry account data or tokens.
ERROR = re.compile(r"(Log(?:D3D1[12]RHI|RHI|Windows|Init|Shaders?|PipelineCache)): (?:Error|Fatal): (.{0,200})")
HITCH_MS = (100, 250)


def parse(path):
    snaps, errors = [], []
    rhi = engine = first = last = None
    with open(path, errors="ignore") as f:
        for line in f:
            m = STAMP.match(line)
            if m:
                stamp = "{}-{}-{} {}:{}:{}".format(*m.groups())
                first = first or stamp
                last = stamp
            if "frame_time_average" in line:
                values = {k: float(v) for k, v in NUMBER.findall(line)}
                mm = MAP.search(line)
                values["map"] = mm.group(1) if mm else "?"
                snaps.append(values)
                continue
            if rhi is None and (m := RHI.search(line)):
                rhi = m.group(1)
            elif engine is None and (m := ENGINE.search(line)):
                engine = m.group(1)
            elif m := ERROR.search(line):
                errors.append(f"{m.group(1)}: {m.group(2).strip()}")
    return dict(snaps=snaps, rhi=rhi, engine=engine, first=first, last=last, errors=errors)


def percentile(values, q):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * q))]


def report(path, data, by_map):
    snaps = data["snaps"]
    print(f"\n== {path}")
    print(f"   Renderer: {data['rhi'] or 'unknown'}   Engine: {data['engine'] or '?'}"
          f"   Session: {data['first'] or '?'} → {data['last'] or '?'}")
    if not snaps:
        print("   No telemetry snapshots: the game did not reach gameplay.")
        for e in data["errors"][-15:]:
            print(f"   ! {e}")
        return
    print(f"   {len(snaps)} snapshots (about one per minute of play)\n")
    print(f"   {'':34s}{'median':>9s}{'p90':>9s}{'worst':>9s}")
    for key, label in FIELDS:
        v = [s[key] for s in snaps if key in s]
        if v:
            print(f"   {label:34s}{statistics.median(v):9.1f}{percentile(v, 0.9):9.1f}{max(v):9.1f}")
    worst = [s["frame_time_max"] for s in snaps if "frame_time_max" in s]
    if worst:
        for ms in HITCH_MS:
            share = sum(w > ms for w in worst) / len(worst)
            print(f"   Snapshots with a frame over {ms} ms: {share:.0%}")
    if by_map:
        print()
        maps = {}
        for s in snaps:
            maps.setdefault(s["map"], []).append(s)
        for name, group in sorted(maps.items(), key=lambda kv: -len(kv[1])):
            ft = [s["frame_time_average"] for s in group if "frame_time_average" in s]
            wf = [s["frame_time_max"] for s in group if "frame_time_max" in s]
            print(f"   {name:30s} {len(group):4d} snaps   avg frame {statistics.median(ft):6.1f} ms"
                  f"   worst-frame median {statistics.median(wf):7.1f} ms")
    if data["errors"]:
        print(f"\n   {len(data['errors'])} renderer/engine errors, last ones:")
        for e in data["errors"][-5:]:
            print(f"   ! {e}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("logs", nargs="*", help="log files (default: Palium's Palia logs and saved copies)")
    parser.add_argument("--save", metavar="LABEL", help=f"copy the current Palia.log to {ARCHIVE_DIR}/LABEL-<time>.log first")
    parser.add_argument("--by-map", action="store_true", help="also break the numbers down per map")
    args = parser.parse_args()

    if args.save:
        current = [p for g in LOG_GLOBS for p in glob.glob(g) if os.path.basename(p) == "Palia.log"]
        if not current:
            sys.exit("No Palia.log found in Palium's prefix.")
        data = parse(current[0])
        os.makedirs(ARCHIVE_DIR, exist_ok=True)
        stamp = (data["first"] or "unknown").replace(" ", "_").replace(":", "-")
        dest = os.path.join(ARCHIVE_DIR, f"{args.save}-{stamp}.log")
        shutil.copy2(current[0], dest)
        print(f"Saved {dest}")

    found = [p for g in LOG_GLOBS for p in sorted(glob.glob(g))]
    paths = args.logs or found + sorted(glob.glob(os.path.join(ARCHIVE_DIR, "*.log")))
    if not paths:
        sys.exit("No Palia logs found. Pass a path to Palia.log.")
    for path in paths:
        report(path, parse(path), args.by_map)


if __name__ == "__main__":
    main()
