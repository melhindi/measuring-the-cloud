# Latency vs offered rate

The TCP-vs-UDP ladder: one arm per (protocol x offered rate) at a fixed 64 B
message, run through `sockperf under-load` with `reply-every=1` so every message
yields a round-trip sample.

## Why the file names look like this

`run_benchmarks.sh` executes benchmark files in **lexical order**. The file name
is therefore not cosmetic -- it is the experiment's run order, and the run order
is part of the design.

    sockperf-ul-64b-<rate>kmps-<position><protocol>.sh

Three properties, each load-bearing:

1. **Zero-padded rate** (`001`, `005`, ... `100`) so the ladder ascends. Named
   with bare integers, lexical sort gives 100k, 10k, 1k, 25k, 50k, 5k -- the
   scenario would open with its heaviest arm on a just-booted instance and never
   traverse rate monotonically.

2. **Protocol last**, so the two protocols at a given rate run adjacently.
   Grouping by protocol instead puts every TCP arm before every UDP arm; at
   3 x 30 s plus cooldown per arm that separates them by roughly nine minutes,
   and any drift over those nine minutes -- thermal, noisy-neighbour, host
   migration -- is indistinguishable from a transport difference. The effect the
   study is looking for is single-digit percent and the within-scenario p50 CV
   is about 3%, so an order effect of that size is not survivable.

3. **A leading `1`/`2` position token that alternates by rung.** Adjacency alone
   still puts TCP first at every rung, which is a smaller bias but still a
   systematic one. Alternating the leader makes it a balanced design: three
   rungs lead TCP, three lead UDP, and monotonic drift cancels across the ladder
   rather than accumulating in one protocol's favour.

`BENCHMARK_NAME` intentionally omits the position token -- it names the
measurement (`...-tcp`), not the slot it ran in, so reports and artifact
directories stay readable and a rung compares against itself across runs even if
the alternation is ever re-cut. The file name and `BENCHMARK_NAME` differing is
deliberate; do not "fix" it by making them match.

## What is still confounded

Rungs run in one fixed ascending order, so rate remains confounded with time
within a scenario. Randomising it would break the alternation's cancellation
property and make runs non-comparable. The intended control is the reversal
arm (`--reversal-control`), which re-runs the first scenario at the end of the
matrix and reports the drift as a noise floor that effect sizes must clear.
