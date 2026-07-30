# Cloud Measuring

Benchmark framework for comparing cloud network and storage performance.

The current implemented slices are STACKIT and AWS network and storage, plus
GCP network benchmarks.
benchmarks. Both providers support a persistent benchmark runner VM path for
private-IP execution:

- provision a small runner VM plus shared network/security plumbing with
  OpenTofu
- stage only the required repository assets to the runner with `rsync`
- generate a runner-local SSH key for the scenario VMs
- run the benchmark suite on the runner over private IPs
- bootstrap tools through cloud-init
- run all non-skipped benchmark files for the selected scenario(s)
- fetch raw artifacts back from the runner
- destroy infrastructure to control cost

The storage slice uses one benchmark VM per scenario, with `fio` workloads over
discovered local and/or attached block storage targets.

## Quick Start

Copy and edit the runner foundation tfvars for the provider you want to run:

```bash
cp infra/stackit-runner/basic-infra.tfvars.example infra/stackit-runner/basic-infra.tfvars
cp infra/aws-runner/basic-infra.tfvars.example infra/aws-runner/basic-infra.tfvars
```

Then provision a Stackit runner and start a benchmark run for one scenario file:

```bash
./scripts/provision_runner.sh \
  --runner-provider stackit \
  --service-account-json /path/to/stackit-service-account.json \
  --scenario network/scenarios/stackit/baseline.sh
```

Or provision an AWS runner and launch an AWS storage/network matrix:

```bash
./scripts/provision_runner.sh \
  --runner-provider aws \
  --scenario-dir network/scenarios/aws/all
```

The AWS runner example defaults to `us-east-1`. This is also the source region
for the shipped private cross-region smoke scenarios in
`network/scenarios/aws/cross-region/`, which peer to `us-west-2`.

For Stackit scenario folders:

```bash
./scripts/provision_runner.sh \
  --runner-provider stackit \
  --service-account-json /path/to/stackit-service-account.json \
  --scenario-dir network/scenarios/stackit/all
```

The helper prints a fetch command for the completed run. Use it to pull the
results back to your workstation once the run has finished:

```bash
./scripts/fetch_runner_results.sh --workload network \
  --runner-host <runner-public-ip> \
  --ssh-key ~/.ssh/id_ed25519 \
  --run-id run-YYYYMMDD-HHMMSS
```

If you omit `--run-id`, the helper fetches the latest completed run for the
selected workload. `--workload storage` works the same way.

`provision_runner.sh` rejects mixed-provider scenario selections. AWS runner
VMs use the EC2 instance role on the runner host; Stackit runner VMs use the
staged service-account key.
To reuse an existing runner for more experiments, invoke
`provision_runner.sh` again with the new scenario or workload and keep the
runner foundation alive until you are done.

When you are finished with all network and storage experiments on that
persistent runner, destroy the runner foundation with:

```bash
./scripts/destroy_runner.sh --runner-provider stackit
./scripts/destroy_runner.sh --runner-provider aws
```

The direct local runner is available for ad-hoc execution:

```bash
./network/runner.sh --dry-run --scenario network/scenarios/stackit/baseline.sh
./network/runner.sh --scenario network/scenarios/stackit/baseline.sh --destroy always
```

AWS scenarios run through the same local runner path:

```bash
./network/runner.sh --dry-run --scenario network/scenarios/aws/baseline.sh
./storage/runner.sh --dry-run --scenario-dir storage/scenarios/aws/all
```

Artifacts are downloaded to:

```text
artifacts/network/runner-control/<run-id>/
artifacts/network/<run-id>/<scenario-name>/
```

## Scenario Files

Scenario files are sourced shell files. They describe one concrete cloud setup
and point the runner to a benchmark directory. Scenario folders group files by
intent: some folders run broad matrices, while others contain focused subsets.
See the README in each scenario folder for the current intent of that folder.

Typical network scenario variables:

```bash
SCENARIO_NAME=stackit-baseline
PROVIDER=stackit
TOFU_DIR=network/infra/stackit
TFVARS_FILE=network/scenarios/stackit/baseline.tfvars
BENCHMARK_DIR=network/benchmarks/baseline
```

Typical storage scenario variables:

```bash
SCENARIO_NAME=stackit_g2a.30d_storage_premium_perf6_standard
PROVIDER=stackit
TOFU_DIR=storage/infra/stackit
TFVARS_FILE=storage/scenarios/stackit/baseline.tfvars
BENCHMARK_DIR=storage/benchmarks/full
```

The selected scenario file can override cloud dimensions such as instance type,
availability zone, OS tuning, affinity, root volume size, or attached block
volume performance class. Storage scenarios can also set
`LOCAL_FILESYSTEM` and `BLOCK_FILESYSTEM` to make target configuration
explicit; both support `ext4`, `xfs`, and `raw`.

AWS storage scenario filenames use explicit gp3 profile naming, for example
`aws_c6id.2xlarge_storage_gp3_3000iops_125mbps_standard.sh`, while STACKIT
storage scenarios keep the native `storage_premium_perf*` naming.

Set `SKIP=1` to keep a scenario file in the directory without running it.

## OpenTofu Files

Track `.terraform.lock.hcl` files for root modules so provider versions are
stable across machines and CI. Do not track `.terraform/`, `*.tfstate`, or real
`*.tfvars` files; scenario tfvars examples are safe to track.

## Benchmark Files

Benchmark files are sourced shell files under workload-specific benchmark
directories. Required variables:

```bash
BENCHMARK_NAME=iperf3-tcp-1s
BENCHMARK_TOOL=iperf3
SKIP=0
```

Set `SKIP=1` to keep a benchmark file in the directory without running it.

Default runtimes and repetitions:

- `sockperf`: 30s runtime, 5 repetitions
- `iperf3` TCP: 30s runtime, 3 repetitions, default `IPERF3_TCP_LENGTH=128K`
- `iperf3` UDP: 30s runtime, 3 repetitions
- `fio`: benchmark-specific runtime, usually 3 repetitions
