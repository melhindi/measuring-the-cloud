#!/usr/bin/env Rscript

detect_repo_root <- function() {
  file_arg <- grep("^--file=", commandArgs(), value = TRUE)
  if (length(file_arg) > 0) {
    script_path <- normalizePath(sub("^--file=", "", file_arg[[1]]))
    return(normalizePath(file.path(dirname(script_path), "..", "..")))
  }
  normalizePath(getwd())
}

stop_if_not <- function(cond, msg) {
  if (!isTRUE(cond)) stop(msg, call. = FALSE)
}

args <- commandArgs(trailingOnly = TRUE)
result_id <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else "all"
repo_root <- detect_repo_root()
results_dir <- file.path(repo_root, "analysis", "network", result_id)

required_files <- c(
  "network_scenarios.csv",
  "network_iperf3.csv",
  "network_iperf3_intervals.csv",
  "network_sockperf.csv"
)

missing_files <- required_files[!file.exists(file.path(results_dir, required_files))]
stop_if_not(length(missing_files) == 0, sprintf("Missing CSV file(s): %s", paste(missing_files, collapse = ", ")))

library(DBI)
library(duckdb)

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

csv_path <- function(name) normalizePath(file.path(results_dir, name), mustWork = TRUE)
dbExecute(con, sprintf("create view scenarios as select * from read_csv_auto('%s')", csv_path("network_scenarios.csv")))
dbExecute(con, sprintf("create view iperf3 as select * from read_csv_auto('%s')", csv_path("network_iperf3.csv")))
dbExecute(con, sprintf("create view iperf3_intervals as select * from read_csv_auto('%s')", csv_path("network_iperf3_intervals.csv")))
dbExecute(con, sprintf("create view sockperf as select * from read_csv_auto('%s')", csv_path("network_sockperf.csv")))

# Glob every run directory, not just run-*.
#
# These counts exist to catch build_csv.R silently dropping a scenario, and they
# were matching "run-*" only -- the shape of an auto-generated RUN_ID. Every run
# launched with an explicit --run-id (stackit-ladder-05, aws-ladder-02, ...) was
# invisible to the check, so it compared 59 parsed scenarios against 34 on disk
# and failed; before that, it could equally have passed while ignoring most of
# the dataset. build_csv.R enumerates all run directories, so this must too.
raw_iperf3_count <- length(Sys.glob(file.path(repo_root, "artifacts", "network", "*", "*", "benchmarks", "*", "rep-*", "client", "iperf3.json")))
raw_sockperf_count <- length(Sys.glob(file.path(repo_root, "artifacts", "network", "*", "*", "benchmarks", "*", "rep-*", "client", "sockperf.log")))
raw_scenario_count <- length(Sys.glob(file.path(repo_root, "artifacts", "network", "*", "*", "scenario.env")))

