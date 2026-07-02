# Storage All Scenarios

This folder contains the broad storage scenario set used for full report runs.
It combines instance types and block volume performance classes into explicit
scenario files. The scenarios in this folder now default to direct-device
benchmarking with `raw` target config unless they explicitly override it.

Use this folder when you want the full storage benchmark matrix:

```bash
./scripts/provision_runner.sh \
  --service-account-json /path/to/stackit-service-account.json \
  --workload storage \
  --scenario-dir storage/scenarios/stackit/all
```

The files may overlap with focused subset folders. That duplication is
intentional: this folder is the stable "run everything" entry point.

It also includes the representative combined local-plus-block filesystem
comparison scenarios from `../filesystem/`:

- combined local `raw` plus block `raw` on the same VM using `g2a.60d`
- combined local `ext4` plus block `ext4` on the same VM using `g2a.60d`
- combined local `xfs` plus block `xfs` on the same VM using `g2a.60d`

No standalone `local_xfs` or block-only `*_xfs` compatibility leftovers are
kept here; the filesystem subset contributes only those three combined
representative scenarios.
