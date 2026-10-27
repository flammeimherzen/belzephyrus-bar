#!/usr/bin/env python3
"""Summarize live-app probes; reject visibility mismatches and their settling time."""
import json
import math
import sys
from pathlib import Path


def intervals(report, opened):
    result = []
    for phase in report['phases']:
        name = phase['name']
        if name not in (['open'] if opened else ['closed', 'closed_again']):
            continue  # partial phases and warmup are not final measurements
        readings = phase['readings']
        last_mismatch = 0.0 if name == 'closed_again' else -math.inf
        for left, right in zip(readings, readings[1:]):
            if left['panelVisible'] != opened or right['panelVisible'] != opened:
                last_mismatch = right['elapsed']
                continue
            if left['elapsed'] - last_mismatch < 10:
                continue
            duration = right['elapsed'] - left['elapsed']
            if duration <= 0:
                continue
            result.append({
                'duration': duration,
                'cpu': right['cpuSeconds'] - left['cpuSeconds'],
                'child_cpu': right['childCPUSeconds'] - left['childCPUSeconds'],
                'wakeups': right['interruptWakeups'] - left['interruptWakeups'],
                'footprint_mib': right['footprintBytes'] / 1048576,
            })
    return result


def summarize(rows):
    if not rows:
        return None
    duration = sum(row['duration'] for row in rows)
    rates = sorted(100 * (row['cpu'] + row['child_cpu']) / row['duration'] for row in rows)
    footprints = [row['footprint_mib'] for row in rows]
    return {
        'valid_seconds': round(duration, 2),
        'cpu_percent_one_core': round(100 * sum(row['cpu'] for row in rows) / duration, 3),
        'child_cpu_percent_one_core': round(100 * sum(row['child_cpu'] for row in rows) / duration, 3),
        'total_cpu_percent_one_core': round(100 * sum(row['cpu'] + row['child_cpu'] for row in rows) / duration, 3),
        'p95_5second_cpu_percent': round(rates[math.ceil(.95 * len(rates)) - 1], 3),
        'peak_5second_cpu_percent': round(rates[-1], 3),
        'footprint_mib_min': round(min(footprints), 2),
        'footprint_mib_max': round(max(footprints), 2),
        'footprint_mib_last': round(footprints[-1], 2),
        'interrupt_wakeups_per_second': round(sum(row['wakeups'] for row in rows) / duration, 2),
    }


if __name__ == '__main__':
    report = json.loads(Path(sys.argv[1]).read_text())
    print(json.dumps({
        'executable': report['executable'],
        'slots': report['slots'],
        'method': '100% CPU = one core. Completed phases only. Warmup, visibility mismatches and 10 s after a mismatch/closing are excluded. Child CPU included separately and in total. WindowServer/GPU compositor cost is not attributed.',
        'closed': summarize(intervals(report, False)),
        'open': summarize(intervals(report, True)),
    }, indent=2))
