# Storage Benchmarks

The storage runner provisions one benchmark VM per scenario, discovers the
available storage targets on that VM, reconciles them to the scenario config,
runs `fio` benchmark files on the
discovered targets, fetches the raw artifacts, and then destroys the
infrastructure according to the selected destroy policy.

The supported cloud paths are STACKIT and AWS. Both providers can use a shared
persistent runner foundation in `infra/stackit-runner/` or `infra/aws-runner/`;
when that runner is used, the storage VM is controlled over private IPs only.

## Quick Start

Copy and edit the shared baseline tfvars:

```bash
cp storage/scenarios/stackit/baseline.tfvars.example \
  storage/scenarios/stackit/baseline.tfvars
```

For AWS, copy and edit the AWS baseline tfvars:

```bash
cp storage/scenarios/aws/baseline.tfvars.example \
  storage/scenarios/aws/baseline.tfvars
```

Run one scenario locally:

```bash
./storage/runner.sh \
  --scenario storage/scenarios/stackit/all/stackit_g2a.30d_storage_premium_perf6_standard.sh \
  --destroy always
```

Run AWS EBS or instance-store scenarios locally:

```bash
./storage/runner.sh \
  --scenario storage/scenarios/aws/block-storage/aws_c6id.large_ebs-gp3_standard.sh \
  --benchmark fio-randread-4k-q32 \
  --destroy always

./storage/runner.sh \
  --scenario storage/scenarios/aws/local-storage/aws_c6id.large_local_standard.sh \
  --benchmark fio-randread-4k-q32 \
  --destroy always
```

Run it through the shared runner.

Stackit example:

```bash
./scripts/provision_runner.sh \
  --runner-provider stackit \
  --service-account-json /path/to/stackit-service-account.json \
  --workload storage \
  --scenario-dir storage/scenarios/stackit/all
```

AWS example:

```bash
./scripts/provision_runner.sh \
  --runner-provider aws \
  --workload storage \
  --scenario-dir storage/scenarios/aws/all
```

Scenario folders under `storage/scenarios/` are organized provider-first, then
by intent. Some folders run broad matrices, while others contain focused
subsets such as block-only or local-only storage. See each folder's README for
the current scope of that folder.

The default benchmark suite is:

```text
storage/benchmarks/full/
```

It covers:
- `psync` latency tests at 4 KiB for `randread`, `randwrite`, `seqread`, and `seqwrite`
- `io_uring` throughput-oriented tests at 4 KiB and 128 KiB for the same four access patterns

All files use the same raw-artifact contract and repetitions/cooldown defaults.

On `g2a.30d`, the setup script discovers both the instance-local disk and the
attached block volume, skips the root volume, and benchmarks the discovered
non-root targets. The current detection prefers udev metadata first:
the local disk is identified by the `ephemeral0` filesystem label and the
attached block volume by its device identity/serial, with size used only as a
fallback if metadata is incomplete.

On AWS, attached EBS volumes are discovered by EBS volume id through NVMe
by-id links. Instance-store NVMe disks are discovered by the AWS instance-store
device model and exposed as the `local` target. In dedicated AWS runner mode,
the runner injects the shared VPC and security-group IDs into the generated
baseline tfvars so the benchmark VM stays private to the runner network.
To run more experiments on the same persistent runner, call
`provision_runner.sh` again with the next storage or network scenario instead
of destroying the runner foundation between runs.

## Scenario Contract

Storage scenarios are shell files and may define:

```bash
SCENARIO_NAME=stackit_g2a.30d_storage_premium_perf6_standard
PROVIDER=stackit
TOFU_DIR=storage/infra/stackit
TFVARS_FILE=storage/scenarios/stackit/baseline.tfvars
BENCHMARK_DIR=storage/benchmarks/full
OS_TUNING=standard
BENCHMARK_MACHINE_TYPE=g2a.30d
BENCHMARK_IMAGE_ID=7b10e105-295b-4369-b6e0-567ec940a02b
BLOCK_VOLUME_SIZE_GIB=300
BLOCK_VOLUME_PERFORMANCE_CLASS=storage_premium_perf6
LOCAL_FILESYSTEM=raw
BLOCK_FILESYSTEM=raw
SKIP=0
```

`SKIP=1` skips a whole scenario during discovery and dry-run reporting.
`BLOCK_VOLUME_SIZE_GIB=0` disables the additional benchmark block volume; the
root volume is still provisioned as the VM boot disk.

`LOCAL_FILESYSTEM` and `BLOCK_FILESYSTEM` make the target configuration part of
the scenario contract. Supported values are `ext4`, `xfs`, and `raw`. `raw`
means direct device benchmarking with no filesystem or mountpoint. The current
scenario matrix defaults to `raw`; explicit filesystem-backed representative
scenarios live under each provider's `filesystem/` folder.

Approximate block-storage pairings used by the AWS scenario matrix:

```text
STACKIT storage_premium_perf6   AWS gp3  3000 IOPS /  125 MiB/s
STACKIT storage_premium_perf12  AWS gp3  6000 IOPS /  250 MiB/s
STACKIT storage_premium_perf21  AWS gp3 10000 IOPS /  500 MiB/s
STACKIT storage_premium_perf29  AWS gp3 16000 IOPS / 1000 MiB/s
```

In the storage analysis and reports, this shared comparison axis is still
called `Performance Class`. For AWS, the displayed value is derived from the
scenario's declared EBS inputs, for example `gp3 (3000 IOPS | 125 MiB/s)`.
For STACKIT, the displayed value keeps the native class name and appends the
documented class characteristics, for example
`storage_premium_perf12 (6000 IOPS | 250 MiB/s)`.

Approximate instance pairings:

```text
STACKIT g2a.8d    AWS c6id.2xlarge
STACKIT g2a.30d   AWS c6id.8xlarge
STACKIT g2a.120d  AWS c6id.32xlarge
```

## Benchmark Contract

Benchmark files are shell files under `storage/benchmarks/` and define `fio`
parameters. Required variables:

```bash
BENCHMARK_NAME=fio-randread-4k-psync
BENCHMARK_TOOL=fio
SKIP=0
```

Typical `fio` settings for the 4 KiB `io_uring` throughput tests:

```bash
FIO_IOENGINE=io_uring
FIO_RW=randread
FIO_BS=4k
FIO_IODEPTH=32
FIO_NUMJOBS=1
FIO_RUNTIME_SEC=60
FIO_DIRECT=1
FIO_GROUP_REPORTING=1
FIO_TIME_BASED=1
FIO_SIZE=1G
FIO_FSYNC=0
FIO_FDATASYNC=0
REPETITIONS=3
COOLDOWN_SEC=5
```

For the `psync` latency profiles, use the same shape with
`FIO_IOENGINE=psync` and `FIO_IODEPTH=1`.

`FIO_FSYNC` and `FIO_FDATASYNC` are optional integer fio parameters. A value of
`0` leaves sync disabled. A value of `N` means fio calls the corresponding sync
operation after every `N` write operations. Only one of these knobs should be
non-zero in the same benchmark file.

The runner automatically wraps the command with `taskset`, uses all CPUs
except CPU 0 when possible, and skips the root volume. Storage targets are
discovered from the benchmark VM and written to a small env file on the host.
Before each scenario run, the runner reconciles each target to the requested
configuration, including transitions between mounted filesystems and `raw`.
The selected target configuration is copied into `storage.env`, `scenario.env`,
and each benchmark's `benchmark.env`.
