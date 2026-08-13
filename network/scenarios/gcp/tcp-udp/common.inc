# The TCP-vs-UDP latency study, GCP arm. See the AWS folder's common.inc for
# why this is a separate folder and why names carry a _ladder suffix.
#
# n2-standard-2 rather than the n2-standard-8 used by gcp/all and
# gcp/cross-region: the study fixes machine size at 2 vCPU across all three
# providers so core count is not a confound, and at 2 vCPU the benchmark gets
# exactly one core (remote_cpu_list yields 1..n-1) with the telemetry sidecar on
# CPU 0. A larger instance would let the measurement process migrate between
# cores, which is a real source of tail-latency jitter at microsecond scale.
PROVIDER=gcp
TOFU_DIR=network/infra/gcp
TFVARS_FILE=network/scenarios/gcp/baseline.tfvars
BENCHMARK_DIR=network/benchmarks/latency-vs-rate
