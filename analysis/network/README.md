# Network Benchmark Analysis

This folder contains the network parsing layer for artifacts under `artifacts/network`.

## Generate CSVs

Generate CSVs for all available network runs:

```bash
Rscript analysis/network/build_csv.R all
```

Generate CSVs for a single run:

```bash
Rscript analysis/network/build_csv.R run-20260523-171439
```

Generate CSVs for selected runs:

```bash
Rscript analysis/network/build_csv.R run-20260523-171439,run-20260523-204710
```

The output is written to `analysis/network/<result-id>/`.

## Output Files

- `network_scenarios.csv`: one row per scenario and run.
- `network_iperf3.csv`: one row per iperf3 repetition.
- `network_iperf3_intervals.csv`: one row per iperf3 interval from the client JSON output.
- `network_sockperf.csv`: one row per sockperf repetition.
- `network_failures.csv`: one row per repetition that produced no usable
  measurement, either because the runner recorded a non-zero exit or because the
  expected output is absent. The measurement tables only ever contain rows that
  parsed, so without this a run that lost repetitions is indistinguishable from a
  complete one with fewer rows.

### Scenario classification

`placement_class` is derived, and distinguishes `cross-region` from `multi-az`
using `PLACEMENT_MODE` and `SERVER_REGION`. Comparing AZ strings alone put every
cross-region run in the `multi-az` bucket. `pair_class` records whether the
client and server machine types were the same, so a mixed-type pair is not
pooled with the same-type pair of its client type.

Provenance (`kernel_release`, `image_id`, `primary_iface_mtu`, tool versions) is
collected into `node-facts.env` on each node and is NA for runs recorded before
that file existed.

## Validate CSVs

```bash
Rscript analysis/network/validate_csv.R all
```

For `all`, validation compares CSV row counts against the raw artifact files and
runs DuckDB sanity checks for protocol-specific fields and key aggregations.

## Render The Report

```bash
Rscript analysis/network/render_network_benchmark_analysis.R all
```

The renderer accepts an optional JSON file with report constants, mirroring the
storage report:

```bash
Rscript analysis/network/render_network_benchmark_analysis.R all \
  --config analysis/network/network_report_config.example.json
```

Defaults are documented in `analysis/network/network_report_config.example.json`.

The report is written to:

```text
analysis/network/<result-id>/network_benchmark_analysis_<result-id>.html
```

The renderer regenerates CSVs before rendering. If no result id is passed, it
renders `all`.
