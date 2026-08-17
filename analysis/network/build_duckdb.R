#!/usr/bin/env Rscript
# Build a queryable DuckDB from the parsed network CSVs.
#
# usage: build_duckdb.R <result-id> [out.duckdb]
#
# The CSVs are the analysis boundary: build_csv.R owns parsing raw artifacts,
# and this owns shaping them for SQL. Nothing here re-reads artifacts.
#
# Three tables rather than one flat one. sockperf and iperf3 measure different
# things -- round-trip latency at a controlled message rate, versus throughput
# and loss -- and folding them together would leave every row half NULL and
# every query filtering on which half it wanted. They share the scenario
# columns, so joining or unioning them is still one line of SQL.
#
#   network_latency            one row per sockperf repetition
#   network_capacity           one row per iperf3 repetition
#   network_capacity_intervals per-second samples inside an iperf3 run
#   network_softnet            per-CPU receive-path counters per repetition
#   network_cpu                per-CPU utilisation and steal per repetition
#
# network_latency and network_capacity each carry worst_steal_pct, joined from
# network_cpu at build time. Steal is a property of the measurement, so it
# belongs on the measurement row: on STACKIT it correlated at r = -0.97 with
# delivered rate, a stronger predictor than any treatment in this study, while
# AWS and GCP measured 0.0% throughout.
#   network_socket             effective socket buffer and drops per repetition
#
# Derived columns are the point of this file. Three quantities were repeatedly
# got wrong while analysing this data by hand, so they are computed once here
# rather than left to whoever writes the next query:
#
#   delivered_mps   messages that ARRIVED per second. achieved_mps counts what
#                   the generator sent, and UDP can hit any offered rate by
#                   dropping the excess -- so comparing protocols on sent rate
#                   flatters UDP by exactly the traffic it failed to deliver.
#   delivered_pct   the same as a fraction, for admission filters.
#   packets_per_sec the axis the limits actually live on. Every ceiling found in
#                   this study was packet-rate bound, never bandwidth bound, and
#                   at 64 B a rate that looks tiny in bits/s is enormous in
#                   packets/s.
suppressMessages({
  library(duckdb)
  library(DBI)
})

# usage: build_duckdb.R <result-id> [out.duckdb] [--suite NAME]
#
# --suite restricts every table to one investigation. The artifacts directory
# accumulates unrelated runs -- an older iperf3 throughput suite, plumbing smoke
# tests -- and they are not comparable with the latency ladder: the old suite ran
# sockperf in ping-pong mode at 64 B, which pools with the ladder's ping-pong
# anchor under any query that does not filter benchmark_name. Measured across the
# published query set, six of nineteen queries returned different numbers with
# the other runs present.
#
# So the database published alongside an investigation should contain that
# investigation. Omit the flag to keep everything, which is what local analysis
# wants.
args <- commandArgs(trailingOnly = TRUE)
suite_filter <- NA_character_
si <- match("--suite", args)
if (!is.na(si)) {
  if (length(args) < si + 1) stop("--suite needs a value")
  suite_filter <- args[[si + 1]]
  args <- args[-c(si, si + 1)]
}
if (length(args) < 1) stop("usage: build_duckdb.R <result-id> [out.duckdb] [--suite NAME]")
result_id <- args[[1]]

script_dir <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
repo_root <- normalizePath(file.path(script_dir, "..", ".."))
in_dir <- file.path(repo_root, "analysis", "network", result_id)
if (!dir.exists(in_dir)) stop(sprintf("no such result directory: %s", in_dir))

out_path <- if (length(args) >= 2) args[[2]] else file.path(in_dir, "network_benchmarks.duckdb")
# invisible(): file.remove() returns a visible TRUE, which an if at top level
# prints, so every rebuild emitted a stray [1] TRUE above the table counts.
if (file.exists(out_path)) invisible(file.remove(out_path))

csv <- function(name) {
  p <- file.path(in_dir, name)
  if (!file.exists(p)) stop(sprintf("missing %s; run build_csv.R %s first", name, result_id))
  gsub("'", "''", p, fixed = TRUE)
}