csv_counts <- dbGetQuery(con, "
select
  (select count(*) from scenarios) as scenarios,
  (select count(*) from iperf3) as iperf3,
  (select count(*) from sockperf) as sockperf,
  (select count(*) from iperf3_intervals) as iperf3_intervals
")

if (identical(result_id, "all")) {
  stop_if_not(csv_counts$scenarios == raw_scenario_count, sprintf("Scenario count mismatch: csv=%s raw=%s", csv_counts$scenarios, raw_scenario_count))
  stop_if_not(csv_counts$iperf3 == raw_iperf3_count, sprintf("iperf3 count mismatch: csv=%s raw=%s", csv_counts$iperf3, raw_iperf3_count))
  stop_if_not(csv_counts$sockperf == raw_sockperf_count, sprintf("sockperf count mismatch: csv=%s raw=%s", csv_counts$sockperf, raw_sockperf_count))
}

protocol_field_check <- dbGetQuery(con, "
select
  sum(case when protocol = 'tcp' and udp_target_bitrate_gbit_per_sec is not null then 1 else 0 end) as tcp_with_udp_bitrate,
  sum(case when protocol = 'udp' and tcp_length_bytes is not null then 1 else 0 end) as udp_with_tcp_length,
  sum(case when protocol = 'udp' and lost_percent is null then 1 else 0 end) as udp_without_loss,
  sum(case when protocol = 'tcp' and receiver_mbit_per_sec is null then 1 else 0 end) as tcp_without_receiver_mbps
from iperf3
")

stop_if_not(protocol_field_check$tcp_with_udp_bitrate == 0, "TCP iperf3 rows unexpectedly contain UDP bitrate values")
stop_if_not(protocol_field_check$udp_with_tcp_length == 0, "UDP iperf3 rows unexpectedly contain TCP length values")
stop_if_not(protocol_field_check$udp_without_loss == 0, "UDP iperf3 rows unexpectedly miss lost_percent")
stop_if_not(protocol_field_check$tcp_without_receiver_mbps == 0, "TCP iperf3 rows unexpectedly miss receiver throughput")

# Scenario classification. An unclassified provider or placement means a new
# scenario naming convention outran the parser, which silently drops those runs
# out of every grouped comparison in the report.
classification_check <- dbGetQuery(con, "
select
  sum(case when provider is null or provider = '' then 1 else 0 end) as scenarios_without_provider,
  sum(case when placement_class is null or placement_class = '' then 1 else 0 end) as scenarios_without_placement,
  sum(case when placement_class not in
        ('single-az', 'co-located-single-az', 'different-host-single-az', 'multi-az', 'cross-region')
      then 1 else 0 end) as scenarios_with_unknown_placement,
  sum(case when pair_class is null or pair_class = '' then 1 else 0 end) as scenarios_without_pair_class,
  sum(case when placement_class = 'cross-region'
        and (server_region is null or server_region = '') then 1 else 0 end) as cross_region_without_region
from scenarios
")

stop_if_not(classification_check$scenarios_without_provider == 0,
            "Scenarios with an unrecognised provider prefix; extend detect_provider()")
stop_if_not(classification_check$scenarios_without_placement == 0,
            "Scenarios without a placement_class")
stop_if_not(classification_check$scenarios_with_unknown_placement == 0,
            "Scenarios with a placement_class outside the known set")
stop_if_not(classification_check$scenarios_without_pair_class == 0,
            "Scenarios without a pair_class; client/server machine types must both be recorded")
stop_if_not(classification_check$cross_region_without_region == 0,
            "Cross-region scenarios missing server_region")

message("CSV counts")
print(csv_counts)

message("scenarios by provider / placement / pairing")
print(dbGetQuery(con, "
select provider, placement_class, pair_class, count(*) as n
from scenarios
group by 1, 2, 3
order by 1, 2, 3
"))

message("iperf3 by placement / machine / tuning")
print(dbGetQuery(con, "
select placement_class, client_machine_type, os_tuning, count(*) as n
from iperf3
group by 1, 2, 3
order by 1, 2, 3
"))

message("iperf3 by protocol and benchmark parameters")
print(dbGetQuery(con, "
select protocol, parallel_streams, udp_length_bytes, udp_target_bitrate_gbit_per_sec,
       count(*) as n,
       round(avg(receiver_mbit_per_sec), 1) as avg_recv_mbps,
       round(avg(lost_percent), 2) as avg_loss_pct
from iperf3
group by 1, 2, 3, 4
order by 1, 2, 3, 4
"))

message("sockperf by protocol and message size")
print(dbGetQuery(con, "
select protocol, msg_size_bytes, count(*) as n,
       round(avg(avg_rtt_us), 2) as avg_rtt_us,
       round(avg(p99_rtt_us), 2) as p99_rtt_us
from sockperf
group by 1, 2
order by 1, 2
"))

message("iperf3 intervals by protocol and omit flag")
print(dbGetQuery(con, "
select protocol, omitted, count(*) as n
from iperf3_intervals
group by 1, 2
order by 1, 2
"))

message(sprintf("Validation OK: %s", results_dir))
