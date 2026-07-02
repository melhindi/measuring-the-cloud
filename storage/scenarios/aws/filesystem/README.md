# AWS Filesystem Scenarios

This folder keeps a small explicit compatibility subset for filesystem-backed
storage benchmarks while the broader AWS scenario matrix continues to cover the
`raw` path.

The representative scenarios use the largest local-storage shape and the
highest gp3 profile already modeled in the repo, named explicitly as
`gp3_16000iops_1000mbps`, with `xfs` as the aligned
filesystem-backed choice for PostgreSQL-oriented runs. Filesystem coverage is
consolidated into combined scenarios that benchmark both the local
instance-store target and the attached gp3 target on the same VM:

- combined local `raw` plus block `raw`: `c6id.32xlarge`
- combined local `ext4` plus block `ext4`: `c6id.32xlarge`
- combined local `xfs` plus block `xfs`: `c6id.32xlarge`

The folder also includes a bare-metal combined comparison point:

- combined local `raw` plus block `raw`: `c6id.metal`
- combined local `ext4` plus block `ext4`: `c6id.metal`
- combined local `xfs` plus block `xfs`: `c6id.metal`

This folder is intentionally limited to the combined representative scenarios:
`raw/raw`, `ext4/ext4`, and `xfs/xfs` for `c6id.32xlarge`, plus the same three
variants for `c6id.metal`.
