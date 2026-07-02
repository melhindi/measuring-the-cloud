# AWS Full Storage Matrix

This folder contains the broader AWS block-storage matrix. It combines
approximate compute pairings with explicit gp3 profiles:

```text
STACKIT g2a.8d    AWS c6id.2xlarge
STACKIT g2a.30d   AWS c6id.8xlarge
STACKIT g2a.120d  AWS c6id.32xlarge
```

AWS scenario filenames in this folder use the explicit
`gp3_<iops>iops_<throughput>mbps` form instead of the older mirrored `perf*`
shorthand.

Like the comparable STACKIT matrix, these scenarios use the full benchmark
suite from `storage/benchmarks/full`.

This folder also includes the representative combined local-plus-block
filesystem comparison scenarios from `../filesystem/`:

- combined local `raw` plus block `raw` on the same VM
- combined local `ext4` plus block `ext4` on the same VM
- combined local `xfs` plus block `xfs` on the same VM
- bare-metal combined local `raw` plus block `raw` on the same VM
- bare-metal combined local `ext4` plus block `ext4` on the same VM
- bare-metal combined local `xfs` plus block `xfs` on the same VM

No standalone `local_xfs` or block-only `*_xfs` compatibility leftovers are
kept here; the filesystem subset contributes only those six combined
representative scenarios.

Run the full matrix through the dedicated AWS runner with:

```bash
./scripts/provision_runner.sh \
  --runner-provider aws \
  --workload storage \
  --scenario-dir storage/scenarios/aws/all
```
