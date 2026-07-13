SCENARIO_NAME=gcp-baseline
PROVIDER=gcp
TOFU_DIR=network/infra/gcp
TFVARS_FILE=network/scenarios/gcp/baseline.tfvars
BENCHMARK_DIR=network/benchmarks/baseline
OS_TUNING=standard
INSTANCE_AFFINITY=different-host
 
# Metadata only for now. Concrete placement is controlled through the tfvars file.
PLACEMENT_MODE=single-az
 