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
results_dir <- file.path(repo_root, "analysis", "storage", result_id)

required_files <- c(
  "storage_scenarios.csv",
  "storage_benchmarks.csv",
  "storage_fio.csv",
  "storage_failures.csv"
)

missing_files <- required_files[!file.exists(file.path(results_dir, required_files))]
stop_if_not(length(missing_files) == 0, sprintf("Missing CSV file(s): %s", paste(missing_files, collapse = ", ")))

library(DBI)
library(duckdb)

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

csv_path <- function(name) normalizePath(file.path(results_dir, name), mustWork = TRUE)
dbExecute(con, sprintf("create view scenarios as select * from read_csv_auto('%s')", csv_path("storage_scenarios.csv")))
dbExecute(con, sprintf("create view benchmarks as select * from read_csv_auto('%s')", csv_path("storage_benchmarks.csv")))
dbExecute(con, sprintf("create view fio as select * from read_csv_auto('%s')", csv_path("storage_fio.csv")))
dbExecute(con, sprintf("create view failures as select * from read_csv_auto('%s')", csv_path("storage_failures.csv")))

raw_scenario_count <- length(Sys.glob(file.path(repo_root, "artifacts", "storage", "run-*", "*", "scenario.env")))
raw_storage_env_count <- length(Sys.glob(file.path(repo_root, "artifacts", "storage", "run-*", "*", "storage.env")))
raw_benchmark_count <- length(Sys.glob(file.path(repo_root, "artifacts", "storage", "run-*", "*", "benchmarks", "*", "*", "benchmark.env")))
raw_fio_count <- length(Sys.glob(file.path(repo_root, "artifacts", "storage", "run-*", "*", "benchmarks", "*", "*", "rep-*", "fio.json")))

