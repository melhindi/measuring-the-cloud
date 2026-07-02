# AWS Block Storage Scenarios

These scenarios use `c6id.2xlarge` to approximate the existing STACKIT
`g2a.8d` block-storage matrix and vary gp3 IOPS/throughput profiles. Their
filenames use the explicit `gp3_<iops>iops_<throughput>mbps` form, and they now
default to direct-device benchmarking with `BLOCK_FILESYSTEM=raw`.

Like the comparable STACKIT block-storage scenarios, this folder uses the full
benchmark suite from `storage/benchmarks/full`.

The profile names are benchmark pairings, not provider-equivalent guarantees:

```text
gp3_3000iops_125mbps    3000 IOPS /  125 MiB/s
gp3_6000iops_250mbps    6000 IOPS /  250 MiB/s
gp3_10000iops_500mbps  10000 IOPS /  500 MiB/s
gp3_16000iops_1000mbps 16000 IOPS / 1000 MiB/s
```

Use `../filesystem/` when you want explicit filesystem-backed comparison runs.

`aws_c6id.large_ebs-gp3_standard` is kept as a lower-cost AWS-only smoke
scenario and is not part of the direct STACKIT pairing matrix.
