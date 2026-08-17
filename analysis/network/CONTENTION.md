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

## Limit: steal control is necessary but not sufficient

The two low-steal UDP measurements above — 2.4% and 2.0% — differ by 20% in
delivered rate and 80% in p50. Host-to-host variation that steal does not
capture is still large, so a single provisioning is unreliable even after
filtering. Repeating the STACKIT arms across several provisionings is the only
way to get a baseline worth comparing against AWS and GCP.

## Open decisions

1. Whether to apply `max_steal_pct` as a filter to the report's existing
   figures. It is currently **reported, not applied**, because filtering would
   silently change every published number. See the Hypervisor Contention section
   in `network_benchmark_analysis.Rmd`.
2. Whether to add the steal/UDP interaction above as a query in
   `network_benchmarks.json`. Interacts with (1).
3. Whether to repeat the STACKIT arms across provisionings (more spend).

## Not verified

`build_duckdb.R`, `validate_csv.R` and the report render have never been
executed. The R `duckdb` package is only in the `.#analysis` nix shell and wants
a source build. Column references were checked against the real CSVs and the R
parses, but that is weaker than having run. The Rmd chunks added for the
contention section are the least-tested code here.

To close this out:

    nix develop .#analysis
    Rscript analysis/network/build_csv.R stackit-ladder-05
    Rscript analysis/network/build_cpu_csv.R stackit-ladder-05
    Rscript analysis/network/build_softnet_csv.R stackit-ladder-05
    Rscript analysis/network/build_duckdb.R stackit-ladder-05
    Rscript analysis/network/validate_csv.R stackit-ladder-05
    Rscript analysis/network/render_network_benchmark_analysis.R stackit-ladder-05

## Data quality note

`tuned` rep 2 at the 100k UDP rung recorded a p99 of **1,041,042 us** — a
1.04-second stall, at 3.9% steal. Nothing currently flags it. It is a stall, not
a percentile, and it will distort any tail statistic that includes it.
