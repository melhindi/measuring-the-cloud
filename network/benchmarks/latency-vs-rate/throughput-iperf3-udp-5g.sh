#!/usr/bin/env bash
# UDP above the capacity of the smaller instances, to find where it breaks.
#
# The 1 G arm asks "does UDP work when the rate is reasonable". This one asks
# "what happens when it is not", which is the more useful question for anyone
# choosing UDP: a transport with no flow control does not slow down when it
# exceeds capacity, it discards, and where the discard happens decides whether
# more buffer, more CPU, or a smaller send rate is the fix.
#
# 5 Gbit/s brackets the three providers rather than matching any one of them.
# AWS c6id.large should absorb it; GCP n2-standard-2 is capped near 2 Gbit/s per
# vCPU; STACKIT historically received 1-3 Gbit/s regardless of target. So this
# is expected to be under capacity on one provider and over on two, which is the
# point -- the delivered rate is then a measurement of capacity rather than a
# restatement of the target.
#
# Deliberately not the 90 G target used by the older full suite. Over-driving by
# 30x produced 51-59% loss, which mostly measures how fast the generator can
# discard and says little about the path.
#
# Same attribution rule as the 1 G arm: check UdpRcvbufErrors and IpInDiscards
# in the telemetry before calling any of this network loss.
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=iperf3-udp-5g-capacity
BENCHMARK_TOOL=iperf3
SKIP=0

IPERF3_PROTOCOL=udp
IPERF3_PARALLEL=1
IPERF3_UDP_BITRATE=5G
# 1472 B payload, not the runner default of 1492. With 8 B UDP and 20 B IP
# headers that is exactly 1500 -- the largest datagram that crosses a standard
# MTU without fragmenting. 1492 would total 1520 and fragment on any 1500 B
# path, which the cross-region legs are; a lost fragment loses the whole
# datagram, so the cross-region loss figure would partly measure fragmentation
# rather than capacity. Intra-AZ paths here are jumbo (8750-9001) and would not
# fragment either way, so pinning it is what makes the placements comparable.
IPERF3_UDP_LENGTH=1472
IPERF3_RUNTIME_SEC=15
IPERF3_OMIT_SEC=3
