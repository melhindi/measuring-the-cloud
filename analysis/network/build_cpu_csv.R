#!/usr/bin/env Rscript
# Summarise the mpstat samples into one row per (repetition, host, CPU).
#
# usage: build_cpu_csv.R <result-id|all> [out-dir]
#
# %steal is why this exists. On stackit-ladder-05 the busy_poll arm and its
# standard control differed in the treatment and also in how contended their
# server hosts were -- 8.1% mean steal against 18.4%, with 47 of 51 standard
# repetitions above 5%. sockperf under-load has the server echo every message,
# so a descheduled server vCPU lands directly in the round-trip time being
# measured. That is large enough to account for a headline result on its own.
#
# It was found by hand, in a log file nothing parses. Every mpstat.log in this
# repository has always been collected and never read; the 11.5/6.3/0.0% softirq
# comparison across providers was assembled by grepping them one at a time. A
# confound that can only be found by hand will eventually not be found, so the
# fields that decide whether a measurement is trustworthy belong in the dataset
# next to the measurement.
#
# Means over the repetition, not percentiles. mpstat is sampled once a second
# against repetitions of a few tens of seconds, so there are too few samples for
# a percentile to mean anything; the mean plus the max is what that sample count
# supports.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: build_cpu_csv.R <result-id|all> [out-dir]")
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

# mpstat -P ALL prints: time CPU %usr %nice %sys %iowait %irq %soft %steal
# %guest %gnice %idle. The header repeats whenever the terminal would scroll and
# the "all" aggregate row is interleaved with the per-CPU rows, so rows are
# selected by shape -- 12 fields, a numeric CPU column -- rather than by
# position. A 12-hour clock locale would shift every column by one; the numeric
# check on the CPU field is what catches that rather than silently reading %usr
# as the CPU number.
MPSTAT_FIELDS <- 12L

parse_mpstat <- function(path) {
  lines <- readLines(path, warn = FALSE)
  rows <- list()
  for (ln in lines) {
    f <- strsplit(trimws(ln), "[[:space:]]+")[[1]]
    if (length(f) != MPSTAT_FIELDS) next
    if (is.na(suppressWarnings(as.integer(f[[2]])))) next   # skips "all" and headers
    vals <- suppressWarnings(as.numeric(f[3:12]))
    if (anyNA(vals)) next
    rows[[length(rows) + 1]] <- c(cpu = as.integer(f[[2]]), vals)
  }
  if (length(rows) == 0) return(NULL)
  m <- do.call(rbind, rows)
  colnames(m) <- c("cpu", "usr", "nice", "sys", "iowait", "irq", "soft",
                   "steal", "guest", "gnice", "idle")
  df <- as.data.frame(m)
  agg <- do.call(rbind, lapply(split(df, df$cpu), function(g) {
    data.frame(
      cpu = g$cpu[[1]],
      samples = nrow(g),
      usr_pct = round(mean(g$usr), 2),
      sys_pct = round(mean(g$sys), 2),
      irq_pct = round(mean(g$irq), 2),
      softirq_pct = round(mean(g$soft), 2),
      steal_pct = round(mean(g$steal), 2),
      steal_pct_max = round(max(g$steal), 2),
      idle_pct = round(mean(g$idle), 2),
      stringsAsFactors = FALSE
    )
  }))
  rownames(agg) <- NULL
  agg
}

all_rows <- list()
for (run_dir in run_dirs) {
  run_id <- basename(run_dir)
  logs <- list.files(run_dir, pattern = "^mpstat\\.log$", recursive = TRUE, full.names = TRUE)
  for (log_path in logs) {
    rel <- substring(log_path, nchar(run_dir) + 2L)
    parts <- strsplit(rel, "/", fixed = TRUE)[[1]]
    if (length(parts) < 6) next
    parsed <- tryCatch(parse_mpstat(log_path), error = function(e) NULL)
    if (is.null(parsed)) next
    parsed$run_id <- run_id
    parsed$scenario_name <- parts[[1]]
    parsed$benchmark_name <- parts[[length(parts) - 4L]]
    parsed$repetition <- suppressWarnings(as.integer(sub("^rep-", "", parts[[length(parts) - 3L]])))
    parsed$role <- parts[[length(parts) - 2L]]
    all_rows[[length(all_rows) + 1]] <- parsed
  }
}

if (length(all_rows) == 0) {
  message("no mpstat samples found (telemetry off, or sysstat absent)")
  quit(status = 0)
}

out <- do.call(rbind, all_rows)
out <- out[, c("run_id", "scenario_name", "benchmark_name", "repetition", "role", "cpu",
               "samples", "usr_pct", "sys_pct", "irq_pct", "softirq_pct",
               "steal_pct", "steal_pct_max", "idle_pct")]
out <- out[order(out$run_id, out$scenario_name, out$benchmark_name,
                 out$repetition, out$role, out$cpu), ]

out_path <- file.path(out_dir, "network_cpu.csv")
write.csv(out, out_path, row.names = FALSE)
cat(sprintf("Wrote %s\n", out_path))
cat(sprintf("rows=%d  reps=%d  rows_over_5pct_steal=%d  max_steal=%.1f%%\n",
            nrow(out),
            length(unique(paste(out$run_id, out$scenario_name, out$benchmark_name, out$repetition))),
            sum(out$steal_pct > 5), max(out$steal_pct_max)))
