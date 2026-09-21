"""Figure 1 and 2: Infinity v5 vs scx_flow 4.2.46, CachyOS benchmarker data.

Reads the two raw CSVs in benchmarks/raw and draws grouped horizontal
bars in the benchmarker aesthetic with academic titles and footnotes.
Layout is defensive against cropping: wide figure, constrained layout,
headroom on the value axis, labels outside bars with clipping off.
"""
import csv
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")
CHARTS = os.path.join(HERE, "charts")

INF_CSV = os.path.join(RAW, "infinity-7.2.6-2026-09-21.csv")
SCX_CSV = os.path.join(RAW, "scxflow-4.2.46-7.3.0-rc2-2026-09-17.csv")

INF_COLOR = "#4682b4"
SCX_COLOR = "#e8912d"
LAT_COLOR = "#d9534f"
RPS_COLOR = "#5cb85c"

THROUGHPUT_TESTS = [
    "stress-ng cpu-cache-mem",
    "perf sched msg fork thread",
    "perf memcpy",
    "calculating prime numbers",
    "namd 92K atoms",
    "argon2 hashing",
    "ffmpeg compilation",
    "xz compression",
    "kernel defconfig",
    "blender render",
    "x265 encoding",
    "y-cruncher pi 1b",
]


def load_row(path):
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    assert len(rows) == 1, f"expected one data row in {path}"
    return rows[0]


def grouped(ax, labels, a_vals, b_vals, a_name, b_name, xlabel,
            a_color, b_color, fmt="{:.2f}", height=0.36):
    import numpy as np

    y = np.arange(len(labels))
    # a below b so that invert_yaxis puts Infinity on top.
    b1 = ax.barh(y - height / 2, a_vals, height=height, label=a_name,
                 color=a_color, edgecolor="0.35", linewidth=0.6)
    b2 = ax.barh(y + height / 2, b_vals, height=height, label=b_name,
                 color=b_color, edgecolor="0.35", linewidth=0.6)
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=10)
    # Units live in the title, so no axis label competes with the footnote.
    ax.invert_yaxis()
    ax.grid(axis="x", linestyle="--", alpha=0.4)
    for bars, vals in ((b1, a_vals), (b2, b_vals)):
        for bar, v in zip(bars, vals):
            ax.text(bar.get_width() * 1.005, bar.get_y() + bar.get_height() / 2,
                    fmt.format(v), va="center", ha="left", fontsize=9,
                    clip_on=False)
    xmax = max(max(a_vals), max(b_vals)) * 1.22
    ax.set_xlim(0, xmax)
    ax.legend(fontsize=10, loc="lower right")
    return xmax


def footnote(ax, text):
    # Footnotes ride as the axis label, which matplotlib always places
    # below the tick labels, so text can never collide or crop.
    ax.set_xlabel(text, fontsize=8.5, color="0.30")


def main():
    os.makedirs(CHARTS, exist_ok=True)
    inf = load_row(INF_CSV)
    scx = load_row(SCX_CSV)
    a = [float(inf[t]) for t in THROUGHPUT_TESTS]
    b = [float(scx[t]) for t in THROUGHPUT_TESTS]

    fig1 = plt.figure(figsize=(16, 9.5), constrained_layout=True)
    gs1 = fig1.add_gridspec(1, 1, bottom=0.09)
    ax1 = fig1.add_subplot(gs1[0, 0])
    ax1.set_title("Figure 1. Infinity v5 vs scx_flow 4.2.46: "
                  "throughput and build times (seconds, lower is better)",
                  fontsize=13, fontweight="bold", pad=12)
    grouped(ax1, THROUGHPUT_TESTS, a, b,
            "Infinity v5 (7.2.6-1-cachyos-kpp)",
            "scx_flow 4.2.46 (7.3.0-rc2-3-cachyos-rc)",
            "Time (s), lower is better",
            INF_COLOR, SCX_COLOR)
    footnote(ax1,
             "n=1 per kernel. Infinity run 2026-09-21, scx_flow run 2026-09-17, "
             "same host.\nBase versions differ (7.2.6 vs 7.3.0-rc2), so gaps "
             "under a few percent are noise, not verdicts.")
    fig1.savefig(os.path.join(CHARTS, "fig1_throughput.png"), dpi=110)
    plt.close(fig1)

    lat_labels = ["schbench p99 latency (us)", "schbench p50 latency (us)",
                  "cyclictest max latency (us)", "schbench avg rps"]
    lat_inf = [float(inf["schbench p99 latency (us)"]),
               float(inf["schbench p50 latency (us)"]),
               float(inf["cyclictest max latency (us)"]),
               float(inf["schbench avg rps"])]
    lat_scx = [float(scx["schbench p99 latency (us)"]),
               float(scx["schbench p50 latency (us)"]),
               float(scx["cyclictest max latency (us)"]),
               float(scx["schbench avg rps"])]

    fig2 = plt.figure(figsize=(16, 7.5), constrained_layout=True)
    gs2 = fig2.add_gridspec(2, 1, height_ratios=[3, 1], hspace=0.3,
                            bottom=0.11)
    ax2a = fig2.add_subplot(gs2[0, 0])
    ax2b = fig2.add_subplot(gs2[1, 0])
    fig2.suptitle("Figure 2. Infinity v5 vs scx_flow 4.2.46: wake and timer "
                  "latency under load", fontsize=13, fontweight="bold")
    grouped(ax2a, lat_labels[:3], lat_inf[:3], lat_scx[:3],
            "Infinity v5 (7.2.6-1-cachyos-kpp)",
            "scx_flow 4.2.46 (7.3.0-rc2-3-cachyos-rc)",
            "Latency (us), lower is better",
            LAT_COLOR, SCX_COLOR, fmt="{:.0f}")
    grouped(ax2b, lat_labels[3:], lat_inf[3:], lat_scx[3:],
            "Infinity v5 (7.2.6-1-cachyos-kpp)",
            "scx_flow 4.2.46 (7.3.0-rc2-3-cachyos-rc)",
            "Throughput (rps), higher is better",
            RPS_COLOR, SCX_COLOR, fmt="{:.0f}")
    footnote(ax2b,
             "n=1 per kernel, same runs as Figure 1. schbench p99 is the "
             "interactive-wake number the bounded-LIFO design targets.\n"
             "cyclictest max is a single worst sample, so near-ties there "
             "carry no verdict.")
    fig2.savefig(os.path.join(CHARTS, "fig2_latency.png"), dpi=110)
    plt.close(fig2)
    print("wrote fig1_throughput.png and fig2_latency.png")


if __name__ == "__main__":
    main()
