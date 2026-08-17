#!/usr/bin/env Rscript
# Turn the softnet_stat telemetry samples into one row per (repetition, host, CPU).
#
# usage: build_softnet_csv.R <result-id|all> [out-dir]
#
# Separate from build_csv.R on purpose. That script emits one row per benchmark
# repetition; this granularity is per CPU within a repetition, so folding it in
# would either multiply every measurement row by the core count or force an
# aggregation that throws away the per-core detail this exists to show. Joining
# is one line of SQL on (run_id, scenario_name, benchmark_name, repetition).
#
# Why this file exists at all. The claim that AWS and GCP keep NAPI in polling
# mode while STACKIT pays an interrupt per packet was an inference from the
# shape of a latency curve. time_squeeze is the counter that tests it directly:
# it increments when a NAPI poll exhausted netdev_budget or its time slice with
# work still queued. Collected but unparsed, it would be readable only by hand
# across several hundred directories, which is the same "measured but not in the
# dataset" gap that left netdev_budget unverifiable for the whole study.
#
# Deltas, not absolutes. The counters are cumulative since boot, so a raw value
# says how busy the host has been since it booted, not what this repetition did.
# Every column here is last-sample minus first-sample within one repetition.
#
# A repetition with fewer than two samples yields no row: one sample cannot
# produce a delta, and emitting a zero would be indistinguishable from a genuine
# idle core.
suppressWarnings(suppressMessages({
  invisible(NULL)
}))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: build_softnet_csv.R <result-id|all> [out-dir]")
result_id <- args[[1]]

script_dir <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
repo_root <- normalizePath(file.path(script_dir, "..", ".."))
artifacts_root <- file.path(repo_root, "artifacts", "network")

run_dirs <- if (identical(result_id, "all")) {
  sort(list.dirs(artifacts_root, full.names = TRUE, recursive = FALSE))
} else {
  d <- file.path(artifacts_root, result_id)
  if (!dir.exists(d)) stop(sprintf("no such run directory: %s", d))
  d
}

out_dir <- if (length(args) >= 2) args[[2]] else file.path(repo_root, "analysis", "network", result_id)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# The kernel writes one whitespace-separated line of %08x per CPU, in CPU order,
# with no header (net/core/net-procfs.c, softnet_seq_show). Column 13 is the CPU
# index, which is checked against the line's position rather than trusted: a
# kernel that changes the layout must fail loudly here rather than silently
# relabel counters. Columns 4-9 are hard-coded zeros in the kernel and are not
# read.
SOFTNET_COLS <- c(
  processed = 1L, dropped = 2L, time_squeeze = 3L,
  received_rps = 10L, flow_limit_count = 11L, backlog_len = 12L, cpu_index = 13L
)

parse_softnet_log <- function(path) {
  lines <- readLines(path, warn = FALSE)
  if (length(lines) == 0) return(NULL)
  samples <- list()
  current <- NULL
  for (ln in lines) {
    ln <- trimws(ln)
    if (!nzchar(ln)) next
    if (startsWith(ln, "#")) {
      # A new timestamp closes the previous sample.
      if (!is.null(current) && length(current) > 0) samples[[length(samples) + 1]] <- current
      current <- list()
      next
    }
    if (is.null(current)) next
    fields <- strsplit(ln, "[[:space:]]+")[[1]]
    if (length(fields) < max(SOFTNET_COLS)) next
    # as.numeric on an "0x" string rather than strtoi: strtoi returns an R
    # integer, which caps at 2^31-1, and processed routinely passes that on a
    # host that has been up a while -- it returned NA there, silently turning a
    # busy CPU into a missing measurement. Doubles hold a u32 exactly.
    vals <- suppressWarnings(as.numeric(paste0("0x", fields)))
    if (anyNA(vals[unname(SOFTNET_COLS)])) next
    current[[length(current) + 1]] <- vals
  }
  if (!is.null(current) && length(current) > 0) samples[[length(samples) + 1]] <- current
  if (length(samples) < 2) return(NULL)

  first <- samples[[1]]
  last <- samples[[length(samples)]]
  n_cpu <- min(length(first), length(last))
  if (n_cpu < 1) return(NULL)

  rows <- lapply(seq_len(n_cpu), function(i) {
    f <- first[[i]]; l <- last[[i]]
    if (f[[SOFTNET_COLS[["cpu_index"]]]] != (i - 1L) ||
        l[[SOFTNET_COLS[["cpu_index"]]]] != (i - 1L)) {
      stop(sprintf("%s: CPU index column does not match line position; softnet_stat layout changed", path))
    }
    # Counters are u32 and can wrap. A negative delta is a wrap, not a decrease.
    d <- function(key) {
      delta <- l[[SOFTNET_COLS[[key]]]] - f[[SOFTNET_COLS[[key]]]]
      if (!is.na(delta) && delta < 0) delta <- delta + 2^32
      delta
    }
    data.frame(
      cpu = i - 1L,
      samples = length(samples),
      processed_delta = d("processed"),
      dropped_delta = d("dropped"),
      time_squeeze_delta = d("time_squeeze"),
      received_rps_delta = d("received_rps"),
      flow_limit_delta = d("flow_limit_count"),
      # Not a counter: an instantaneous queue depth at the last sample.
      backlog_len_last = l[[SOFTNET_COLS[["backlog_len"]]]],
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

all_rows <- list()
for (run_dir in run_dirs) {
  run_id <- basename(run_dir)
  logs <- list.files(run_dir, pattern = "^softnet_stat\\.log$",
                     recursive = TRUE, full.names = TRUE)
  for (log_path in logs) {
    # <scenario>/benchmarks/<benchmark>/rep-N/<role>/telemetry/softnet_stat.log
    rel <- substring(log_path, nchar(run_dir) + 2L)
    parts <- strsplit(rel, "/", fixed = TRUE)[[1]]
    if (length(parts) < 6) next
    role <- parts[[length(parts) - 2L]]
    rep <- parts[[length(parts) - 3L]]
    benchmark <- parts[[length(parts) - 4L]]
    scenario <- parts[[1]]
    parsed <- tryCatch(parse_softnet_log(log_path), error = function(e) {
      message(sprintf("  skipping %s: %s", rel, conditionMessage(e)))
      NULL
    })
    if (is.null(parsed)) next
    parsed$run_id <- run_id
    parsed$scenario_name <- scenario
    parsed$benchmark_name <- benchmark
    parsed$repetition <- suppressWarnings(as.integer(sub("^rep-", "", rep)))
    parsed$role <- role
    all_rows[[length(all_rows) + 1]] <- parsed
  }
}

if (length(all_rows) == 0) {
  message("no softnet_stat samples found (telemetry off, or runs predate its collection)")
  quit(status = 0)
}

out <- do.call(rbind, all_rows)
out <- out[, c("run_id", "scenario_name", "benchmark_name", "repetition", "role", "cpu",
               "samples", "processed_delta", "dropped_delta", "time_squeeze_delta",
               "received_rps_delta", "flow_limit_delta", "backlog_len_last")]
out <- out[order(out$run_id, out$scenario_name, out$benchmark_name, out$repetition,
                 out$role, out$cpu), ]

out_path <- file.path(out_dir, "network_softnet.csv")
write.csv(out, out_path, row.names = FALSE)
cat(sprintf("Wrote %s\n", out_path))
cat(sprintf("rows=%d  reps=%d  hosts_with_time_squeeze=%d\n",
            nrow(out),
            length(unique(paste(out$run_id, out$scenario_name, out$benchmark_name, out$repetition))),
            sum(out$time_squeeze_delta > 0)))
