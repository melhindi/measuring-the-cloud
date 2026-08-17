#!/usr/bin/env Rscript
# Extract the sockperf socket's buffer and drop counters from the ss telemetry.
#
# usage: build_socket_csv.R <result-id|all> [out-dir]
#
# One row per (repetition, host). The columns that matter:
#
#   rb_bytes        the receive buffer the socket ACTUALLY got, from skmem rb.
#                   This is the column that makes SOCKPERF_BUFFER_SIZE
#                   falsifiable, and it exists because the study spent a whole
#                   arm on a buffer that never changed: the network-throughput
#                   profile raises net.core.rmem_max 630x, from 212992 to
#                   134217728, and on stackit-ladder-05 the sockperf socket
#                   measured rb 212992 under BOTH profiles. rmem_max is a
#                   ceiling on what an application may request; UDP does not
#                   autotune the way TCP does, so it takes rmem_default, which
#                   the profile never touched. The conclusion that "a 630x
#                   buffer did not reduce UDP loss" tested nothing.
#
#                   The kernel computes rb as 2 * min(request, rmem_max), so a
#                   request above the ceiling is silently clamped -- another
#                   reason to read the effective value rather than the asked-for
#                   one.
#
#   drops_delta     skmem d, the per-socket drop count, within the repetition.
#                   The socket-local counterpart to UdpRcvbufErrors from nstat.
#   recv_queue_max  skmem r, the deepest the receive queue was seen. A queue
#                   that never approaches rb was not buffer limited, whatever
#                   else went wrong.
#
# The port is read from benchmark.env rather than assumed, because ss -uanm
# reports every UDP socket on the host -- systemd-resolved on :53, DHCP on :68 --
# and matching on the buffer value alone would silently read whichever socket
# happened to be listed first. That mistake was made by hand before this file
# existed; it gave the right answer only because every socket on the box had an
# identical default.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: build_socket_csv.R <result-id|all> [out-dir]")
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

# ss -uanm prints the socket line, then its skmem on the following line:
#   UNCONN 0 0  0.0.0.0:11111  0.0.0.0:*
#        skmem:(r0,rb212992,t0,tb212992,f0,w0,o0,bl0,d1275528)
parse_ss_udp <- function(path, port) {
  lines <- readLines(path, warn = FALSE)
  port_pat <- sprintf(":%s\\b", port)
  rb <- integer(0); rq <- numeric(0); dr <- numeric(0)
  pending <- FALSE
  for (ln in lines) {
    if (grepl("^\\s*skmem:", ln)) {
      if (!pending) next
      pending <- FALSE
      f <- function(key) {
        m <- regmatches(ln, regexpr(sprintf("[,(]%s([0-9]+)", key), ln))
        if (length(m) == 0) return(NA_real_)
        as.numeric(sub(sprintf("^[,(]%s", key), "", m))
      }
      rb <- c(rb, f("rb")); rq <- c(rq, f("r")); dr <- c(dr, f("d"))
      next
    }
    # A socket line for our port arms the next skmem line.
    pending <- grepl(port_pat, ln)
  }
  if (length(rb) == 0) return(NULL)
  data.frame(
    samples = length(rb),
    rb_bytes = suppressWarnings(max(rb, na.rm = TRUE)),
    recv_queue_max = suppressWarnings(max(rq, na.rm = TRUE)),
    # Cumulative for the socket's lifetime, and the socket is created per
    # repetition, so last-minus-first is the repetition's own drops.
    drops_delta = suppressWarnings(max(dr, na.rm = TRUE) - min(dr, na.rm = TRUE)),
    drops_total = suppressWarnings(max(dr, na.rm = TRUE)),
    stringsAsFactors = FALSE
  )
}

read_port <- function(bench_dir) {
  f <- file.path(bench_dir, "benchmark.env")
  if (!file.exists(f)) return(NA_character_)
  ln <- grep("SOCKPERF_PORT", readLines(f, warn = FALSE), value = TRUE)
  if (length(ln) == 0) return(NA_character_)
  gsub("[^0-9]", "", ln[[1]])
}

all_rows <- list()
for (run_dir in run_dirs) {
  run_id <- basename(run_dir)
  logs <- list.files(run_dir, pattern = "^ss-udp\\.log$", recursive = TRUE, full.names = TRUE)
  for (log_path in logs) {
    rel <- substring(log_path, nchar(run_dir) + 2L)
    parts <- strsplit(rel, "/", fixed = TRUE)[[1]]
    if (length(parts) < 6) next
    role <- parts[[length(parts) - 2L]]
    rep <- parts[[length(parts) - 3L]]
    benchmark <- parts[[length(parts) - 4L]]
    scenario <- parts[[1]]
    bench_dir <- file.path(run_dir, scenario, "benchmarks", benchmark)
    port <- read_port(bench_dir)
    if (is.na(port) || !nzchar(port)) next
    parsed <- tryCatch(parse_ss_udp(log_path, port), error = function(e) NULL)
    if (is.null(parsed)) next
    parsed$run_id <- run_id
    parsed$scenario_name <- scenario
    parsed$benchmark_name <- benchmark
    parsed$repetition <- suppressWarnings(as.integer(sub("^rep-", "", rep)))
    parsed$role <- role
    parsed$port <- port
    all_rows[[length(all_rows) + 1]] <- parsed
  }
}

if (length(all_rows) == 0) {
  message("no ss-udp samples found for a sockperf port (telemetry off, TCP-only run, or older result set)")
  quit(status = 0)
}

out <- do.call(rbind, all_rows)
out <- out[, c("run_id", "scenario_name", "benchmark_name", "repetition", "role", "port",
               "samples", "rb_bytes", "recv_queue_max", "drops_delta", "drops_total")]
out <- out[order(out$run_id, out$scenario_name, out$benchmark_name, out$repetition, out$role), ]

out_path <- file.path(out_dir, "network_socket.csv")
write.csv(out, out_path, row.names = FALSE)
cat(sprintf("Wrote %s\n", out_path))
cat(sprintf("rows=%d  distinct rb_bytes=%s  rows_with_drops=%d\n",
            nrow(out),
            paste(sort(unique(out$rb_bytes)), collapse = ","),
            sum(out$drops_delta > 0, na.rm = TRUE)))
