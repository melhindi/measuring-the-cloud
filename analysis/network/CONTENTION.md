# Hypervisor contention, and what it did to the STACKIT results

Findings from `stackit-ladder-05` (2026-08-17). Written down because the
measurements are on disk but the reasoning that connects them was not.

## The short version

CPU steal on STACKIT is large, systematic, and was silently inside every
STACKIT latency number in this study. It invalidated one published conclusion,
left another standing, and produced a third that is more interesting than
either.

## How it was found

`mpstat` has been collected on every run in this repository since telemetry was
added and had never been parsed — the cross-provider softirq comparison
(11.5 / 6.3 / 0.0%) was assembled by grepping logs one at a time. Parsing it
was prompted by a `busy_poll` arm that appeared to deliver a 4x improvement.

The improvement was not real. Its control had landed on a host with 31% steal
against the treatment's 0.7%.

    arm                   worst steal   delivered (100k UDP)   p50
    standard (ladder-01)         0.7%                 92,716   1,973 us
    busypoll (ladder-05)         0.8%                 90,356   1,748 us
    tuned    (ladder-05)     0.8-3.9%              70-83,000   2,701-4,927 us
    standard (ladder-05)          31%                 47,161   7,348 us
    rps      (ladder-05)          37%                 42,318   11,144 us

Steal explains the ordering. The treatments do not.

## Steal is a provider difference

Benchmark core (CPU 1), every run ever made in this repo:

    provider   mean steal   peak    reps over 5%
    aws          0.0%       0.1%      0%
    gcp          0.0%       0.0%      0%
    stackit      8.6-11.0%  47.0%    56%

`g2a.2d` is more oversubscribed than `c6id.large` or `n2-standard-2`. That is a
product difference and a legitimate thing to report — but it is not a network
difference, and it lands on the same measurement.

## What died: the packet-rate ceiling

The claimed "hard ceiling around 60k packets/s" on STACKIT was contention.
Across 18 STACKIT repetitions at the 100k rung, worst-end steal correlates at
**r = -0.97** with delivered message rate: uncontended hosts deliver 74k-93k
msg/s, contended ones 39k-47k. On a clean host STACKIT reaches ~93% of a 100k
msg/s offered load, so there is no ceiling to explain.

Three guest-side explanations were tested directly and all three are negative:

- `netdev_budget` 300 -> 1000 — confirmed applied via the new read-back, changes
  nothing. `time_squeeze` is already 0.7 per million packets on a clean host, so
  the budget was never the binding constraint.
- `busy_poll` — nothing, once steal is matched.
- `rps_cpus` — steers as designed (`received_rps` confirms the cross-CPU
  handoff) and makes latency **1.4-2.1x worse** below 25k msg/s. The IPI costs
  more than the contention it relieves. On a 2-vCPU instance the only core to
  move to is CPU 0, which also runs the telemetry samplers.

`time_squeeze` does rise with contention — 0.7 per million packets below 3%
steal, 113 above 25% — but that is a stolen time slice ending a poll with work
still queued, not an exhausted budget. Same counter, different cause.

## What survived: UDP is genuinely worse on STACKIT

At 2.0% steal, inter-AZ, 100k msg/s: UDP delivers 90,772 against TCP's 99,994,
at 2,160 us p50 against 1,572. UDP loses on STACKIT even on a clean host, unlike
AWS and GCP where it wins at high rate. Contention inflated the magnitude; it
did not invent the direction.

## The new finding: steal penalises UDP and not TCP

STACKIT inter-AZ, 100k rung, across runs:

    run         proto   worst steal   delivered   p50
    ladder-02   tcp           9.3%       99,999   1,587 us
    ladder-04   tcp          24.8%      100,000   1,766 us
    ladder-05   tcp           5.4%       99,994   1,572 us
    ladder-02   udp           2.4%       75,887   3,884 us
    ladder-04   udp          36.6%       41,563   6,901 us
    ladder-05   udp           2.0%       90,772   2,160 us

TCP delivered its full offered rate in all three runs including at 24.8% steal,
p50 varying only 1,572-1,766 us. UDP's delivered rate swung 41k-91k and its p50
2,160-6,901 us.

This is the study's own closed-loop/open-loop distinction turning up somewhere
nobody was looking. TCP paces the sender to what the receiver absorbs, so a
descheduled vCPU slows the ACK loop and the offered rate still lands. UDP has no
feedback: the sender blasts regardless and whatever the stolen receiver cannot
drain becomes loss.

