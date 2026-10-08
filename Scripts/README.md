# Capture and analysis scripts

Run scripts from the repository root. Python image/plot tools require the
packages in `requirements.txt`; install them in a local virtual environment:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r Scripts/requirements.txt
```

Activate that environment before using scripts which launch other Python tools.
Xcode command-line tools are required for Simulator/device capture and profiling.
Build the example first; see each linked report for the exact workload and capture
procedure. Pass device identifiers as local command arguments.

| Tools | Purpose |
| --- | --- |
| `export_comparisons.sh`, `make_contact_sheet.py` | Export Simulator comparison fixtures and build gallery sheets |
| `run_benchmarks.py`, `analyze_benchmarks.py`, `write_benchmark_tables.py` | Run device workloads and summarize the original benchmark sweep |
| `analyze_randomized_benchmarks.py` | Validate and summarize distinct per-view workloads |
| `analyze_optimized_benchmarks.py` | Compare historical batching/allocation measurements |
| `run_geometry_benchmarks.py`, `analyze_geometry_benchmarks.py` | Run and analyze fixed-density geometry experiments |
| `analyze_geometry_images.py` | Compare captured pixels across geometry resolutions |
| `profile_geometry_benchmarks.py`, `analyze_gpu_trace.py` | Capture Instruments Metal traces and summarize exported timings |
| `analyze_adaptive_benchmarks.py` | Validate and summarize current adaptive-renderer trials |
| `inspect_renderbox_geometry.py`, `probe_renderbox_geometry_lldb.py` | Version-specific research utilities for local Apple framework inspection |

The framework inspection utilities are research tools, separate from the shipping
library. They require compatible locally installed Simulator binaries and may
need updating for another SDK. No Apple binaries or extracted shader code are
included in this repository or required by the package.

The [documentation index](../Documentation/README.md) links every report. Some
analysis tools have fixed historical input/output paths; inspect them before
running against a new dataset. Do not overwrite published evidence with a new
trial. Capture experimental output under ignored `DerivedData/` and promote only
reviewed inputs, measurements, and images into the relevant documentation folder.
