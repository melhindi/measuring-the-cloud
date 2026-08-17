# The TCP-vs-UDP latency study, STACKIT arm. See the AWS folder's common.inc for
# why this is a separate folder and why names carry a _ladder suffix.
#
# Two placement points rather than three: the STACKIT module has no server_region
# variable and STACKIT exposes one region here, so the cross-region point of the
# placement axis does not exist for this provider. That is a property of the
# provider, not a gap in the study -- the analysis must compare STACKIT against
# the others on intra-AZ and inter-AZ only, and must not read the absence of a
# cross-region row as a missing measurement.
#
# g2a.2d is 2 vCPU, matching c6id.large and n2-standard-2.
PROVIDER=stackit
TOFU_DIR=network/infra/stackit
TFVARS_FILE=network/scenarios/stackit/baseline.tfvars
BENCHMARK_DIR=network/benchmarks/latency-vs-rate
