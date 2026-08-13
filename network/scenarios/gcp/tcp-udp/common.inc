# The TCP-vs-UDP latency study, GCP arm. See the AWS folder's common.inc for
# why this is a separate folder and why names carry a _ladder suffix.
#
# US regions rather than the europe-west3 used by every other GCP scenario, and
# set per scenario via CLIENT_REGION rather than in baseline.tfvars so those
# scenarios are unaffected. us-east4 is Ashburn and us-west1 is The Dalles --
# the same two metros as AWS us-east-1 and us-west-2 -- so the two providers'
# cross-region arms cover the same distance. Comparing a Frankfurt-to-Iowa leg
# against a Virginia-to-Oregon one would measure geography and call it provider.
#
# The whole GCP arm moved, not just the cross-region scenario: leaving intra-
# and inter-zone in Europe would confound placement with datacenter geography
# inside this provider's own placement axis.
#
# STACKIT stays in eu01 and cannot follow, which is acceptable because it has no
# cross-region arm -- and intra-AZ latency is a property of one datacenter, not
# of which continent it stands on.
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
