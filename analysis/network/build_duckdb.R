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

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: build_duckdb.R <result-id> [out.duckdb]")
result_id <- args[[1]]

script_dir <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
repo_root <- normalizePath(file.path(script_dir, "..", ".."))
in_dir <- file.path(repo_root, "analysis", "network", result_id)
if (!dir.exists(in_dir)) stop(sprintf("no such result directory: %s", in_dir))

out_path <- if (length(args) >= 2) args[[2]] else file.path(in_dir, "network_benchmarks.duckdb")
if (file.exists(out_path)) file.remove(out_path)

csv <- function(name) {
  p <- file.path(in_dir, name)
  if (!file.exists(p)) stop(sprintf("missing %s; run build_csv.R %s first", name, result_id))
  gsub("'", "''", p, fixed = TRUE)
}

con <- dbConnect(duckdb::duckdb(), out_path)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# TRY_CAST throughout: a column is typed by read_csv_auto from the data present,
# so one that is empty in this result set arrives as VARCHAR and would abort the
# arithmetic. TRY_CAST yields NULL instead, which is the honest answer.
invisible(dbExecute(con, sprintf("
create table network_latency as
select
  * exclude (client_private_ip, server_private_ip, target_ip, source_file),
  -- see the header: delivered, not sent
  try_cast(received_messages as double)
    / nullif(try_cast(valid_duration_sec as double), 0)            as delivered_mps,
  100.0 * try_cast(received_messages as double)
    / nullif(try_cast(sent_messages as double), 0)                 as delivered_pct,
  -- one message out and one reply back crosses the client NIC twice
  2 * try_cast(received_messages as double)
    / nullif(try_cast(valid_duration_sec as double), 0)            as packets_per_sec,
  try_cast(p99_rtt_us as double)
    / nullif(try_cast(p50_rtt_us as double), 0)                    as tail_ratio_p99_p50
from read_csv_auto('%s', header = true)
", csv("network_sockperf.csv"))))

invisible(dbExecute(con, sprintf("
create table network_capacity as
select
  * exclude (client_ip, server_ip, source_file),
  -- iperf3 is one-way, so this is packets on the wire in the sending direction
  try_cast(receiver_mbit_per_sec as double) * 1e6
    / nullif(8.0 * try_cast(udp_length_bytes as double), 0)        as approx_packets_per_sec,
  100.0 * try_cast(receiver_mbit_per_sec as double)
    / nullif(try_cast(udp_target_bitrate_gbit_per_sec as double) * 1000.0, 0) as delivered_pct_of_target
from read_csv_auto('%s', header = true)
", csv("network_iperf3.csv"))))

invisible(dbExecute(con, sprintf("
create table network_capacity_intervals as
select * exclude (source_file)
from read_csv_auto('%s', header = true)
", csv("network_iperf3_intervals.csv"))))

failures_csv <- file.path(in_dir, "network_failures.csv")
if (file.exists(failures_csv)) {
  invisible(dbExecute(con, sprintf("
create table network_failures as select * from read_csv_auto('%s', header = true)
", gsub("'", "''", failures_csv, fixed = TRUE))))
}

for (tbl in dbGetQuery(con, "select table_name from information_schema.tables order by 1")$table_name) {
  n <- dbGetQuery(con, sprintf("select count(*) as n from %s", tbl))$n
  cat(sprintf("  %-28s %6d rows\n", tbl, n))
}
cat(sprintf("\nWrote %s\n", out_path))
