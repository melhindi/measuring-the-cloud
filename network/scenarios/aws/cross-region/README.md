# AWS Cross-Region Scenarios

These scenarios run a client in the persistent runner's source region and a
server in a peered VPC in the destination region. Both benchmark nodes and
runner control traffic use private IPs; temporary NAT gateways provide package
installation egress.

The shipped smoke pair is `us-east-1a` to `us-west-2a`. Provision the AWS
runner in `us-east-1` before running this directory.