**Contention is therefore not a neutral noise source. It systematically
penalises the protocol under test.** Any UDP-vs-TCP comparison on a contended
host is biased, not merely noisy.

## How often a STACKIT provisioning is contended: usually

Measured across every provisioning in the repository, taking each one's mean
steal on the benchmark core and the worse of its two ends:

    provider   provisionings   contended (>5%)   median worst-end   max
    aws                    9          0 (  0%)              0.0%    0.0%
    gcp                    6          0 (  0%)              0.0%    0.0%
    stackit               14         12 ( 86%)             12.9%   23.6%

Only 2 of 14 STACKIT provisionings were genuinely quiet. There is no practical
"retry until you draw a quiet host" strategy on g2a.2d -- contention is the
normal case.

This corrects an earlier estimate in this session of a ~27% bad-draw rate with a
bimodal distribution. That came from reading per-repetition steal at the 100k
rung only, where values happened to cluster near 1% or near 30%. Across whole
provisionings the distribution is a continuum from 1.7% to 23.6%. The practical
consequence of the error was a recommendation that six provisionings would yield
four or five quiet draws; at the true rate it would have yielded about one.

## Consequence: UDP's deficit scales with contention

STACKIT, 100k msg/s, 10 repetitions per cell:

    arm         proto   worst steal   delivered   p50
    inter-AZ    tcp            28%       99,998   2,088 us
    inter-AZ    udp            32%       40,420   7,464 us
    intra-AZ    tcp            20%       99,996   1,916 us
    intra-AZ    udp            35%       42,678   8,023 us

Against the quietest draw available (ladder-05 inter-AZ, 4.9% worst-end), where
UDP delivered 90,772 of 100,000. So UDP delivers ~91% of offered load on a quiet
host and ~40% on a contended one, while TCP holds 100% throughout.

The honest reading is a product statement rather than a network one: on g2a.2d,
UDP at high message rates is unreliable in practice, because contention is the
norm and UDP converts contention into loss where TCP converts it into a slower
ACK loop.

## What repetitions bought, and what they did not

stackit-reps-01 ran both arms at 10 repetitions instead of 3.

Gained: stall frequency became measurable. One repetition of the intra-AZ UDP
100k arm recorded a p99 of 905,373 us against a median of 34,182 across the
other nine -- so stalls are a 1-in-10 event, not the one-off the earlier 1.04
second outlier appeared to be.

Not gained: precision on the central estimate. A 3-repetition median would have
reported p99 between 33,451 and 34,341 us across every consecutive window,
within 3% of the 10-repetition median. The median already discards the stall.

Also not gained: within-host steal correlation. Steal varies only in a narrow
band within one provisioning (19-28% at the 100k rung), so per-repetition
correlations come out inconsistent -- r = 0.97 for p50 at TCP 100k but -0.92 at
TCP 25k, which is a range artifact. The steal-to-latency relationship is
established between hosts, where the range spans two orders of magnitude, and
repetitions cannot substitute for that.

## Limit: steal control is necessary but not sufficient

The two low-steal UDP measurements above — 2.4% and 2.0% — differ by 20% in
delivered rate and 80% in p50. Host-to-host variation that steal does not
capture is still large, so a single provisioning is unreliable even after
filtering. Repeating the STACKIT arms across several provisionings is the only
way to get a baseline worth comparing against AWS and GCP.

## A second treatment that was never applied: the socket buffer

Tested after the above, and it invalidates a further conclusion.

The study recorded that UDP loss on STACKIT is not a buffer artifact, because
the `network-throughput` profile raises `net.core.rmem_max` 630x (212992 ->
134217728) and the loss did not go away. **That tested nothing.** `rmem_max` is
a ceiling on what an application may *request*; UDP has no receive autotuning
the way TCP does, so the socket takes `net.core.rmem_default`, which the profile
never sets. Read out of `ss` skmem: `rb` was **212992 in all 105 repetitions**
of stackit-ladder-05, in every arm, tuned and untuned alike.

The same telemetry shows the buffer was the binding constraint on loss. Server
side, UDP, by rung:

    rung          queue_fill_ratio   socket drops
    ping-pong               0.006              0
    1k msg/s                0.003              0
    5k msg/s                0.005              0
    10k msg/s               0.141             64
    25k msg/s               0.385          1,301
    50k msg/s               0.705         72,947
    100k msg/s              0.987        598,780

Drops appear exactly where the queue starts filling and explode as it approaches
full. `nstat` agrees: loss is entirely `UdpRcvbufErrors` with `IpInDiscards` at
zero, so the packets arrived, climbed the stack, and were discarded because the
application could not be scheduled to read them.