csv_counts <- dbGetQuery(con, "
select
  (select count(*) from scenarios) as scenarios,
  (select count(*) from benchmarks) as benchmarks,
  (select count(*) from fio) as fio,
  (select count(*) from failures) as failures
")

if (identical(result_id, "all")) {
  stop_if_not(csv_counts$scenarios == raw_scenario_count, sprintf("Scenario count mismatch: csv=%s raw=%s", csv_counts$scenarios, raw_scenario_count))
  stop_if_not(csv_counts$benchmarks == raw_benchmark_count, sprintf("Benchmark count mismatch: csv=%s raw=%s", csv_counts$benchmarks, raw_benchmark_count))
  stop_if_not(csv_counts$fio == raw_fio_count, sprintf("Fio count mismatch: csv=%s raw=%s", csv_counts$fio, raw_fio_count))
}

field_checks <- dbGetQuery(con, "
select
  sum(case when storage_target not in ('local', 'block') then 1 else 0 end) as bad_storage_target,
  sum(case when storage_target = 'local' and (storage_target_filesystem is null or storage_target_filesystem = '') then 1 else 0 end) as local_missing_target_filesystem,
  sum(case when storage_target = 'block' and (storage_target_filesystem is null or storage_target_filesystem = '') then 1 else 0 end) as block_missing_target_filesystem,
  sum(case when access_pattern not in ('random', 'sequential') then 1 else 0 end) as bad_access_pattern,
  sum(case when direction not in ('read', 'write') then 1 else 0 end) as bad_direction,
  sum(case when durability_mode not in ('none', 'fsync', 'fdatasync') then 1 else 0 end) as bad_durability_mode,
  sum(case when coalesce(fio_fsync, 0) < 0 or coalesce(fio_fdatasync, 0) < 0 or coalesce(durability_every_ops, 0) < 0 then 1 else 0 end) as negative_durability_values,
  sum(case when coalesce(fio_fsync, 0) > 0 and coalesce(fio_fdatasync, 0) > 0 then 1 else 0 end) as conflicting_durability_modes,
  sum(case when durability_mode = 'none' and coalesce(durability_every_ops, 0) <> 0 then 1 else 0 end) as bad_none_durability_every_ops,
  sum(case when durability_mode = 'fsync' and (coalesce(fio_fsync, 0) <= 0 or coalesce(fio_fdatasync, 0) <> 0 or coalesce(durability_every_ops, 0) <> coalesce(fio_fsync, 0)) then 1 else 0 end) as bad_fsync_durability_rows,
  sum(case when durability_mode = 'fdatasync' and (coalesce(fio_fdatasync, 0) <= 0 or coalesce(fio_fsync, 0) <> 0 or coalesce(durability_every_ops, 0) <> coalesce(fio_fdatasync, 0)) then 1 else 0 end) as bad_fdatasync_durability_rows,
  sum(case when valid_measurement and coalesce(fio_error, 0) <> 0 then 1 else 0 end) as valid_with_error,
  sum(case when not valid_measurement and coalesce(fio_error, 0) = 0 then 1 else 0 end) as invalid_without_error
from fio
")

stop_if_not(field_checks$bad_storage_target == 0, "Unexpected storage_target values in fio CSV")
stop_if_not(field_checks$local_missing_target_filesystem == 0, "Some local fio rows are missing storage_target_filesystem")
stop_if_not(field_checks$block_missing_target_filesystem == 0, "Some block fio rows are missing storage_target_filesystem")
stop_if_not(field_checks$bad_access_pattern == 0, "Unexpected access_pattern values in fio CSV")
stop_if_not(field_checks$bad_direction == 0, "Unexpected direction values in fio CSV")
stop_if_not(field_checks$bad_durability_mode == 0, "Unexpected durability_mode values in fio CSV")
stop_if_not(field_checks$negative_durability_values == 0, "Negative durability values were parsed from fio CSV")
stop_if_not(field_checks$conflicting_durability_modes == 0, "Some fio rows set both fsync and fdatasync")
stop_if_not(field_checks$bad_none_durability_every_ops == 0, "Some non-durable fio rows have non-zero durability_every_ops")
stop_if_not(field_checks$bad_fsync_durability_rows == 0, "Some fsync rows do not agree with the parsed durability fields")
stop_if_not(field_checks$bad_fdatasync_durability_rows == 0, "Some fdatasync rows do not agree with the parsed durability fields")
stop_if_not(field_checks$valid_with_error == 0, "Some valid fio rows still carry a non-zero error code")
stop_if_not(field_checks$invalid_without_error == 0, "Some invalid fio rows have zero error code")

failure_consistency <- dbGetQuery(con, "
select
  (select count(*) from fio where not valid_measurement) as invalid_rows,
  (select count(*) from failures) as failure_rows,
  coalesce(sum(case when fio_error = 0 then 1 else 0 end), 0) as failure_rows_with_zero_error
from failures
")

stop_if_not(failure_consistency$invalid_rows == failure_consistency$failure_rows, "Failure CSV does not match invalid fio rows")
stop_if_not(failure_consistency$failure_rows_with_zero_error == 0, "Failure CSV contains zero-error rows")

message("CSV counts")
print(csv_counts)

message("Scenarios")
print(dbGetQuery(con, "
select scenario_name, benchmark_machine_type, access_mode, os_tuning, storage_targets_raw,
       storage_local_filesystem, storage_block_filesystem, count(*) as n
from scenarios
group by 1, 2, 3, 4, 5, 6, 7
order by 1, 2, 3, 4, 5, 6, 7
"))

message("Benchmarks by target and workload")
print(dbGetQuery(con, "
select storage_target, storage_target_filesystem, benchmark_tool, benchmark_rw_mode, io_engine, block_size,
       durability_mode, durability_every_ops, count(*) as n
from benchmarks
group by 1, 2, 3, 4, 5, 6, 7, 8
order by 1, 2, 3, 4, 5, 6, 7, 8
"))

message("Valid fio measurements")
print(dbGetQuery(con, "
select storage_target, storage_target_filesystem, benchmark_rw_mode, io_engine, block_size,
       durability_mode, durability_every_ops, valid_measurement, count(*) as n
from fio
group by 1, 2, 3, 4, 5, 6, 7, 8
order by 1, 2, 3, 4, 5, 6, 7, 8
"))

message("Throughput and latency by target")
print(dbGetQuery(con, "
select storage_target,
       round(avg(primary_bw_bytes_per_sec) / 1024.0 / 1024.0, 2) as avg_mib_per_sec,
       round(avg(primary_clat_p99_ns) / 1000.0, 2) as avg_p99_us,
       round(avg(primary_clat_p50_ns) / 1000.0, 2) as avg_p50_us
from fio
where valid_measurement
group by 1
order by 1
"))

message("Failures")
print(dbGetQuery(con, "
select benchmark_name, storage_target, repetition, fio_error, failure_reason
from failures
order by benchmark_name, storage_target, repetition
"))

message(sprintf("Validation OK: %s", results_dir))
