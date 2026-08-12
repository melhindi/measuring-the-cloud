# Spot on the AWS storage matrix

Any scenario in this tree can be moved to the EC2 spot market by adding one
line:

```bash
USE_SPOT=1
```

It is off by default and only accepted for `PROVIDER=aws`; STACKIT has no spot
market, and the runner rejects `USE_SPOT=1` for any other provider rather than
ignoring it.

## Why storage and not the network study

The saving scales with the instance, and this matrix uses `c6id.metal` and
`c6id.32xlarge`, where it is large in absolute terms. The network pairs are
small instances for a few hours, where the saving is minor and not worth the
risk below.

## What it costs you

Spot capacity comes from spare pools, so it influences which physical host you
land on. Spot and on-demand are the same hardware, but per-instance variance is
large enough here that host draw is not a free variable — which is why every arm
of one comparison should use one purchasing model, and why the model is recorded
per node.

An interruption ends the instance mid-scenario. Repetitions then fail and are
recorded in the failures table, the scenario is reported failed, and the runner
still tears the infrastructure down; you lose that scenario's data, not the run.

## What is recorded

`purchase_model` comes from the instance metadata service (`spot` /
`on-demand`), not from the Terraform input, so it reports what the instance
actually was. `use_spot_requested` records what the scenario asked for. If they
disagree, believe `purchase_model`.

## Never for the runner

`infra/aws-runner` stays on-demand. The runner is what destroys the benchmark
VMs after each scenario; losing it mid-campaign orphans them and they keep
billing, which can cost more than spot saves.
