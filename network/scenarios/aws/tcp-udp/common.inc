# The TCP-vs-UDP latency study.
#
# Every scenario in this folder runs network/benchmarks/latency-vs-rate -- the
# same twelve arms (two protocols x six offered rates) -- so the only thing that
# differs between them is where the two instances sit relative to each other.
# That is the study's independent variable; everything else is held fixed.
#
# A separate folder from co-located/, different-host/, multi-az/ and
# cross-region/ because those run the iperf3 throughput suite, which answers a
# different question and would triple the runtime of every scenario here.
#
# Scenario names carry a _ladder suffix for a concrete reason: the cross-region
# coordinates below are identical to those in network/scenarios/aws/cross-region,
# and two scenarios sharing a SCENARIO_NAME write into the same artifact
# directory. preflight_scenarios() rejects that, but only when both are selected
# in one invocation -- across separate runs it would silently attribute one
# benchmark set's measurements to the other configuration.
PROVIDER=aws
TOFU_DIR=network/infra/aws
TFVARS_FILE=network/scenarios/aws/baseline.tfvars
BENCHMARK_DIR=network/benchmarks/latency-vs-rate
