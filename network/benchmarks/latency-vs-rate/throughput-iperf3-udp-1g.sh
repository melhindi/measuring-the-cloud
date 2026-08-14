#!/usr/bin/env bash
# UDP capacity and loss at a rate every provider here should sustain.
#
# The ladder probes the packet-rate axis: 64 B messages, up to 100k/s, about
# 102 Mbit/s. This probes the byte-rate axis instead -- ~1500 B datagrams at
# 1 Gbit/s, roughly 83k packets/s. Two different ways to run out of capacity,
# and the pair distinguishes them: a provider that sustains 1 Gbit/s here but
# collapses at 25k msg/s on the ladder is packet-rate limited, not bandwidth
# limited.
#
# 1 Gbit/s is deliberately modest. Historical runs in this repository received
# 835-979 Mbit/s against a 1 G target, so this sits near the achievable edge for
# the smaller instances and comfortably inside AWS c6id.large -- which makes any
# loss here interesting rather than an artefact of gross over-driving.
#
# On reading the loss figure: it is the honest end-to-end outcome, but it is not
# by itself a network-loss measurement. In this repository's own history,
# co-located pairs -- the shortest possible path -- lost 16-59% while cross-host
# pairs lost 0.7-2.6%, which is the receiver failing to drain rather than the
# fabric dropping traffic. The telemetry sidecar settles it: UdpRcvbufErrors
# counts endpoint drops, IpInDiscards counts drops the IP layer made, and a
# network loss shows in neither. Read the counters before attributing the loss.
#
# jitter_ms carries the same caveat as any UDP percentile: it is computed only
# over datagrams that arrived, so a lossy arm reports the jitter of the
# survivors and looks better than it was.
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=iperf3-udp-1g-capacity
BENCHMARK_TOOL=iperf3
SKIP=0

IPERF3_PROTOCOL=udp
IPERF3_PARALLEL=1
IPERF3_UDP_BITRATE=1G
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
