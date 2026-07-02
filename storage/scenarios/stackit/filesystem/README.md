# STACKIT Filesystem Scenarios

This folder keeps a small explicit compatibility subset for filesystem-backed
storage benchmarks while the broader STACKIT scenario matrix continues to
cover the `raw` path.

The representative scenarios use the largest reliable local-storage shape and
the highest attached block profile already modeled in the repo. Because
`g2a.120d` availability has been unreliable, the representative filesystem
subset uses `g2a.60d`, with `xfs` as the aligned filesystem-backed choice for
PostgreSQL-oriented runs. Filesystem coverage is consolidated into combined
scenarios that benchmark both the instance-local target and the attached block
target on the same VM:

- combined local `raw` plus block `raw`: `g2a.60d` with `storage_premium_perf29`
- combined local `ext4` plus block `ext4`: `g2a.60d` with `storage_premium_perf29`
- combined local `xfs` plus block `xfs`: `g2a.60d` with `storage_premium_perf29`

This folder is intentionally limited to the combined representative scenarios:
one `raw/raw` variant, one `ext4/ext4` variant, and one `xfs/xfs` variant.