So contention and buffer size are not competing explanations. **Steal creates the
stalls; the buffer's size decides how much traffic survives one.** Neither was
ever varied. At 212992 bytes and roughly 768 bytes of skb overhead per 64 B
datagram, the buffer held about 2.8 ms of traffic at 100k msg/s -- less than a
single hypervisor scheduling quantum.

`SOCKPERF_BUFFER_SIZE` now exists to test it, via sockperf `--buffer-size`
(SO_RCVBUF/SO_SNDBUF) on both roles. Note the kernel arithmetic: the effective
buffer is `2 * min(request, rmem_max)`, so a request above the ceiling is
silently clamped -- verified locally, where 8 MB against a 4 MB ceiling yielded
rb 8388608 rather than 16777216. The runner therefore raises `rmem_max` to at
least the request alongside it, which confounds nothing precisely because
`rmem_max` has no effect on its own. Confirm the treatment took from `rb_bytes`
in `network_socket.csv`, never from the requested value.

`stackit_g2a.2d_eu01-1_different-host_standard_bigbuf_ladder` requests 8388608,
giving an effective 16777216 -- about 79x, or ~218 ms of traffic at 100k msg/s.

## Publishing

The published pair lives at `~/git/cloudspecs/static/network_benchmarks.{duckdb,json}`
(the README there maps `dbId` to the filename stem).

    Rscript analysis/network/build_csv.R all
    Rscript analysis/network/build_cpu_csv.R all
    Rscript analysis/network/build_softnet_csv.R all
    Rscript analysis/network/build_socket_csv.R all
    Rscript analysis/network/build_duckdb.R all <out.duckdb> --suite tcp-udp-latency

`--suite` matters. The artifacts directory accumulates every run ever made --
this latency ladder, an older iperf3 throughput suite, and plumbing smoke tests
-- and they are not comparable. The old suite ran sockperf in ping-pong mode at
64 B, which pools with the ladder's ping-pong anchor under any query that does
not filter benchmark_name.

Measured, not assumed: building both databases and diffing all 19 published
queries, 6 returned different values for groups present in both -- "What was
measured" (4 of 9 groups), "Coordinated omission" (5 of 16), "Latency by
placement" (5 of 16), "Was the ladder ever bandwidth limited?" (2 of 8),
"Hypervisor CPU steal" (4 of 6) and "Delivered rate against steal" (1 of 11).
A further 8 gained extra rows without changing shared values, which is harmless.

A published dataset is read by people writing their own SQL who cannot know that
`sockperf-tcp-64b` and `sockperf-pp-64b-tcp` belong to different investigations,
so the filter belongs in the artifact rather than in a caveat. The `suite` column
is carried on every row regardless, so provenance stays visible.

Two implementation notes. DELETE does not reclaim pages in DuckDB, so a filtered
build is compacted by copying the database out -- without that it stayed the full
4.2 MB. And the local unfiltered build is unchanged: omit `--suite` for analysis
across every run, which is what the report renders from.

## Open decisions

1. Whether to apply `max_steal_pct` as a filter to the report's existing
   figures. It is currently **reported, not applied**, because filtering would
   silently change every published number. See the Hypervisor Contention section
   in `network_benchmark_analysis.Rmd`.
2. Whether to add the steal/UDP interaction above as a query in
   `network_benchmarks.json`. Interacts with (1).
3. Whether to repeat the STACKIT arms across provisionings (more spend).

## Verified

Everything below ran in `nix develop .#analysis` on 2026-08-17, once the shell
was available:

- `build_duckdb.R` — 7 tables
- `validate_csv.R` — Validation OK
- all 19 queries in `network_benchmarks.json` — 19 ok, 0 failed
- the report render — 86/86 chunks, contention section renders with real tables
- `run_sockperf.sh --buffer-size` end to end against a live sockperf, 212992 ->
  8388608 on the socket, flag recorded in `client.cmd`, summary and percentiles
  still parseable

Note for a future session: the duckdb-dependent scripts need
`nix develop .#analysis --command ...`; the default shell lacks duckdb, tidyr,
readr, stringr and lubridate. The three base-R parsers (`build_csv.R`,
`build_cpu_csv.R`, `build_softnet_csv.R`, `build_socket_csv.R`) run anywhere.

## Data quality note

`tuned` rep 2 at the 100k UDP rung recorded a p99 of **1,041,042 us** — a
1.04-second stall, at 3.9% steal. Nothing currently flags it. It is a stall, not
a percentile, and it will distort any tail statistic that includes it.
