#!/usr/bin/env Rscript

`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a
}

empty_df <- function(cols) {
  as.data.frame(
    setNames(lapply(cols, function(x) character(0)), cols),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

ensure_schema <- function(df, cols) {
  if (is.null(df) || !is.data.frame(df) || ncol(df) == 0) {
    return(empty_df(cols))
  }
  missing_cols <- setdiff(cols, names(df))
  for (col in missing_cols) df[[col]] <- NA
  df[, cols, drop = FALSE]
}

bind_rows_with_schema <- function(df_list, cols) {
  df_list <- df_list[!vapply(df_list, is.null, logical(1))]
  df_list <- df_list[vapply(df_list, is.data.frame, logical(1))]
  if (length(df_list) == 0) return(empty_df(cols))
  df_list <- lapply(df_list, ensure_schema, cols = cols)
  out <- do.call(rbind, df_list)
  rownames(out) <- NULL
  out
}

safe_write_csv <- function(df, path, cols) {
  # See analysis/network/build_csv.R: R picks fixed or scientific notation by
  # whichever is shorter, so a single column can mix '400000' and '4e+05'.
  # Force fixed notation, and restore the caller's setting afterwards.
  old <- options(scipen = 999)
  on.exit(options(old), add = TRUE)
  write.csv(ensure_schema(df, cols), path, row.names = FALSE, na = "")
}

detect_repo_root <- function() {
  file_arg <- grep("^--file=", commandArgs(), value = TRUE)
  if (length(file_arg) > 0) {
    script_path <- normalizePath(sub("^--file=", "", file_arg[[1]]))
    return(normalizePath(file.path(dirname(script_path), "..", "..")))
  }
  normalizePath(getwd())
}

to_num <- function(x) suppressWarnings(as.numeric(x))

scalar_value <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA)
  if (is.list(x)) return(scalar_value(x[[1]]))
  x[[1]]
}

scalar_char <- function(x) {
  v <- scalar_value(x)
  if (is.na(v)) NA_character_ else as.character(v)
}

scalar_num <- function(x) {
  v <- scalar_value(x)
  if (is.na(v)) NA_real_ else to_num(v)
}

normalize_env_value <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  x <- as.character(x[[1]])
  x <- trimws(x)
  x <- sub("^export[[:space:]]+", "", x, perl = TRUE)
  x <- sub("[[:space:]]+#.*$", "", x, perl = TRUE)
  x <- trimws(x)
  x <- gsub('^"|"$', "", x)
  x <- gsub("^'|'$", "", x)
  x <- gsub("\\\\ ", " ", x, perl = TRUE)
  x
}

read_env_file <- function(path) {
  if (!file.exists(path)) return(setNames(character(0), character(0)))
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nzchar(lines) & !grepl("^#", lines)]
  lines <- sub("^export[[:space:]]+", "", lines, perl = TRUE)
  lines <- lines[grepl("=", lines, fixed = TRUE)]
  if (length(lines) == 0) return(setNames(character(0), character(0)))
  keys <- sub("=.*$", "", lines)
  vals <- sub("^[^=]*=", "", lines)
  vals <- vapply(vals, normalize_env_value, character(1))
  stats::setNames(vals, keys)
}

env_get <- function(env, key, default = NA_character_) {
  if (is.null(env) || length(env) == 0 || is.null(names(env)) || !(key %in% names(env))) return(default)
  value <- env[[key]]
  if (is.null(value) || length(value) == 0 || is.na(value) || !nzchar(value)) default else value
}

# Overlay supplementary env files onto scenario.env without letting them shadow
# it; matches analysis/network/build_csv.R.
merge_env <- function(base_env, ...) {
  for (extra in list(...)) {
    if (length(extra) == 0) next
    new_keys <- setdiff(names(extra), names(base_env))
    if (length(new_keys) > 0) base_env <- c(base_env, extra[new_keys])
  }
  base_env
}

infer_storage_filesystem <- function(explicit_value, scenario_name, mount_point = NA_character_) {
  if (!is.na(explicit_value) && nzchar(explicit_value)) return(explicit_value)
  scenario_name <- tolower(scenario_name %||% "")
  mount_point <- if (is.na(mount_point)) "" else mount_point

  if (grepl("ext4", scenario_name, fixed = TRUE)) return("ext4")
  if (grepl("xfs", scenario_name, fixed = TRUE)) return("xfs")
  if (grepl("raw", scenario_name, fixed = TRUE)) return("raw")
  if (nzchar(mount_point)) return("xfs")
  if (grepl("standard", scenario_name, fixed = TRUE)) return("xfs")
  NA_character_
}

parse_size_bytes <- function(x) {
  if (is.null(x) || is.na(x) || !nzchar(x)) return(NA_real_)
  x <- toupper(trimws(as.character(x)))
  m <- regexec("^([0-9.]+)([KMGTP]?)$", x, perl = TRUE)
  r <- regmatches(x, m)[[1]]
  if (length(r) < 2) return(to_num(x))
  value <- to_num(r[[2]])
  suffix <- r[[3]] %||% ""
  mult <- switch(suffix, K = 1024, M = 1024^2, G = 1024^3, T = 1024^4, P = 1024^5, 1)
  value * mult
}

detect_provider <- function(scenario_name) {
  if (grepl("^stackit[_-]", scenario_name)) return("stackit")
  if (grepl("^aws[_-]", scenario_name)) return("aws")
  NA_character_
}

derive_block_volume_performance_class <- function(provider, scenario_name, benchmark_machine_type, scenario_env = NULL) {
  if (identical(provider, "aws")) {
    block_type <- env_get(scenario_env, "BLOCK_VOLUME_TYPE")
    block_iops <- env_get(scenario_env, "BLOCK_VOLUME_IOPS")
    block_throughput <- env_get(scenario_env, "BLOCK_VOLUME_THROUGHPUT_MBPS")
    if (is.na(block_type) || !nzchar(block_type)) return(NA_character_)
    label <- tolower(block_type)
    if (!is.na(block_iops) && nzchar(block_iops)) {
      label <- paste0(label, "_", block_iops, "iops")
    }
    if (!is.na(block_throughput) && nzchar(block_throughput)) {
      label <- paste0(label, "_", block_throughput, "mbps")
    }
    return(label)
  }
  if (!is.null(scenario_name) && grepl("perf[0-9]+", scenario_name)) {
    perf <- sub(".*(perf[0-9]+).*", "\\1", scenario_name)
    return(paste0("storage_premium_", perf))
  }
  if (identical(benchmark_machine_type, "g2a.30d")) return("storage_premium_perf6")
  if (identical(benchmark_machine_type, "g2a.8d")) return("storage_premium_perf12")
  NA_character_
}

stackit_block_profile_details <- function(perf_class) {
  if (is.na(perf_class) || !nzchar(perf_class)) {
    return(list(type = NA_character_, iops = NA_real_, throughput_mbps = NA_real_, performance_class = NA_character_))
  }
  profile_map <- list(
    storage_premium_perf0 = list(type = "stackit-block", iops = 120, throughput_mbps = 25),
    storage_premium_perf1 = list(type = "stackit-block", iops = 500, throughput_mbps = 50),
    storage_premium_perf2 = list(type = "stackit-block", iops = 1000, throughput_mbps = 100),
    storage_premium_perf4 = list(type = "stackit-block", iops = 2000, throughput_mbps = 150),
    storage_premium_perf6 = list(type = "stackit-block", iops = 5000, throughput_mbps = 200),
    storage_premium_perf8 = list(type = "stackit-block", iops = 10000, throughput_mbps = 250),
    storage_premium_perf10 = list(type = "stackit-block", iops = 15000, throughput_mbps = 300),
    storage_premium_perf12 = list(type = "stackit-block", iops = 20000, throughput_mbps = 350),
    storage_premium_perf13 = list(type = "stackit-block", iops = 20000, throughput_mbps = 700),
    storage_premium_perf14 = list(type = "stackit-block", iops = 25000, throughput_mbps = 400),
    storage_premium_perf15 = list(type = "stackit-block", iops = 25000, throughput_mbps = 800),
    storage_premium_perf16 = list(type = "stackit-block", iops = 30000, throughput_mbps = 450),
    storage_premium_perf17 = list(type = "stackit-block", iops = 30000, throughput_mbps = 900),
    storage_premium_perf18 = list(type = "stackit-block", iops = 35000, throughput_mbps = 500),
    storage_premium_perf19 = list(type = "stackit-block", iops = 35000, throughput_mbps = 1000),
    storage_premium_perf20 = list(type = "stackit-block", iops = 40000, throughput_mbps = 550),
    storage_premium_perf21 = list(type = "stackit-block", iops = 40000, throughput_mbps = 1100),
    storage_premium_perf29 = list(type = "stackit-block", iops = 60000, throughput_mbps = 1500)
  )
  c(profile_map[[perf_class]] %||% list(type = "stackit-block", iops = NA_real_, throughput_mbps = NA_real_), list(performance_class = perf_class))
}

block_profile_metadata <- function(provider, scenario_env, perf_class) {
  if (identical(provider, "aws")) {
    scenario_name <- env_get(scenario_env, "SCENARIO_NAME")
    if (!exists(".scenario_source_cache", envir = .GlobalEnv, inherits = FALSE)) {
      assign(".scenario_source_cache", new.env(parent = emptyenv()), envir = .GlobalEnv)
    }
    scenario_source_cache <- get(".scenario_source_cache", envir = .GlobalEnv, inherits = FALSE)
    if (!is.na(scenario_name) && nzchar(scenario_name)) {
      if (!exists(scenario_name, envir = scenario_source_cache, inherits = FALSE)) {
        scenario_path <- Sys.glob(file.path(repo_root, "storage", "scenarios", "aws", "*", paste0(scenario_name, ".sh")))
        scenario_env_from_source <- if (length(scenario_path) > 0) {
          read_env_file(scenario_path[[1]])
        } else {
          setNames(character(0), character(0))
        }
        assign(scenario_name, scenario_env_from_source, envir = scenario_source_cache)
      }
      scenario_source_env <- get(scenario_name, envir = scenario_source_cache, inherits = FALSE)
      scenario_env <- c(scenario_env, scenario_source_env[setdiff(names(scenario_source_env), names(scenario_env))])
      if (length(scenario_source_env) > 0) {
        scenario_env[names(scenario_source_env)] <- scenario_source_env
      }
    }
    block_type <- env_get(scenario_env, "BLOCK_VOLUME_TYPE")
    block_iops <- to_num(env_get(scenario_env, "BLOCK_VOLUME_IOPS"))
    block_throughput <- to_num(env_get(scenario_env, "BLOCK_VOLUME_THROUGHPUT_MBPS"))
    block_class <- if (!is.na(block_type) && nzchar(block_type)) {
      label <- tolower(block_type)
      if (!is.na(block_iops)) label <- paste0(label, "_", format(block_iops, scientific = FALSE, trim = TRUE), "iops")
      if (!is.na(block_throughput)) label <- paste0(label, "_", format(block_throughput, scientific = FALSE, trim = TRUE), "mbps")
      label
    } else {
      NA_character_
    }
    return(list(
      type = block_type,
      iops = block_iops,
      throughput_mbps = block_throughput,
      performance_class = block_class
    ))
  }
  if (identical(provider, "stackit")) {
    return(stackit_block_profile_details(perf_class))
  }
  list(type = NA_character_, iops = NA_real_, throughput_mbps = NA_real_, performance_class = NA_character_)
}

access_pattern_for_rw <- function(rw) {
  if (grepl("^rand", rw)) return("random")
  if (rw %in% c("read", "write")) return("sequential")
  NA_character_
}

direction_for_rw <- function(rw) {
  if (grepl("read$", rw)) return("read")
  if (grepl("write$", rw)) return("write")
  NA_character_
}

first_line <- function(path) {
  if (!file.exists(path)) return(NA_character_)
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0) NA_character_ else lines[[1]]
}

read_text_file <- function(path) {
  if (!file.exists(path)) return(NA_character_)
  lines <- readLines(path, warn = FALSE)
  if (length(lines) == 0) return(NA_character_)
  paste(lines, collapse = "\n")
}

read_fio_doc <- function(path) {
  if (!file.exists(path)) return(NULL)
  txt <- paste(readLines(path, warn = FALSE), collapse = "\n")
  start <- regexpr("{", txt, fixed = TRUE)[[1]]
  end <- max(unlist(gregexpr("}", txt, fixed = TRUE)))
  if (is.na(start) || start < 1 || is.na(end) || end < start) return(NULL)
  json_txt <- substr(txt, start, end)
  tryCatch(jsonlite::fromJSON(json_txt, simplifyVector = FALSE), error = function(e) NULL)
}

get_path <- function(x, path, default = NA) {
  cur <- x
  for (part in path) {
    if (is.null(cur) || !is.list(cur) || is.null(cur[[part]])) return(default)
    cur <- cur[[part]]
  }
  if (is.null(cur) || length(cur) == 0) return(default)
  if (is.list(cur) && !is.data.frame(cur)) return(cur)
  cur[[1]]
}

percentile_value <- function(clat, pct_key) {
  if (is.null(clat) || !is.list(clat)) return(NA_real_)
  pct <- clat[["percentile"]]
  if (is.null(pct) || !is.list(pct) || is.null(pct[[pct_key]])) return(NA_real_)
  to_num(scalar_value(pct[[pct_key]]))
}

durability_mode_from_counts <- function(fsync_count, fdatasync_count) {
  fsync_count <- to_num(fsync_count)
  fdatasync_count <- to_num(fdatasync_count)
  if (!is.na(fsync_count) && fsync_count > 0) return("fsync")
  if (!is.na(fdatasync_count) && fdatasync_count > 0) return("fdatasync")
  "none"
}

durability_every_ops_from_counts <- function(fsync_count, fdatasync_count) {
  mode <- durability_mode_from_counts(fsync_count, fdatasync_count)
  if (identical(mode, "fsync")) return(to_num(fsync_count))
  if (identical(mode, "fdatasync")) return(to_num(fdatasync_count))
  0
}

scenario_fields <- c(
  "run_id", "scenario_name", "provider", "access_mode", "os_tuning", "benchmark_host",
  "benchmark_private_ip", "ssh_user", "benchmark_cpu_list", "benchmark_machine_type",
  "benchmark_availability_zone", "block_volume_performance_class", "block_volume_type",
  "block_volume_iops", "block_volume_throughput_mbps", "storage_targets_raw", "storage_root_device",
  "storage_local_device", "storage_local_mount", "storage_local_filesystem",
  "storage_block_device", "storage_block_mount", "storage_block_filesystem",
  "cpu_idle_pinning_requested", "cpu_idle_pinning_supported",
  "cpu_idle_pinning_verified", "cpu_idle_pinning_reason", "cpu_idle_driver",
  "cpu_idle_deep_entries_delta", "cpufreq_driver", "cpufreq_governor",
  "kernel_release",
  "scenario_source_file", "storage_env_file"
)

benchmark_fields <- c(
  scenario_fields,
  "benchmark_name", "benchmark_source_file", "storage_target", "storage_target_mount",
  "storage_target_device", "storage_target_filesystem", "benchmark_tool",
  "benchmark_rw_mode", "access_pattern", "direction",
  "io_engine", "block_size", "block_size_bytes", "iodepth", "numjobs", "runtime_sec", "direct",
  "group_reporting", "time_based", "fio_size", "fio_fsync", "fio_fdatasync",
  "durability_mode", "durability_every_ops", "repetitions_expected", "cooldown_sec"
)

fio_fields <- c(
  benchmark_fields,
  "repetition", "fio_json_file", "fio_log_file", "fio_cmd_file", "fio_version", "fio_timestamp",
  "fio_timestamp_ms", "fio_time", "fio_jobname", "fio_error", "fio_job_runtime_ms", "fio_elapsed_sec",
  "fio_eta", "sync_total_ios", "sync_lat_mean_ns", "sync_lat_p50_ns", "sync_lat_p95_ns",
  "sync_lat_p99_ns", "sync_lat_p999_ns", "sync_lat_p9999_ns", "sync_lat_min_ns",
  "sync_lat_max_ns", "sync_lat_stddev_ns", "sync_lat_samples", "usr_cpu", "sys_cpu", "ctx", "majf", "minf", "iodepth_level", "iodepth_submit",
  "iodepth_complete", "latency_ns", "latency_us", "latency_ms", "latency_depth", "latency_target",
  "latency_percentile", "latency_window", "read_io_bytes", "read_bw_bytes", "read_bw_kib_per_sec",
  "read_bw_min_kib_per_sec", "read_bw_max_kib_per_sec", "read_bw_mean_kib_per_sec",
  "read_bw_dev_kib_per_sec", "read_bw_samples", "read_iops", "read_iops_min", "read_iops_max",
  "read_iops_mean", "read_iops_stddev", "read_iops_samples", "read_runtime_ms", "read_total_ios",
  "read_short_ios", "read_drop_ios", "read_slat_mean_ns", "read_slat_min_ns", "read_slat_max_ns",
  "read_slat_stddev_ns", "read_slat_samples", "read_clat_mean_ns", "read_clat_p50_ns",
  "read_clat_p95_ns", "read_clat_p99_ns", "read_clat_p999_ns", "read_clat_p9999_ns",
  "read_clat_min_ns", "read_clat_max_ns", "read_clat_stddev_ns", "read_clat_samples",
  "read_lat_mean_ns", "read_lat_min_ns", "read_lat_max_ns", "read_lat_stddev_ns", "read_lat_samples",
  "write_io_bytes", "write_bw_bytes", "write_bw_kib_per_sec", "write_bw_min_kib_per_sec",
  "write_bw_max_kib_per_sec", "write_bw_mean_kib_per_sec", "write_bw_dev_kib_per_sec",
  "write_bw_samples", "write_iops", "write_iops_min", "write_iops_max", "write_iops_mean",
  "write_iops_stddev", "write_iops_samples", "write_runtime_ms", "write_total_ios",
  "write_short_ios", "write_drop_ios", "write_slat_mean_ns", "write_slat_min_ns",
  "write_slat_max_ns", "write_slat_stddev_ns", "write_slat_samples", "write_clat_mean_ns",
  "write_clat_p50_ns", "write_clat_p95_ns", "write_clat_p99_ns", "write_clat_p999_ns",
  "write_clat_p9999_ns", "write_clat_min_ns", "write_clat_max_ns", "write_clat_stddev_ns",
  "write_clat_samples", "write_lat_mean_ns", "write_lat_min_ns", "write_lat_max_ns",
  "write_lat_stddev_ns", "write_lat_samples", "primary_io_bytes",
  "primary_bw_bytes_per_sec", "primary_bw_kib_per_sec", "primary_iops", "primary_runtime_ms",
  "primary_total_ios", "primary_short_ios", "primary_drop_ios", "primary_clat_mean_ns",
  "primary_clat_p50_ns", "primary_clat_p95_ns", "primary_clat_p99_ns", "primary_clat_p999_ns",
  "primary_clat_p9999_ns", "primary_clat_min_ns", "primary_clat_max_ns", "primary_clat_stddev_ns",
  "primary_clat_samples", "valid_measurement", "failure_reason"
)

fio_internal_fields <- c(fio_fields, "fio_command")

consolidated_fio_fields <- c(
  "run_id", "scenario_name", "provider", "os_tuning",
  "benchmark_machine_type", "benchmark_availability_zone",
  "block_volume_performance_class", "block_volume_type", "block_volume_iops",
  "block_volume_throughput_mbps", "benchmark_name", "benchmark_tool",
  "benchmark_rw_mode", "io_engine", "block_size", "block_size_bytes",
  "iodepth", "numjobs", "runtime_sec", "direct",
  "time_based", "fio_size", "fio_fsync", "fio_fdatasync", "durability_mode",
  "durability_every_ops", "storage_target", "storage_target_filesystem",
  "storage_local_filesystem", "storage_block_filesystem", "repetition",
  "fio_command", "fio_version", "fio_timestamp_ms", "fio_error",
  "valid_measurement", "failure_reason", "usr_cpu", "sys_cpu", "ctx",
  "majf", "minf", "sync_total_ios", "sync_lat_mean_ns", "sync_lat_p50_ns",
  "sync_lat_p95_ns", "sync_lat_p99_ns", "sync_lat_p999_ns", "sync_lat_p9999_ns",
  "sync_lat_min_ns", "sync_lat_max_ns", "sync_lat_stddev_ns", "sync_lat_samples",
  "read_io_bytes", "read_bw_bytes", "read_bw_kib_per_sec", "read_bw_min_kib_per_sec",
  "read_bw_max_kib_per_sec", "read_bw_mean_kib_per_sec", "read_bw_dev_kib_per_sec",
  "read_bw_samples", "read_iops", "read_iops_min", "read_iops_max", "read_iops_mean",
  "read_iops_stddev", "read_iops_samples", "read_runtime_ms", "read_total_ios",
  "read_short_ios", "read_drop_ios", "read_slat_mean_ns", "read_slat_min_ns",
  "read_slat_max_ns", "read_slat_stddev_ns", "read_slat_samples", "read_clat_mean_ns",
  "read_clat_p50_ns", "read_clat_p95_ns", "read_clat_p99_ns", "read_clat_p999_ns",
  "read_clat_p9999_ns", "read_clat_min_ns", "read_clat_max_ns", "read_clat_stddev_ns",
  "read_clat_samples", "read_lat_mean_ns", "read_lat_min_ns", "read_lat_max_ns",
  "read_lat_stddev_ns", "read_lat_samples", "write_io_bytes", "write_bw_bytes",
  "write_bw_kib_per_sec", "write_bw_min_kib_per_sec", "write_bw_max_kib_per_sec",
  "write_bw_mean_kib_per_sec", "write_bw_dev_kib_per_sec", "write_bw_samples",
  "write_iops", "write_iops_min", "write_iops_max", "write_iops_mean",
  "write_iops_stddev", "write_iops_samples", "write_runtime_ms", "write_total_ios",
  "write_short_ios", "write_drop_ios", "write_slat_mean_ns", "write_slat_min_ns",
  "write_slat_max_ns", "write_slat_stddev_ns", "write_slat_samples", "write_clat_mean_ns",
  "write_clat_p50_ns", "write_clat_p95_ns", "write_clat_p99_ns", "write_clat_p999_ns",
  "write_clat_p9999_ns", "write_clat_min_ns", "write_clat_max_ns", "write_clat_stddev_ns",
  "write_clat_samples", "write_lat_mean_ns", "write_lat_min_ns", "write_lat_max_ns",
  "write_lat_stddev_ns", "write_lat_samples"
)

fio_numeric_fields <- c(
  "block_volume_iops", "block_volume_throughput_mbps", "block_size_bytes",
  "iodepth", "numjobs", "runtime_sec", "direct", "time_based", "fio_fsync",
  "fio_fdatasync", "durability_every_ops", "repetition", "fio_timestamp_ms",
  "fio_error", "usr_cpu", "sys_cpu", "ctx", "majf", "minf", "sync_total_ios",
  "sync_lat_mean_ns", "sync_lat_p50_ns", "sync_lat_p95_ns", "sync_lat_p99_ns",
  "sync_lat_p999_ns", "sync_lat_p9999_ns", "sync_lat_min_ns", "sync_lat_max_ns",
  "sync_lat_stddev_ns", "sync_lat_samples", "read_io_bytes", "read_bw_bytes",
  "read_bw_kib_per_sec", "read_bw_min_kib_per_sec", "read_bw_max_kib_per_sec",
  "read_bw_mean_kib_per_sec", "read_bw_dev_kib_per_sec", "read_bw_samples",
  "read_iops", "read_iops_min", "read_iops_max", "read_iops_mean", "read_iops_stddev",
  "read_iops_samples", "read_runtime_ms", "read_total_ios", "read_short_ios",
  "read_drop_ios", "read_slat_mean_ns", "read_slat_min_ns", "read_slat_max_ns",
  "read_slat_stddev_ns", "read_slat_samples", "read_clat_mean_ns", "read_clat_p50_ns",
  "read_clat_p95_ns", "read_clat_p99_ns", "read_clat_p999_ns", "read_clat_p9999_ns",
  "read_clat_min_ns", "read_clat_max_ns", "read_clat_stddev_ns", "read_clat_samples",
  "read_lat_mean_ns", "read_lat_min_ns", "read_lat_max_ns", "read_lat_stddev_ns",
  "read_lat_samples", "write_io_bytes", "write_bw_bytes", "write_bw_kib_per_sec",
  "write_bw_min_kib_per_sec", "write_bw_max_kib_per_sec", "write_bw_mean_kib_per_sec",
  "write_bw_dev_kib_per_sec", "write_bw_samples", "write_iops", "write_iops_min",
  "write_iops_max", "write_iops_mean", "write_iops_stddev", "write_iops_samples",
  "write_runtime_ms", "write_total_ios", "write_short_ios", "write_drop_ios",
  "write_slat_mean_ns", "write_slat_min_ns", "write_slat_max_ns", "write_slat_stddev_ns",
  "write_slat_samples", "write_clat_mean_ns", "write_clat_p50_ns", "write_clat_p95_ns",
  "write_clat_p99_ns", "write_clat_p999_ns", "write_clat_p9999_ns", "write_clat_min_ns",
  "write_clat_max_ns", "write_clat_stddev_ns", "write_clat_samples", "write_lat_mean_ns",
  "write_lat_min_ns", "write_lat_max_ns", "write_lat_stddev_ns", "write_lat_samples"
)

zero_fill_numeric_columns <- function(df, cols) {
  for (col in cols) {
    if (!col %in% names(df)) next
    if (is.numeric(df[[col]]) || is.integer(df[[col]])) {
      df[[col]][is.na(df[[col]])] <- 0
    } else if (is.character(df[[col]])) {
      df[[col]][is.na(df[[col]]) | df[[col]] == ""] <- "0"
    } else if (is.logical(df[[col]])) {
      df[[col]][is.na(df[[col]])] <- FALSE
    }
  }
  df
}

failure_fields <- c(
  benchmark_fields, "repetition", "fio_json_file", "fio_log_file", "fio_cmd_file", "fio_error",
  "failure_reason"
)

scenario_row <- function(run_id, scenario_name, scenario_env, storage_env, scenario_dir) {
  provider <- detect_provider(scenario_name)
  storage_targets <- env_get(scenario_env, "STORAGE_TARGETS", env_get(storage_env, "STORAGE_TARGETS"))
  storage_local_mount <- env_get(scenario_env, "STORAGE_LOCAL_MOUNT", env_get(storage_env, "STORAGE_LOCAL_MOUNT"))
  storage_block_mount <- env_get(scenario_env, "STORAGE_BLOCK_MOUNT", env_get(storage_env, "STORAGE_BLOCK_MOUNT"))
  block_perf_class <- derive_block_volume_performance_class(
    provider,
    scenario_name,
    env_get(scenario_env, "BENCHMARK_MACHINE_TYPE"),
    scenario_env
  )
  block_profile <- block_profile_metadata(provider, scenario_env, block_perf_class)
  if (identical(provider, "aws")) {
    block_perf_class <- block_profile$performance_class
  }
  storage_local_filesystem <- infer_storage_filesystem(
    env_get(scenario_env, "STORAGE_LOCAL_FILESYSTEM", env_get(storage_env, "STORAGE_LOCAL_FILESYSTEM")),
    scenario_name,
    storage_local_mount
  )
  storage_block_filesystem <- infer_storage_filesystem(
    env_get(scenario_env, "STORAGE_BLOCK_FILESYSTEM", env_get(storage_env, "STORAGE_BLOCK_FILESYSTEM")),
    scenario_name,
    storage_block_mount
  )
  data.frame(
    run_id = run_id,
    scenario_name = scenario_name,
    provider = provider,
    access_mode = env_get(scenario_env, "ACCESS_MODE"),
    os_tuning = env_get(scenario_env, "OS_TUNING"),
    benchmark_host = env_get(scenario_env, "BENCHMARK_HOST"),
    benchmark_private_ip = env_get(scenario_env, "BENCHMARK_PRIVATE_IP"),
    ssh_user = env_get(scenario_env, "SSH_USER"),
    benchmark_cpu_list = env_get(scenario_env, "BENCHMARK_CPU_LIST"),
    benchmark_machine_type = env_get(scenario_env, "BENCHMARK_MACHINE_TYPE"),
    benchmark_availability_zone = env_get(scenario_env, "BENCHMARK_AVAILABILITY_ZONE"),
    block_volume_performance_class = block_perf_class,
    block_volume_type = scalar_char(block_profile$type),
    block_volume_iops = scalar_num(block_profile$iops),
    block_volume_throughput_mbps = scalar_num(block_profile$throughput_mbps),
    storage_targets_raw = storage_targets,
    storage_root_device = env_get(scenario_env, "STORAGE_ROOT_DEVICE", env_get(storage_env, "STORAGE_ROOT_DEVICE")),
    storage_local_device = env_get(scenario_env, "STORAGE_LOCAL_DEVICE", env_get(storage_env, "STORAGE_LOCAL_DEVICE")),
    storage_local_mount = storage_local_mount,
    storage_local_filesystem = storage_local_filesystem,
    storage_block_device = env_get(scenario_env, "STORAGE_BLOCK_DEVICE", env_get(storage_env, "STORAGE_BLOCK_DEVICE")),
    storage_block_mount = storage_block_mount,
    storage_block_filesystem = storage_block_filesystem,
    # CPU idle state matters here as much as on the network side: the psync
    # queue-depth-1 profiles spend most of their time waiting, so a core that
    # drops into a deep idle state pays exit latency on every completion.
    # cpufreq is the separate frequency-scaling subsystem; driver = 'none' means
    # the guest exposes no frequency control, which is distinct from NA.
    cpu_idle_pinning_requested = env_get(scenario_env, "CPU_IDLE_PINNING"),
    cpu_idle_pinning_supported = env_get(scenario_env, "NODE_CPU_IDLE_PINNING_SUPPORTED"),
    cpu_idle_pinning_verified = env_get(scenario_env, "NODE_CPU_IDLE_PINNING_VERIFIED"),
    cpu_idle_pinning_reason = env_get(scenario_env, "NODE_CPU_IDLE_PINNING_REASON"),
    cpu_idle_driver = env_get(scenario_env, "NODE_CPU_IDLE_DRIVER"),
    cpu_idle_deep_entries_delta = to_num(env_get(scenario_env, "NODE_CPU_IDLE_DEEP_ENTRIES_DELTA")),
    cpufreq_driver = env_get(scenario_env, "NODE_CPUFREQ_DRIVER"),
    cpufreq_governor = env_get(scenario_env, "NODE_CPUFREQ_GOVERNOR"),
    kernel_release = env_get(scenario_env, "NODE_KERNEL_RELEASE"),
    scenario_source_file = file.path(scenario_dir, "scenario.env"),
    storage_env_file = file.path(scenario_dir, "storage.env"),
    stringsAsFactors = FALSE
  )
}

benchmark_row <- function(run_id, scenario_name, scenario_env, storage_env, benchmark_name, storage_target, benchmark_env, benchmark_dir, scenario_dir) {
  rw_mode <- env_get(benchmark_env, "FIO_RW")
  provider <- detect_provider(scenario_name)
  storage_local_mount <- env_get(scenario_env, "STORAGE_LOCAL_MOUNT", env_get(storage_env, "STORAGE_LOCAL_MOUNT"))
  storage_block_mount <- env_get(scenario_env, "STORAGE_BLOCK_MOUNT", env_get(storage_env, "STORAGE_BLOCK_MOUNT"))
  block_perf_class <- derive_block_volume_performance_class(
    provider,
    scenario_name,
    env_get(scenario_env, "BENCHMARK_MACHINE_TYPE"),
    scenario_env
  )
  block_profile <- block_profile_metadata(provider, scenario_env, block_perf_class)
  if (identical(provider, "aws")) {
    block_perf_class <- block_profile$performance_class
  }
  storage_local_filesystem <- infer_storage_filesystem(
    env_get(scenario_env, "STORAGE_LOCAL_FILESYSTEM", env_get(storage_env, "STORAGE_LOCAL_FILESYSTEM")),
    scenario_name,
    storage_local_mount
  )
  storage_block_filesystem <- infer_storage_filesystem(
    env_get(scenario_env, "STORAGE_BLOCK_FILESYSTEM", env_get(storage_env, "STORAGE_BLOCK_FILESYSTEM")),
    scenario_name,
    storage_block_mount
  )
  storage_target_filesystem <- if (identical(storage_target, "local")) {
    storage_local_filesystem
  } else if (identical(storage_target, "block")) {
    storage_block_filesystem
  } else {
    NA_character_
  }
  data.frame(
    run_id = run_id,
    scenario_name = scenario_name,
    provider = provider,
    access_mode = env_get(scenario_env, "ACCESS_MODE"),
    os_tuning = env_get(benchmark_env, "OS_TUNING", env_get(scenario_env, "OS_TUNING")),
    benchmark_host = env_get(scenario_env, "BENCHMARK_HOST"),
    benchmark_private_ip = env_get(scenario_env, "BENCHMARK_PRIVATE_IP"),
    ssh_user = env_get(scenario_env, "SSH_USER"),
    benchmark_cpu_list = env_get(benchmark_env, "BENCHMARK_CPU_LIST", env_get(scenario_env, "BENCHMARK_CPU_LIST")),
    benchmark_machine_type = env_get(scenario_env, "BENCHMARK_MACHINE_TYPE"),
    benchmark_availability_zone = env_get(scenario_env, "BENCHMARK_AVAILABILITY_ZONE"),
    block_volume_performance_class = block_perf_class,
    block_volume_type = scalar_char(block_profile$type),
    block_volume_iops = scalar_num(block_profile$iops),
    block_volume_throughput_mbps = scalar_num(block_profile$throughput_mbps),
    storage_targets_raw = env_get(scenario_env, "STORAGE_TARGETS", env_get(storage_env, "STORAGE_TARGETS")),
    storage_root_device = env_get(scenario_env, "STORAGE_ROOT_DEVICE", env_get(storage_env, "STORAGE_ROOT_DEVICE")),
    storage_local_device = env_get(scenario_env, "STORAGE_LOCAL_DEVICE", env_get(storage_env, "STORAGE_LOCAL_DEVICE")),
    storage_local_mount = storage_local_mount,
    storage_local_filesystem = storage_local_filesystem,
    storage_block_device = env_get(scenario_env, "STORAGE_BLOCK_DEVICE", env_get(storage_env, "STORAGE_BLOCK_DEVICE")),
    storage_block_mount = storage_block_mount,
    storage_block_filesystem = storage_block_filesystem,
    scenario_source_file = file.path(scenario_dir, "scenario.env"),
    storage_env_file = file.path(scenario_dir, "storage.env"),
    benchmark_name = benchmark_name,
    benchmark_source_file = file.path(benchmark_dir, "benchmark.env"),
    storage_target = storage_target,
    storage_target_mount = env_get(benchmark_env, "STORAGE_TARGET_MOUNT"),
    storage_target_device = env_get(benchmark_env, "STORAGE_TARGET_DEVICE"),
    storage_target_filesystem = storage_target_filesystem,
    benchmark_tool = env_get(benchmark_env, "BENCHMARK_TOOL"),
    benchmark_rw_mode = rw_mode,
    access_pattern = access_pattern_for_rw(rw_mode),
    direction = direction_for_rw(rw_mode),
    io_engine = env_get(benchmark_env, "FIO_IOENGINE"),
    block_size = env_get(benchmark_env, "FIO_BS"),
    block_size_bytes = parse_size_bytes(env_get(benchmark_env, "FIO_BS")),
    iodepth = to_num(env_get(benchmark_env, "FIO_IODEPTH")),
    numjobs = to_num(env_get(benchmark_env, "FIO_NUMJOBS")),
    runtime_sec = to_num(env_get(benchmark_env, "FIO_RUNTIME_SEC")),
    direct = to_num(env_get(benchmark_env, "FIO_DIRECT")),
    group_reporting = to_num(env_get(benchmark_env, "FIO_GROUP_REPORTING")),
    time_based = to_num(env_get(benchmark_env, "FIO_TIME_BASED")),
    fio_size = env_get(benchmark_env, "FIO_SIZE"),
    fio_fsync = to_num(env_get(benchmark_env, "FIO_FSYNC", "0")),
    fio_fdatasync = to_num(env_get(benchmark_env, "FIO_FDATASYNC", "0")),
    durability_mode = durability_mode_from_counts(
      env_get(benchmark_env, "FIO_FSYNC", "0"),
      env_get(benchmark_env, "FIO_FDATASYNC", "0")
    ),
    durability_every_ops = durability_every_ops_from_counts(
      env_get(benchmark_env, "FIO_FSYNC", "0"),
      env_get(benchmark_env, "FIO_FDATASYNC", "0")
    ),
    repetitions_expected = to_num(env_get(benchmark_env, "REPETITIONS")),
    cooldown_sec = to_num(env_get(benchmark_env, "COOLDOWN_SEC")),
    benchmark_dir = benchmark_dir,
    stringsAsFactors = FALSE
  )
}

parse_job_metrics <- function(job, section_name) {
  section <- if (!is.null(job[[section_name]])) job[[section_name]] else list()
  clat <- if (!is.null(section$clat_ns)) section$clat_ns else list()
  slat <- if (!is.null(section$slat_ns)) section$slat_ns else list()
  lat <- if (!is.null(section$lat_ns)) section$lat_ns else list()
  data.frame(
    io_bytes = scalar_num(section$io_bytes),
    bw_bytes = scalar_num(section$bw_bytes),
    bw_kib_per_sec = scalar_num(section$bw),
    bw_min_kib_per_sec = scalar_num(section$bw_min),
    bw_max_kib_per_sec = scalar_num(section$bw_max),
    bw_mean_kib_per_sec = scalar_num(section$bw_mean),
    bw_dev_kib_per_sec = scalar_num(section$bw_dev),
    bw_samples = scalar_num(section$bw_samples),
    iops = scalar_num(section$iops),
    iops_min = scalar_num(section$iops_min),
    iops_max = scalar_num(section$iops_max),
    iops_mean = scalar_num(section$iops_mean),
    iops_stddev = scalar_num(section$iops_stddev),
    iops_samples = scalar_num(section$iops_samples),
    runtime_ms = scalar_num(section$runtime),
    total_ios = scalar_num(section$total_ios),
    short_ios = scalar_num(section$short_ios),
    drop_ios = scalar_num(section$drop_ios),
    slat_mean_ns = scalar_num(slat$mean),
    slat_min_ns = scalar_num(slat$min),
    slat_max_ns = scalar_num(slat$max),
    slat_stddev_ns = scalar_num(slat$stddev),
    slat_samples = scalar_num(slat$N),
    clat_mean_ns = scalar_num(clat$mean),
    clat_p50_ns = percentile_value(clat, "50.000000"),
    clat_p95_ns = percentile_value(clat, "95.000000"),
    clat_p99_ns = percentile_value(clat, "99.000000"),
    clat_p999_ns = percentile_value(clat, "99.900000"),
    clat_p9999_ns = percentile_value(clat, "99.990000"),
    clat_min_ns = scalar_num(clat$min),
    clat_max_ns = scalar_num(clat$max),
    clat_stddev_ns = scalar_num(clat$stddev),
    clat_samples = scalar_num(clat$N),
    lat_mean_ns = scalar_num(lat$mean),
    lat_min_ns = scalar_num(lat$min),
    lat_max_ns = scalar_num(lat$max),
    lat_stddev_ns = scalar_num(lat$stddev),
    lat_samples = scalar_num(lat$N),
    stringsAsFactors = FALSE
  )
}

parse_sync_metrics <- function(job) {
  sync <- if (!is.null(job$sync)) job$sync else list()
  lat <- if (!is.null(sync$lat_ns)) sync$lat_ns else list()
  data.frame(
    sync_total_ios = scalar_num(sync$total_ios),
    sync_lat_mean_ns = scalar_num(lat$mean),
    sync_lat_p50_ns = percentile_value(lat, "50.000000"),
    sync_lat_p95_ns = percentile_value(lat, "95.000000"),
    sync_lat_p99_ns = percentile_value(lat, "99.000000"),
    sync_lat_p999_ns = percentile_value(lat, "99.900000"),
    sync_lat_p9999_ns = percentile_value(lat, "99.990000"),
    sync_lat_min_ns = scalar_num(lat$min),
    sync_lat_max_ns = scalar_num(lat$max),
    sync_lat_stddev_ns = scalar_num(lat$stddev),
    sync_lat_samples = scalar_num(lat$N),
    stringsAsFactors = FALSE
  )
}

parse_fio_row <- function(run_id, scenario_name, scenario_env, storage_env, benchmark_name, storage_target, benchmark_env,
                          benchmark_dir, scenario_dir, rep_dir, rep, json_path, log_path, cmd_path) {
  doc <- read_fio_doc(json_path)
  if (is.null(doc) || is.null(doc$jobs) || length(doc$jobs) == 0) return(NULL)

  job <- doc$jobs[[1]]
  job_opts <- if (!is.null(job[["job options"]])) job[["job options"]] else list()
  direction <- direction_for_rw(env_get(benchmark_env, "FIO_RW"))
  primary_section <- if (identical(direction, "read")) "read" else "write"
  other_section <- if (identical(primary_section, "read")) "write" else "read"
  read_metrics <- parse_job_metrics(job, "read")
  write_metrics <- parse_job_metrics(job, "write")
  primary_metrics <- if (identical(primary_section, "read")) read_metrics else write_metrics
  error_code <- scalar_num(job$error)
  failure_reason <- if (!is.na(error_code) && error_code != 0) first_line(log_path) else NA_character_
  valid_measurement <- !is.na(error_code) && error_code == 0 && !is.na(primary_metrics$bw_bytes[[1]]) && primary_metrics$bw_bytes[[1]] > 0

  base <- benchmark_row(run_id, scenario_name, scenario_env, storage_env, benchmark_name, storage_target, benchmark_env, benchmark_dir, scenario_dir)
  base$repetition <- rep
  base$fio_json_file <- json_path
  base$fio_log_file <- log_path
  base$fio_cmd_file <- cmd_path
  base$fio_command <- read_text_file(cmd_path)
  base$fio_version <- if (!is.null(doc[["fio version"]])) as.character(doc[["fio version"]]) else NA_character_
  base$fio_timestamp <- if (!is.null(doc[["timestamp"]])) as.character(doc[["timestamp"]]) else NA_character_
  base$fio_timestamp_ms <- scalar_num(doc$timestamp_ms)
  base$fio_time <- if (!is.null(doc[["time"]])) as.character(doc[["time"]]) else NA_character_
  base$fio_jobname <- if (!is.null(job$jobname)) as.character(job$jobname) else NA_character_
  base$fio_error <- error_code
  base$fio_job_runtime_ms <- scalar_num(job$job_runtime)
  base$fio_elapsed_sec <- scalar_num(job$elapsed)
  base$fio_eta <- scalar_num(job$eta)
  sync_metrics <- parse_sync_metrics(job)
  base$usr_cpu <- scalar_num(job$usr_cpu)
  base$sys_cpu <- scalar_num(job$sys_cpu)
  base$ctx <- scalar_num(job$ctx)
  base$majf <- scalar_num(job$majf)
  base$minf <- scalar_num(job$minf)
  base$iodepth_level <- scalar_num(job$iodepth_level)
  base$iodepth_submit <- scalar_num(job$iodepth_submit)
  base$iodepth_complete <- scalar_num(job$iodepth_complete)
  base$latency_ns <- scalar_num(job$latency_ns)
  base$latency_us <- scalar_num(job$latency_us)
  base$latency_ms <- scalar_num(job$latency_ms)
  base$latency_depth <- scalar_num(job$latency_depth)
  base$latency_target <- scalar_num(job$latency_target)
  base$latency_percentile <- scalar_num(job$latency_percentile)
  base$latency_window <- scalar_num(job$latency_window)
  base$sync_total_ios <- sync_metrics$sync_total_ios
  base$sync_lat_mean_ns <- sync_metrics$sync_lat_mean_ns
  base$sync_lat_p50_ns <- sync_metrics$sync_lat_p50_ns
  base$sync_lat_p95_ns <- sync_metrics$sync_lat_p95_ns
  base$sync_lat_p99_ns <- sync_metrics$sync_lat_p99_ns
  base$sync_lat_p999_ns <- sync_metrics$sync_lat_p999_ns
  base$sync_lat_p9999_ns <- sync_metrics$sync_lat_p9999_ns
  base$sync_lat_min_ns <- sync_metrics$sync_lat_min_ns
  base$sync_lat_max_ns <- sync_metrics$sync_lat_max_ns
  base$sync_lat_stddev_ns <- sync_metrics$sync_lat_stddev_ns
  base$sync_lat_samples <- sync_metrics$sync_lat_samples

  base$read_io_bytes <- read_metrics$io_bytes
  base$read_bw_bytes <- read_metrics$bw_bytes
  base$read_bw_kib_per_sec <- read_metrics$bw_kib_per_sec
  base$read_bw_min_kib_per_sec <- read_metrics$bw_min_kib_per_sec
  base$read_bw_max_kib_per_sec <- read_metrics$bw_max_kib_per_sec
  base$read_bw_mean_kib_per_sec <- read_metrics$bw_mean_kib_per_sec
  base$read_bw_dev_kib_per_sec <- read_metrics$bw_dev_kib_per_sec
  base$read_bw_samples <- read_metrics$bw_samples
  base$read_iops <- read_metrics$iops
  base$read_iops_min <- read_metrics$iops_min
  base$read_iops_max <- read_metrics$iops_max
  base$read_iops_mean <- read_metrics$iops_mean
  base$read_iops_stddev <- read_metrics$iops_stddev
  base$read_iops_samples <- read_metrics$iops_samples
  base$read_runtime_ms <- read_metrics$runtime_ms
  base$read_total_ios <- read_metrics$total_ios
  base$read_short_ios <- read_metrics$short_ios
  base$read_drop_ios <- read_metrics$drop_ios
  base$read_slat_mean_ns <- read_metrics$slat_mean_ns
  base$read_slat_min_ns <- read_metrics$slat_min_ns
  base$read_slat_max_ns <- read_metrics$slat_max_ns
  base$read_slat_stddev_ns <- read_metrics$slat_stddev_ns
  base$read_slat_samples <- read_metrics$slat_samples
  base$read_clat_mean_ns <- read_metrics$clat_mean_ns
  base$read_clat_p50_ns <- read_metrics$clat_p50_ns
  base$read_clat_p95_ns <- read_metrics$clat_p95_ns
  base$read_clat_p99_ns <- read_metrics$clat_p99_ns
  base$read_clat_p999_ns <- read_metrics$clat_p999_ns
  base$read_clat_p9999_ns <- read_metrics$clat_p9999_ns
  base$read_clat_min_ns <- read_metrics$clat_min_ns
  base$read_clat_max_ns <- read_metrics$clat_max_ns
  base$read_clat_stddev_ns <- read_metrics$clat_stddev_ns
  base$read_clat_samples <- read_metrics$clat_samples
  base$read_lat_mean_ns <- read_metrics$lat_mean_ns
  base$read_lat_min_ns <- read_metrics$lat_min_ns
  base$read_lat_max_ns <- read_metrics$lat_max_ns
  base$read_lat_stddev_ns <- read_metrics$lat_stddev_ns
  base$read_lat_samples <- read_metrics$lat_samples

  base$write_io_bytes <- write_metrics$io_bytes
  base$write_bw_bytes <- write_metrics$bw_bytes
  base$write_bw_kib_per_sec <- write_metrics$bw_kib_per_sec
  base$write_bw_min_kib_per_sec <- write_metrics$bw_min_kib_per_sec
  base$write_bw_max_kib_per_sec <- write_metrics$bw_max_kib_per_sec
  base$write_bw_mean_kib_per_sec <- write_metrics$bw_mean_kib_per_sec
  base$write_bw_dev_kib_per_sec <- write_metrics$bw_dev_kib_per_sec
  base$write_bw_samples <- write_metrics$bw_samples
  base$write_iops <- write_metrics$iops
  base$write_iops_min <- write_metrics$iops_min
  base$write_iops_max <- write_metrics$iops_max
  base$write_iops_mean <- write_metrics$iops_mean
  base$write_iops_stddev <- write_metrics$iops_stddev
  base$write_iops_samples <- write_metrics$iops_samples
  base$write_runtime_ms <- write_metrics$runtime_ms
  base$write_total_ios <- write_metrics$total_ios
  base$write_short_ios <- write_metrics$short_ios
  base$write_drop_ios <- write_metrics$drop_ios
  base$write_slat_mean_ns <- write_metrics$slat_mean_ns
  base$write_slat_min_ns <- write_metrics$slat_min_ns
  base$write_slat_max_ns <- write_metrics$slat_max_ns
  base$write_slat_stddev_ns <- write_metrics$slat_stddev_ns
  base$write_slat_samples <- write_metrics$slat_samples
  base$write_clat_mean_ns <- write_metrics$clat_mean_ns
  base$write_clat_p50_ns <- write_metrics$clat_p50_ns
  base$write_clat_p95_ns <- write_metrics$clat_p95_ns
  base$write_clat_p99_ns <- write_metrics$clat_p99_ns
  base$write_clat_p999_ns <- write_metrics$clat_p999_ns
  base$write_clat_p9999_ns <- write_metrics$clat_p9999_ns
  base$write_clat_min_ns <- write_metrics$clat_min_ns
  base$write_clat_max_ns <- write_metrics$clat_max_ns
  base$write_clat_stddev_ns <- write_metrics$clat_stddev_ns
  base$write_clat_samples <- write_metrics$clat_samples
  base$write_lat_mean_ns <- write_metrics$lat_mean_ns
  base$write_lat_min_ns <- write_metrics$lat_min_ns
  base$write_lat_max_ns <- write_metrics$lat_max_ns
  base$write_lat_stddev_ns <- write_metrics$lat_stddev_ns
  base$write_lat_samples <- write_metrics$lat_samples

  base$primary_io_bytes <- if (identical(direction, "read")) base$read_io_bytes else base$write_io_bytes
  base$primary_bw_bytes_per_sec <- if (identical(direction, "read")) base$read_bw_bytes else base$write_bw_bytes
  base$primary_bw_kib_per_sec <- if (identical(direction, "read")) base$read_bw_kib_per_sec else base$write_bw_kib_per_sec
  base$primary_iops <- if (identical(direction, "read")) base$read_iops else base$write_iops
  base$primary_runtime_ms <- if (identical(direction, "read")) base$read_runtime_ms else base$write_runtime_ms
  base$primary_total_ios <- if (identical(direction, "read")) base$read_total_ios else base$write_total_ios
  base$primary_short_ios <- if (identical(direction, "read")) base$read_short_ios else base$write_short_ios
  base$primary_drop_ios <- if (identical(direction, "read")) base$read_drop_ios else base$write_drop_ios
  base$primary_clat_mean_ns <- if (identical(direction, "read")) base$read_clat_mean_ns else base$write_clat_mean_ns
  base$primary_clat_p50_ns <- if (identical(direction, "read")) base$read_clat_p50_ns else base$write_clat_p50_ns
  base$primary_clat_p95_ns <- if (identical(direction, "read")) base$read_clat_p95_ns else base$write_clat_p95_ns
  base$primary_clat_p99_ns <- if (identical(direction, "read")) base$read_clat_p99_ns else base$write_clat_p99_ns
  base$primary_clat_p999_ns <- if (identical(direction, "read")) base$read_clat_p999_ns else base$write_clat_p999_ns
  base$primary_clat_p9999_ns <- if (identical(direction, "read")) base$read_clat_p9999_ns else base$write_clat_p9999_ns
  base$primary_clat_min_ns <- if (identical(direction, "read")) base$read_clat_min_ns else base$write_clat_min_ns
  base$primary_clat_max_ns <- if (identical(direction, "read")) base$read_clat_max_ns else base$write_clat_max_ns
  base$primary_clat_stddev_ns <- if (identical(direction, "read")) base$read_clat_stddev_ns else base$write_clat_stddev_ns
  base$primary_clat_samples <- if (identical(direction, "read")) base$read_clat_samples else base$write_clat_samples
  base$valid_measurement <- valid_measurement
  base$failure_reason <- failure_reason

  base
}

parse_storage_run <- function(repo_root, run_id) {
  run_dir <- file.path(repo_root, "artifacts", "storage", run_id)
  if (!dir.exists(run_dir)) stop(sprintf("Storage artifacts directory not found: %s", run_dir))

  scenario_dirs <- list.dirs(run_dir, full.names = TRUE, recursive = FALSE)
  scenario_dirs <- scenario_dirs[file.exists(file.path(scenario_dirs, "scenario.env"))]
  if (length(scenario_dirs) == 0) return(list(
    scenarios = empty_df(scenario_fields),
    benchmarks = empty_df(benchmark_fields),
    fio = empty_df(fio_internal_fields),
    failures = empty_df(failure_fields)
  ))

  scenario_rows <- list()
  benchmark_rows <- list()
  fio_rows <- list()

  for (scenario_dir in scenario_dirs) {
    scenario_name <- basename(scenario_dir)
    # node-facts.env, os-tuning.env and cpu-idle-benchmark.env are written by
    # the runner alongside scenario.env. All are absent for runs recorded before
    # they existed, in which case the columns they feed are simply NA.
    scenario_env <- merge_env(
      read_env_file(file.path(scenario_dir, "scenario.env")),
      read_env_file(file.path(scenario_dir, "node-facts.env")),
      read_env_file(file.path(scenario_dir, "os-tuning.env")),
      read_env_file(file.path(scenario_dir, "cpu-idle-benchmark.env"))
    )
    storage_env <- read_env_file(file.path(scenario_dir, "storage.env"))
    scenario_rows[[length(scenario_rows) + 1]] <- scenario_row(run_id, scenario_name, scenario_env, storage_env, scenario_dir)

    benchmark_env_paths <- Sys.glob(file.path(scenario_dir, "benchmarks", "*", "*", "benchmark.env"))
    benchmark_env_paths <- sort(benchmark_env_paths)

    for (benchmark_env_path in benchmark_env_paths) {
      benchmark_target_dir <- dirname(benchmark_env_path)
      benchmark_dir <- dirname(benchmark_target_dir)
      benchmark_name <- basename(benchmark_dir)
      storage_target <- basename(benchmark_target_dir)
      benchmark_env <- read_env_file(benchmark_env_path)
      benchmark_rows[[length(benchmark_rows) + 1]] <- benchmark_row(
        run_id, scenario_name, scenario_env, storage_env, benchmark_name, storage_target, benchmark_env, benchmark_dir, scenario_dir
      )

      rep_json_paths <- Sys.glob(file.path(benchmark_target_dir, "rep-*", "fio.json"))
      rep_json_paths <- sort(rep_json_paths)
      for (json_path in rep_json_paths) {
        rep_dir <- dirname(json_path)
        rep <- to_num(sub("^rep-", "", basename(rep_dir)))
        log_path <- file.path(rep_dir, "fio.log")
        cmd_path <- file.path(rep_dir, "fio.cmd")
        row <- parse_fio_row(
          run_id, scenario_name, scenario_env, storage_env, benchmark_name, storage_target, benchmark_env,
          benchmark_dir, scenario_dir, rep_dir, rep, json_path, log_path, cmd_path
        )
        if (!is.null(row)) fio_rows[[length(fio_rows) + 1]] <- row
      }
    }
  }

  fio_df <- bind_rows_with_schema(fio_rows, fio_internal_fields)
  list(
    scenarios = bind_rows_with_schema(scenario_rows, scenario_fields),
    benchmarks = bind_rows_with_schema(benchmark_rows, benchmark_fields),
    fio = fio_df,
    failures = ensure_schema(fio_df[!as.logical(fio_df$valid_measurement), , drop = FALSE], failure_fields)
  )
}

discover_run_ids <- function(repo_root, result_id) {
  storage_root <- file.path(repo_root, "artifacts", "storage")
  if (!dir.exists(storage_root)) return(character(0))
  if (grepl(",", result_id, fixed = TRUE)) {
    run_ids <- trimws(unlist(strsplit(result_id, ",", fixed = TRUE)))
    run_ids <- run_ids[nzchar(run_ids)]
    if (length(run_ids) == 0) stop("No storage run ids were provided")
    missing_run_ids <- run_ids[!dir.exists(file.path(storage_root, run_ids))]
    if (length(missing_run_ids) > 0) {
      stop(sprintf("Storage run(s) not found: %s", paste(missing_run_ids, collapse = ", ")))
    }
    return(unique(run_ids))
  }
  if (!identical(result_id, "all")) {
    run_dir <- file.path(storage_root, result_id)
    if (!dir.exists(run_dir)) stop(sprintf("Storage run not found: %s", run_dir))
    return(result_id)
  }
  dirs <- list.dirs(storage_root, full.names = FALSE, recursive = FALSE)
  dirs[grepl("^run-[0-9]{8}-[0-9]{6}$", dirs)]
}

args <- commandArgs(trailingOnly = TRUE)
result_id <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else "all"
repo_root <- detect_repo_root()
out_dir <- file.path(repo_root, "analysis", "storage", result_id)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

run_ids <- discover_run_ids(repo_root, result_id)
if (length(run_ids) == 0) stop("No storage runs found")

parsed_runs <- lapply(run_ids, function(run_id) parse_storage_run(repo_root, run_id))

scenarios_df <- bind_rows_with_schema(lapply(parsed_runs, `[[`, "scenarios"), scenario_fields)
benchmarks_df <- bind_rows_with_schema(lapply(parsed_runs, `[[`, "benchmarks"), benchmark_fields)
fio_internal_df <- bind_rows_with_schema(lapply(parsed_runs, `[[`, "fio"), fio_internal_fields)
fio_df <- ensure_schema(fio_internal_df, fio_fields)
consolidated_fio_df <- ensure_schema(fio_internal_df, consolidated_fio_fields)
fio_df <- zero_fill_numeric_columns(fio_df, fio_numeric_fields)
consolidated_fio_df <- zero_fill_numeric_columns(consolidated_fio_df, fio_numeric_fields)
failures_df <- bind_rows_with_schema(lapply(parsed_runs, `[[`, "failures"), failure_fields)

safe_write_csv(scenarios_df, file.path(out_dir, "storage_scenarios.csv"), scenario_fields)
safe_write_csv(benchmarks_df, file.path(out_dir, "storage_benchmarks.csv"), benchmark_fields)
safe_write_csv(fio_df, file.path(out_dir, "storage_fio.csv"), fio_fields)
safe_write_csv(consolidated_fio_df, file.path(out_dir, "storage_fio_consolidated.csv"), consolidated_fio_fields)
safe_write_csv(failures_df, file.path(out_dir, "storage_failures.csv"), failure_fields)

message(sprintf("Wrote storage CSVs to %s", out_dir))
message(sprintf(
  "scenarios=%d benchmarks=%d fio=%d consolidated_fio=%d failures=%d",
  nrow(scenarios_df), nrow(benchmarks_df), nrow(fio_df), nrow(consolidated_fio_df), nrow(failures_df)
))