con <- dbConnect(duckdb::duckdb(), out_path)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# CPU state has to be loaded before the measurement tables, because they carry a
# steal column derived from it.
#
# Always created, empty if the CSV is absent. A missing table would make every
# query below fail to bind; an empty one lets them run and report NULL steal,
# which is the honest answer for a run with no telemetry. Absence is normal --
# build_cpu_csv.R is a separate step and COLLECT_TELEMETRY can be off.
cpu_csv <- file.path(in_dir, "network_cpu.csv")
if (file.exists(cpu_csv)) {
  invisible(dbExecute(con, sprintf("
create table network_cpu as select * from read_csv_auto('%s', header = true)
", gsub("'", "''", cpu_csv, fixed = TRUE))))
} else {
  invisible(dbExecute(con, "
create table network_cpu (
  run_id varchar, scenario_name varchar, benchmark_name varchar,
  repetition bigint, role varchar, cpu bigint, samples bigint,
  usr_pct double, sys_pct double, irq_pct double, softirq_pct double,
  steal_pct double, steal_pct_max double, idle_pct double)"))
}

# Worst-end steal per repetition: the max across the pair, because either host
# being descheduled stalls the round trip. CPU 1 is the benchmark core --
# remote_cpu_list() pins benchmarks to 1..n-1 and leaves CPU 0 for the samplers.
invisible(dbExecute(con, "
create view rep_steal as
select run_id, scenario_name, benchmark_name, repetition,
       max(steal_pct)     as worst_steal_pct,
       max(steal_pct_max) as peak_steal_pct
from network_cpu where cpu = 1
group by 1, 2, 3, 4"))

# TRY_CAST throughout: a column is typed by read_csv_auto from the data present,
# so one that is empty in this result set arrives as VARCHAR and would abort the
# arithmetic. TRY_CAST yields NULL instead, which is the honest answer.
invisible(dbExecute(con, sprintf("
create table network_latency as
select
  sp.* exclude (client_private_ip, server_private_ip, target_ip, source_file),
  -- see the header: delivered, not sent
  try_cast(received_messages as double)
    / nullif(try_cast(valid_duration_sec as double), 0)            as delivered_mps,
  100.0 * try_cast(received_messages as double)
    / nullif(try_cast(sent_messages as double), 0)                 as delivered_pct,
  -- one message out and one reply back crosses the client NIC twice
  2 * try_cast(received_messages as double)
    / nullif(try_cast(valid_duration_sec as double), 0)            as packets_per_sec,
  try_cast(p99_rtt_us as double)
    / nullif(try_cast(p50_rtt_us as double), 0)                    as tail_ratio_p99_p50,
  -- Steal travels WITH the measurement rather than sitting in a separate table
  -- nobody joins. A tail percentile and the contention that may have caused it
  -- have to be visible in the same row, or a reader has no way to tell a
  -- transport effect from a descheduled vCPU -- which is exactly how a busy_poll
  -- arm was briefly credited with a 4x improvement that was entirely its
  -- control sitting at 31 percent steal against the treatment's 0.7.
  --
  -- LEFT JOIN, so a run without CPU telemetry keeps its measurement rows with a
  -- NULL steal. An inner join would silently drop every row of every older run.
  st.worst_steal_pct,
  st.peak_steal_pct
from read_csv_auto('%s', header = true) sp
left join rep_steal st
  on  st.run_id         = sp.run_id
  and st.scenario_name  = sp.scenario_name
  and st.benchmark_name = sp.benchmark_name
  and st.repetition     = sp.repetition
", csv("network_sockperf.csv"))))

invisible(dbExecute(con, sprintf("
create table network_capacity as
select
  ip.* exclude (client_ip, server_ip, source_file),
  -- iperf3 is one-way, so this is packets on the wire in the sending direction
  try_cast(receiver_mbit_per_sec as double) * 1e6
    / nullif(8.0 * try_cast(udp_length_bytes as double), 0)        as approx_packets_per_sec,
  100.0 * try_cast(receiver_mbit_per_sec as double)
    / nullif(try_cast(udp_target_bitrate_gbit_per_sec as double) * 1000.0, 0) as delivered_pct_of_target,
  st.worst_steal_pct,
  st.peak_steal_pct
from read_csv_auto('%s', header = true) ip
left join rep_steal st
  on  st.run_id         = ip.run_id
  and st.scenario_name  = ip.scenario_name
  and st.benchmark_name = ip.benchmark_name
  and st.repetition     = ip.repetition
", csv("network_iperf3.csv"))))

invisible(dbExecute(con, sprintf("
create table network_capacity_intervals as
-- No exclude here. The interval table is built from a deliberately narrow
-- column set (see iperf3_interval_cols in build_csv.R) that already omits
-- source_file and the scenario metadata, because interval rows outnumber
-- measurement rows 13 to 1 and carrying 78 scenario columns on each was most
-- of the published file size.
select *
from read_csv_auto('%s', header = true)
", csv("network_iperf3_intervals.csv"))))

# Telemetry, at a different grain from everything above: one row per CPU per
# repetition rather than one per repetition. Optional, because it exists only
# for runs made after softnet_stat collection was added and only when telemetry
# was enabled. Join on (run_id, scenario_name, benchmark_name, repetition).
softnet_csv <- file.path(in_dir, "network_softnet.csv")
if (file.exists(softnet_csv)) {
  invisible(dbExecute(con, sprintf("
create table network_softnet as
select *,
  -- time_squeeze is the counter that tests whether NAPI is exhausting its
  -- budget. Normalised per million packets so a rate ladder can be read down
  -- the column: the raw count rises with offered load whether or not anything
  -- is wrong, which makes the absolute number unusable for comparing rungs.
  1e6 * try_cast(time_squeeze_delta as double)
    / nullif(try_cast(processed_delta as double), 0)          as squeeze_per_mpkt,
  1e6 * try_cast(dropped_delta as double)
    / nullif(try_cast(processed_delta as double), 0)          as backlog_drops_per_mpkt
from read_csv_auto('%s', header = true)
", gsub("'", "''", softnet_csv, fixed = TRUE))))
}

# The sockperf socket's effective buffer and drops. This is what makes a buffer
# treatment falsifiable: rb_bytes is what the socket got, not what was asked for,
# and the two differ because the kernel computes 2 * min(request, rmem_max).
socket_csv <- file.path(in_dir, "network_socket.csv")
if (file.exists(socket_csv)) {
  invisible(dbExecute(con, sprintf("
create table network_socket as
select *,
  -- A queue that sat at the buffer ceiling was buffer limited. Measured at
  -- 1.00 across four of five arms on stackit-ladder-05, with rb identical in
  -- every one of them.
  try_cast(recv_queue_max as double)
    / nullif(try_cast(rb_bytes as double), 0)                as queue_fill_ratio
from read_csv_auto('%s', header = true)
", gsub("'", "''", socket_csv, fixed = TRUE))))
}

failures_csv <- file.path(in_dir, "network_failures.csv")
if (file.exists(failures_csv)) {
  invisible(dbExecute(con, sprintf("
create table network_failures as select * from read_csv_auto('%s', header = true)
", gsub("'", "''", failures_csv, fixed = TRUE))))
}

if (!is.na(suite_filter)) {
  # network_cpu / network_softnet / network_socket carry no suite column -- they
  # are keyed by scenario_name, so restrict them by membership instead. Done
  # before the row counts print, so the reported numbers are the published ones.
  keep <- sprintf("select distinct scenario_name from network_latency
                   union select distinct scenario_name from network_capacity")
  # Base tables only. rep_steal is a view over network_cpu, so it follows the
  # filter automatically and cannot be deleted from.
  base_tables <- dbGetQuery(con, "select table_name from information_schema.tables where table_type = 'BASE TABLE'")$table_name
  for (tbl in base_tables) {
    cols <- dbGetQuery(con, sprintf("select column_name from information_schema.columns where table_name = '%s'", tbl))$column_name
    if ("suite" %in% cols) {
      invisible(dbExecute(con, sprintf("delete from %s where suite is distinct from '%s'", tbl, suite_filter)))
    }
  }
  for (tbl in base_tables) {
    cols <- dbGetQuery(con, sprintf("select column_name from information_schema.columns where table_name = '%s'", tbl))$column_name
    if (!("suite" %in% cols) && "scenario_name" %in% cols) {
      invisible(dbExecute(con, sprintf("delete from %s where scenario_name not in (%s)", tbl, keep)))
    }
  }
  cat(sprintf("restricted to suite '%s'\n", suite_filter))
}

for (tbl in dbGetQuery(con, "select table_name from information_schema.tables order by 1")$table_name) {
  n <- dbGetQuery(con, sprintf("select count(*) as n from %s", tbl))$n
  cat(sprintf("  %-28s %6d rows\n", tbl, n))
}
# DELETE frees rows but not pages, so a filtered build stays the size of the
# unfiltered one -- 4.2 MB of mostly-empty file. There is no VACUUM; the
# supported way to reclaim is to copy the database out. Done only when a filter
# ran, so the ordinary build path is untouched.
if (!is.na(suite_filter)) {
  dbDisconnect(con, shutdown = TRUE)
  on.exit()
  compact <- paste0(out_path, ".compact")
  if (file.exists(compact)) invisible(file.remove(compact))
  # In-memory connection with both databases attached by name. Connecting
  # directly to the target names its catalog after the file, not "memory", so
  # the copy has to address it explicitly.
  cc <- dbConnect(duckdb::duckdb())
  invisible(dbExecute(cc, sprintf("attach '%s' as src (read_only)", gsub("'", "''", out_path, fixed = TRUE))))
  invisible(dbExecute(cc, sprintf("attach '%s' as tgt", gsub("'", "''", compact, fixed = TRUE))))
  invisible(dbExecute(cc, "copy from database src to tgt"))
  invisible(dbExecute(cc, "detach tgt"))
  invisible(dbExecute(cc, "detach src"))
  dbDisconnect(cc, shutdown = TRUE)
  before <- file.info(out_path)$size
  invisible(file.rename(compact, out_path))
  cat(sprintf("compacted %.1f MB -> %.1f MB\n", before / 1e6, file.info(out_path)$size / 1e6))
}

cat(sprintf("\nWrote %s\n", out_path))
