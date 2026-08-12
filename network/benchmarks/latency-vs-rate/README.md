# Latency vs Offered Rate

A ladder of `sockperf under-load` runs at fixed message size and increasing
offered message rate, for both TCP and UDP.

## Why this exists

The rest of the network suite measures two operating points and nothing between
them: `iperf3` saturates the link, and `sockperf pp` keeps one message in flight,
which is effectively idle. Applications run in between, and that is where TCP and
UDP actually differ — ordering, retransmission and congestion control cost little
at one message in flight and a great deal under load.

Two consequences worth knowing when reading these results:

- **A protocol comparison at ping-pong rates will show almost nothing.** Both
  protocols move one packet each way. Any TCP/UDP latency difference has to be
  read off the shape of the curve, not from a single point.
- **The bottom rung is where CPU idle-state exit cost is largest.** That cost has
  been measured elsewhere at roughly +171 µs at ~1k msg/s, falling to ~0 at high
  packet rate — larger than the same-AZ round trip. `1kmps` is included
  deliberately so the effect is visible rather than hidden, and scenarios can set
  `CPU_IDLE_PINNING=1` to separate it from genuine path latency. Check
  `cpu_idle_pinning_supported` in the analysis before attributing a low-rate
  difference to the network: not every instance type exposes the control.

## Rungs

`1k`, `5k`, `10k`, `25k`, `50k`, `100k` messages/second, TCP and UDP, 64-byte
messages. With `--reply-every 1` every message is answered, so the packet rate on
the wire is twice the offered message rate.

## Running it

```bash
./network/runner.sh \
  --scenario network/scenarios/aws/baseline.sh \
  --benchmark-dir network/benchmarks/latency-vs-rate
```

Rungs above the pair's capacity will show sockperf dropping messages. That is a
result, not a failure: read `dropped_messages` alongside the percentiles, and
treat any rung with drops as measuring the knee rather than the latency.

## Adding a rung

Copy a file and change `SOCKPERF_MPS` and the name. Everything else comes from
`network/scripts/benchmark_defaults.sh`, so rungs cannot drift apart in message
size or runtime.
