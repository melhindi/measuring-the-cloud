# AWS Network Scenarios

Focused AWS scenarios for validating EC2 network placement behavior.

Copy and edit the shared AWS baseline tfvars before running:

```bash
cp network/scenarios/aws/baseline.tfvars.example network/scenarios/aws/baseline.tfvars
```

Current placement mapping:

- `INSTANCE_AFFINITY=none`: no EC2 placement group
- `INSTANCE_AFFINITY=co-located`: EC2 cluster placement group
- `INSTANCE_AFFINITY=different-host`: EC2 spread placement group

Cluster placement is intentionally modeled as single-AZ only.

Cross-region scenarios live in `cross-region/`. They use VPC peering and a
runner in the scenario's client region; the initial examples use US East to US
West.
