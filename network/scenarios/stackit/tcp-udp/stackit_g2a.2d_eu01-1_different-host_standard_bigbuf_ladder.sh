#!/usr/bin/env bash
# Intra-AZ with a socket receive buffer that actually changes: the fourth paired
# arm to stackit_g2a.2d_eu01-1_different-host_standard_ladder.
#
# Everything is held identical to that scenario except SOCKPERF_BUFFER_SIZE.
#
# Why this arm exists. The study already concluded that UDP loss on STACKIT is
# not a buffer artifact, on the grounds that the network-throughput profile
# raised net.core.rmem_max 630x -- 212992 to 134217728 -- and the loss did not
# go away. That conclusion tested nothing. rmem_max is a ceiling on what an
# application may request, not a size it receives; UDP has no receive autotuning
# the way TCP does, so a UDP socket takes net.core.rmem_default, which the
# profile never touched. Read out of ss on stackit-ladder-05, every sockperf
# socket in all five arms measured rb 212992, tuned and untuned alike -- 105 of
# 105 repetitions.
#
# The same telemetry says the buffer was the binding constraint. recv_queue_max
# sat at 213760 against an rb of 212992 in four of the five arms: the queue was
# pinned full. And nstat attributes the loss entirely to UdpRcvbufErrors with
# IpInDiscards at zero, so nothing was lost in the network -- the packets
# arrived, climbed the stack, and were discarded because the application could
# not be scheduled to read them.
#
# The arithmetic. The kernel sets the effective buffer to
# 2 * min(SO_RCVBUF_request, rmem_max), so the request has to be paired with a
# ceiling that admits it or it is silently clamped -- verified locally, where
# requesting 8 MB against an rmem_max of 4 MB yielded rb 8388608 rather than
# 16777216. The runner therefore raises rmem_max to at least the requested size
# alongside the request. 8388608 here gives an effective rb of 16777216, about
# 79x the 212992 every prior run used, or roughly 218 ms of traffic at 100k
# msg/s and 64 B messages against the ~2.8 ms the old buffer held.
#
# Raising the ceiling confounds nothing, which is the reason this can still be a
# one-variable comparison against the standard baseline: rmem_max has no
# behavioural effect on its own, and the measurement above is precisely that
# nothing was requesting against it.
#
# What each outcome would mean. If loss collapses, "UDP drops under load on
# STACKIT" was a statement about a default buffer, and the earlier conclusion
# has to be withdrawn. If loss survives a 79x buffer, the earlier conclusion was
# right for the wrong reason and the loss belongs to something else -- most
# likely the scheduling gaps, since 218 ms of buffer is more than any plausible
# hypervisor quantum.
#
# Read it against contention, not in isolation. CPU steal on g2a.2d ran 8.6-11.0%
# mean with a 47% peak and dominates every STACKIT number in this study; a
# provisioning that draws a quiet host will look better than one that does not,
# whatever the buffer does. Confirm the treatment took from rb_bytes in
# network_socket.csv, and check worst-end steal before comparing arms.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_different-host_standard_bigbuf_ladder
OS_TUNING=standard
SOCKPERF_BUFFER_SIZE=8388608
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-1
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
