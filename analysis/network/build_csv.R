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
  # R chooses fixed or scientific notation by whichever is shorter, so the same
  # column can be written as '400000' in one row and '4e+05' in another, and
  # udp_target_bitrate_bits_per_sec comes out as '1e+09'. Readers that infer
  # types cope, but the files are also read by eye and by grep. Force fixed
  # notation, and restore the caller's setting afterwards.
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

strip_ansi <- function(x) {
  gsub("\033\\[[0-9;]*[[:alpha:]]", "", x, perl = TRUE)
}

clean_scalar <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  x <- as.character(x[[1]])
  x <- trimws(x)
  x <- sub("^export[[:space:]]+", "", x, perl = TRUE)
  x <- sub("[[:space:]]+#.*$", "", x, perl = TRUE)
  x <- trimws(x)
  x <- gsub('^"|"$', "", x)
  x <- gsub("^'|'$", "", x)
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
  vals <- vapply(vals, clean_scalar, character(1))
  stats::setNames(vals, keys)
}

# read_env_file() returns a named character vector, for which env[["missing"]]
# raises "subscript out of bounds" rather than returning NULL. Every key queried
# before optional fields existed happened to always be present; check names()
# explicitly so absent keys fall back to the default instead of erroring.
env_get <- function(env, key, default = NA_character_) {
  if (is.null(env) || length(env) == 0 || is.null(names(env)) || !(key %in% names(env))) return(default)
  value <- env[[key]]
  if (is.null(value) || length(value) == 0 || is.na(value) || !nzchar(value)) default else value
}

# Overlay supplementary env files onto scenario.env without letting them shadow
# it. Node facts are namespaced with NODE_, so in practice nothing collides; the
# precedence rule just keeps scenario.env authoritative if that ever changes.
merge_env <- function(base_env, ...) {
  for (extra in list(...)) {
    if (length(extra) == 0) next
    new_keys <- setdiff(names(extra), names(base_env))
    if (length(new_keys) > 0) base_env <- c(base_env, extra[new_keys])
  }
  base_env
}

# The server writes the same NODE_* keys as the client, so its facts have to be
# renamed before they can be merged into one namespace. Client and server can
# genuinely differ -- most obviously on a mixed-type pair, but also in MTU or
# idle-state capability on a same-type pair whose instances were not identical.
prefix_env <- function(env, prefix) {
  if (length(env) == 0) return(env)
  stats::setNames(env, paste0(prefix, names(env)))
}

to_num <- function(x) {
  suppressWarnings(as.numeric(x))
}

parse_rate_bits_per_sec <- function(x) {
  if (is.null(x) || is.na(x) || !nzchar(x)) return(NA_real_)
  x <- toupper(trimws(as.character(x)))
  m <- regexec("^([0-9.]+)([KMGTP]?)$", x, perl = TRUE)
  r <- regmatches(x, m)[[1]]
  if (length(r) < 2) return(to_num(x))
  value <- to_num(r[[2]])
  suffix <- r[[3]] %||% ""
  mult <- switch(suffix, K = 1e3, M = 1e6, G = 1e9, T = 1e12, P = 1e15, 1)
  value * mult
}

parse_size_bytes <- function(x) {
  if (is.null(x) || is.na(x) || !nzchar(x)) return(NA_real_)
  x <- toupper(trimws(as.character(x)))
  m <- regexec("^([0-9.]+)([KMG]?)$", x, perl = TRUE)
  r <- regmatches(x, m)[[1]]
  if (length(r) < 2) return(to_num(x))
  value <- to_num(r[[2]])
  suffix <- r[[3]] %||% ""
  mult <- switch(suffix, K = 1024, M = 1024^2, G = 1024^3, 1)
  value * mult
}

normalize_os_tuning <- function(x) {
  if (is.na(x) || !nzchar(x)) return(NA_character_)
  if (identical(x, "network-throughput")) return("tuned")
  x
}

detect_provider <- function(scenario_name) {
  if (grepl("^stackit[_-]", scenario_name)) return("stackit")
  if (grepl("^aws[_-]", scenario_name)) return("aws")
  if (grepl("^gcp[_-]", scenario_name)) return("gcp")
  NA_character_
}

# Strip the zone suffix from an availability zone to get its region.
#   aws     us-east-1a     -> us-east-1
#   gcp     europe-west3-a -> europe-west3
#   stackit eu01-1         -> eu01
region_of_zone <- function(zone) {
  if (is.na(zone) || !nzchar(zone)) return(NA_character_)
  if (grepl("-[a-z0-9]$", zone)) {
    trimmed <- sub("-[a-z0-9]$", "", zone)
    if (nzchar(trimmed)) return(trimmed)
  }
  if (grepl("[0-9][a-z]$", zone)) return(sub("[a-z]$", "", zone))
  zone
}

derive_placement_class <- function(scenario_env) {
  placement_mode <- env_get(scenario_env, "PLACEMENT_MODE")
  server_region <- env_get(scenario_env, "SERVER_REGION")
  affinity <- env_get(scenario_env, "INSTANCE_AFFINITY")
  client_az <- env_get(scenario_env, "CLIENT_AVAILABILITY_ZONE")
  server_az <- env_get(scenario_env, "SERVER_AVAILABILITY_ZONE")

  # A cross-region scenario declares itself. Only this value short-circuits, so
  # any other PLACEMENT_MODE falls through to the availability-zone comparison
  # that classified every run before this field was recorded.
  if (identical(placement_mode, "cross-region")) return("cross-region")
  if (!is.na(server_region) && nzchar(server_region)) {
    client_region <- region_of_zone(client_az)
    if (!is.na(client_region) && !identical(client_region, server_region)) return("cross-region")
  }

  same_az <- !is.na(client_az) && !is.na(server_az) && identical(client_az, server_az)
  if (!same_az) return("multi-az")
  if (identical(affinity, "co-located")) return("co-located-single-az")
  if (identical(affinity, "different-host")) return("different-host-single-az")
  "single-az"
}

# Client and server machine types are configured independently by the runner but
# every shipped scenario currently sets them equal. This makes the distinction an
# explicit column so the first mixed-type run is not silently pooled with the
# same-type pair of its client machine type.
derive_pair_class <- function(scenario_env) {
  client_type <- env_get(scenario_env, "CLIENT_MACHINE_TYPE")
  server_type <- env_get(scenario_env, "SERVER_MACHINE_TYPE")
  if (is.na(client_type) || is.na(server_type)) return(NA_character_)
  if (identical(client_type, server_type)) "same-type" else "mixed-type"
}

get_path <- function(x, path, default = NA) {
  cur <- x
  for (part in path) {
    if (is.null(cur) || !is.list(cur) || is.null(cur[[part]])) return(default)
    cur <- cur[[part]]
  }
  if (is.null(cur) || length(cur) == 0) return(default)
  if (is.list(cur)) return(cur)
  cur[[1]]
}

first_connected <- function(doc) {
  connected <- get_path(doc, c("start", "connected"), default = list())
  if (is.data.frame(connected) && nrow(connected) > 0) return(as.list(connected[1, , drop = FALSE]))
  if (is.list(connected) && length(connected) > 0 && is.list(connected[[1]])) return(connected[[1]])
  list()
}

scenario_common_row <- function(run_id, scenario_name, scenario_env) {
  data.frame(
    run_id = run_id,
    scenario_name = scenario_name,
    provider = detect_provider(scenario_name),
    client_machine_type = env_get(scenario_env, "CLIENT_MACHINE_TYPE"),
    server_machine_type = env_get(scenario_env, "SERVER_MACHINE_TYPE"),
    client_availability_zone = env_get(scenario_env, "CLIENT_AVAILABILITY_ZONE"),
    server_availability_zone = env_get(scenario_env, "SERVER_AVAILABILITY_ZONE"),
    # A reversal-control arm re-runs an earlier scenario to measure drift. It
    # must not also contribute measurements to the comparison it audits, or that
    # configuration is counted twice. base_scenario_name pairs it with its
    # original.
    is_control = grepl("__control$", scenario_name),
    base_scenario_name = sub("__control$", "", scenario_name),
    placement_class = derive_placement_class(scenario_env),
    placement_mode = env_get(scenario_env, "PLACEMENT_MODE"),
    server_region = env_get(scenario_env, "SERVER_REGION"),
    pair_class = derive_pair_class(scenario_env),
    instance_affinity = env_get(scenario_env, "INSTANCE_AFFINITY"),
    os_tuning = normalize_os_tuning(env_get(scenario_env, "OS_TUNING")),
    access_mode = env_get(scenario_env, "ACCESS_MODE"),
    client_private_ip = env_get(scenario_env, "CLIENT_PRIVATE_IP"),
    server_private_ip = env_get(scenario_env, "SERVER_PRIVATE_IP"),
    client_cpu_list = env_get(scenario_env, "CLIENT_CPU_LIST"),
    server_cpu_list = env_get(scenario_env, "SERVER_CPU_LIST"),
    # Read back from the node after the profile ran, so a profile that claims to
    # tune something the kernel did not accept is visible in the data. These are
    # what distinguish a real cross-provider "tuned" comparison from one where
    # the profiles quietly differ.
    tuning_congestion_control = env_get(scenario_env, "NODE_OS_TUNING_CONGESTION_CONTROL"),
    tuning_qdisc = env_get(scenario_env, "NODE_OS_TUNING_QDISC"),
    tuning_rmem_max = to_num(env_get(scenario_env, "NODE_OS_TUNING_RMEM_MAX")),
    tuning_netdev_max_backlog = to_num(env_get(scenario_env, "NODE_OS_TUNING_NETDEV_BACKLOG")),
    # How many packets one NAPI poll may drain before yielding the CPU. The
    # network-throughput profile raises it 300 -> 1000 but never recorded the
    # result, so runs before this column existed read NA and cannot be used to
    # check whether the value took. Paired with the softnet_stat time_squeeze
    # counter, this is the difference between "NAPI ran out of budget" as a
    # measurement and as an inference from the shape of a latency curve.
    tuning_netdev_budget = to_num(env_get(scenario_env, "NODE_OS_TUNING_NETDEV_BUDGET")),
    # Requested versus effective, kept apart deliberately. rps_cpus is normalised
    # by the kernel and a write to a single-queue virtio NIC can succeed and
    # still steer nothing, so the mask asked for is not evidence of the mask in
    # force -- group by the effective one.
    busy_poll_requested = env_get(scenario_env, "BUSY_POLL"),
    tuning_busy_poll_usec = to_num(env_get(scenario_env, "NODE_OS_TUNING_BUSY_POLL")),
    tuning_busy_read_usec = to_num(env_get(scenario_env, "NODE_OS_TUNING_BUSY_READ")),
    rps_cpus_requested = env_get(scenario_env, "NODE_OS_TUNING_RPS_CPUS_REQUESTED"),
    rps_cpus_effective = env_get(scenario_env, "NODE_OS_TUNING_RPS_CPUS_EFFECTIVE"),
    cpu_idle_pinning_requested = env_get(scenario_env, "CPU_IDLE_PINNING"),
    cpu_idle_pinning_supported = env_get(scenario_env, "NODE_CPU_IDLE_PINNING_SUPPORTED"),
    cpu_idle_pinning_verified = env_get(scenario_env, "NODE_CPU_IDLE_PINNING_VERIFIED"),
    cpu_idle_driver = env_get(scenario_env, "NODE_CPU_IDLE_DRIVER"),
    cpu_idle_states = env_get(scenario_env, "NODE_CPU_IDLE_STATES"),
    cpu_idle_deep_entries_delta = to_num(env_get(scenario_env, "NODE_CPU_IDLE_DEEP_ENTRIES_DELTA")),
    # cpufreq is a separate subsystem from the cpu_idle_* fields above: it
    # governs frequency while executing, not what an idle core does. A
    # 'performance' governor does not keep a core out of a deep C-state, so
    # neither column substitutes for the other. driver = 'none' means the guest
    # exposes no frequency control at all, which is the common cloud case and is
    # distinct from NA, which means the run predates this field.
    cpufreq_driver = env_get(scenario_env, "NODE_CPUFREQ_DRIVER"),
    cpufreq_governor = env_get(scenario_env, "NODE_CPUFREQ_GOVERNOR"),
    cpufreq_available_governors = env_get(scenario_env, "NODE_CPUFREQ_AVAILABLE_GOVERNORS"),
    cpufreq_governor_uniform = env_get(scenario_env, "NODE_CPUFREQ_GOVERNOR_UNIFORM"),
    cpufreq_cur_freq_khz = to_num(env_get(scenario_env, "NODE_CPUFREQ_CUR_FREQ_KHZ")),
    cpufreq_min_freq_khz = to_num(env_get(scenario_env, "NODE_CPUFREQ_MIN_FREQ_KHZ")),
    cpufreq_max_freq_khz = to_num(env_get(scenario_env, "NODE_CPUFREQ_MAX_FREQ_KHZ")),
    # Server-side counterparts. A pair where the client could pin and the server
    # could not is not a pinned measurement, and without these it would read as
    # one. MTU is here for the same reason: an asymmetric path is a real effect
    # that a client-only column cannot show.
    server_cpu_idle_pinning_supported = env_get(scenario_env, "SERVER_NODE_CPU_IDLE_PINNING_SUPPORTED"),
    server_cpu_idle_pinning_verified = env_get(scenario_env, "SERVER_NODE_CPU_IDLE_PINNING_VERIFIED"),
    server_cpu_idle_pinning_reason = env_get(scenario_env, "SERVER_NODE_CPU_IDLE_PINNING_REASON"),
    server_cpu_idle_driver = env_get(scenario_env, "SERVER_NODE_CPU_IDLE_DRIVER"),
    server_cpu_idle_deep_entries_delta = to_num(env_get(scenario_env, "SERVER_NODE_CPU_IDLE_DEEP_ENTRIES_DELTA")),
    server_cpufreq_driver = env_get(scenario_env, "SERVER_NODE_CPUFREQ_DRIVER"),
    server_cpufreq_governor = env_get(scenario_env, "SERVER_NODE_CPUFREQ_GOVERNOR"),
    server_tuning_congestion_control = env_get(scenario_env, "SERVER_NODE_OS_TUNING_CONGESTION_CONTROL"),
    server_tuning_netdev_budget = to_num(env_get(scenario_env, "SERVER_NODE_OS_TUNING_NETDEV_BUDGET")),
    server_tuning_busy_poll_usec = to_num(env_get(scenario_env, "SERVER_NODE_OS_TUNING_BUSY_POLL")),
    server_rps_cpus_effective = env_get(scenario_env, "SERVER_NODE_OS_TUNING_RPS_CPUS_EFFECTIVE"),
    server_kernel_release = env_get(scenario_env, "SERVER_NODE_KERNEL_RELEASE"),
    server_primary_iface_mtu = to_num(env_get(scenario_env, "SERVER_NODE_PRIMARY_IFACE_MTU")),
    # Read from the instance metadata service, so it reports what the instance
    # actually was rather than what was requested. 'unknown' means no metadata
    # service answered, which is distinct from NA (the run predates the field).
    # Requested vs actual. USE_SPOT is what the scenario asked for;
    # purchase_model is read from the metadata service on the node. They should
    # agree, and the point of recording both is to notice when they do not.
    use_spot_requested = env_get(scenario_env, "USE_SPOT"),
    purchase_model = env_get(scenario_env, "NODE_PURCHASE_MODEL"),
    server_purchase_model = env_get(scenario_env, "SERVER_NODE_PURCHASE_MODEL"),
    kernel_release = env_get(scenario_env, "NODE_KERNEL_RELEASE"),
    image_id = env_get(scenario_env, "NODE_IMAGE_ID"),
    primary_iface = env_get(scenario_env, "NODE_PRIMARY_IFACE"),
    primary_iface_mtu = to_num(env_get(scenario_env, "NODE_PRIMARY_IFACE_MTU")),
    # NIC interrupt placement and packet steering, client and server.
    #
    # Benchmarks run on CPUs 1..n-1 while nothing places these interrupts, so
    # irq_cpus overlapping that range means receive softirq work could be
    # serviced on the measurement core -- a plausible source of tail jitter
    # that is otherwise invisible. Recorded, not controlled: the analysis can
    # test whether it correlates with the spread rather than assuming it away.
    irq_count = to_num(env_get(scenario_env, "NODE_IRQ_COUNT")),
    irq_cpus = env_get(scenario_env, "NODE_IRQ_CPUS"),
    irq_cpu_count = to_num(env_get(scenario_env, "NODE_IRQ_CPU_COUNT")),
    irqbalance_running = env_get(scenario_env, "NODE_IRQBALANCE_RUNNING"),
    rx_queues = to_num(env_get(scenario_env, "NODE_RX_QUEUES")),
    tx_queues = to_num(env_get(scenario_env, "NODE_TX_QUEUES")),
    rps_enabled = env_get(scenario_env, "NODE_RPS_ENABLED"),
    xps_enabled = env_get(scenario_env, "NODE_XPS_ENABLED"),
    server_irq_cpus = env_get(scenario_env, "SERVER_NODE_IRQ_CPUS"),
    server_irq_cpu_count = to_num(env_get(scenario_env, "SERVER_NODE_IRQ_CPU_COUNT")),
    server_irqbalance_running = env_get(scenario_env, "SERVER_NODE_IRQBALANCE_RUNNING"),
    server_rx_queues = to_num(env_get(scenario_env, "SERVER_NODE_RX_QUEUES")),
    server_rps_enabled = env_get(scenario_env, "SERVER_NODE_RPS_ENABLED"),
    iperf3_tool_version = env_get(scenario_env, "NODE_IPERF3_VERSION"),
    sockperf_tool_version = env_get(scenario_env, "NODE_SOCKPERF_VERSION"),
    fio_tool_version = env_get(scenario_env, "NODE_FIO_VERSION"),
    stringsAsFactors = FALSE
  )
}

common_measurement_fields <- function(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, source_file) {
  cbind(
    scenario_common_row(run_id, scenario_name, scenario_env),
    data.frame(
      benchmark_name = benchmark_name,
      benchmark_tool = env_get(benchmark_env, "BENCHMARK_TOOL"),
      repetition = rep,
      configured_repetitions = to_num(env_get(benchmark_env, "REPETITIONS")),
      cooldown_sec = to_num(env_get(benchmark_env, "COOLDOWN_SEC")),
      source_file = source_file,
      stringsAsFactors = FALSE
    )
  )
}

parse_iperf3_summary <- function(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path) {
  doc <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(doc)) return(NULL)

  protocol <- tolower(env_get(benchmark_env, "IPERF3_PROTOCOL", tolower(get_path(doc, c("start", "test_start", "protocol"), NA_character_))))
  connected <- first_connected(doc)
  test_start <- get_path(doc, c("start", "test_start"), default = list())
  sum_sent <- get_path(doc, c("end", "sum_sent"), default = list())
  sum_received <- get_path(doc, c("end", "sum_received"), default = list())
  fallback_sum <- get_path(doc, c("end", "sum"), default = list())
  cpu <- get_path(doc, c("end", "cpu_utilization_percent"), default = list())

  sender_bits <- to_num(get_path(sum_sent, c("bits_per_second"), NA_real_))
  receiver_bits <- to_num(get_path(sum_received, c("bits_per_second"), NA_real_))
  if (is.na(receiver_bits)) receiver_bits <- to_num(get_path(fallback_sum, c("bits_per_second"), NA_real_))

  jitter_ms <- lost_packets <- packets <- lost_percent <- NA_real_
  if (identical(protocol, "udp")) {
    udp_loss_source <- if (is.list(sum_received) && length(sum_received) > 0) sum_received else fallback_sum
    jitter_ms <- to_num(get_path(udp_loss_source, c("jitter_ms"), NA_real_))
    lost_packets <- to_num(get_path(udp_loss_source, c("lost_packets"), NA_real_))
    packets <- to_num(get_path(udp_loss_source, c("packets"), NA_real_))
    lost_percent <- to_num(get_path(udp_loss_source, c("lost_percent"), NA_real_))
  }

  tcp_length <- if (identical(protocol, "tcp")) env_get(benchmark_env, "IPERF3_TCP_LENGTH") else NA_character_
  tcp_length_bytes <- if (identical(protocol, "tcp")) parse_size_bytes(tcp_length) else NA_real_
  udp_target_bitrate <- if (identical(protocol, "udp")) env_get(benchmark_env, "IPERF3_UDP_BITRATE") else NA_character_
  udp_target_bitrate_bits <- if (identical(protocol, "udp")) {
    parse_rate_bits_per_sec(env_get(benchmark_env, "IPERF3_UDP_BITRATE", get_path(test_start, c("target_bitrate"), NA_real_)))
  } else {
    NA_real_
  }
  udp_length_bytes <- if (identical(protocol, "udp")) {
    to_num(env_get(benchmark_env, "IPERF3_UDP_LENGTH", get_path(test_start, c("blksize"), NA_real_)))
  } else {
    NA_real_
  }

  cbind(
    common_measurement_fields(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path),
    data.frame(
      protocol = protocol,
      runtime_sec = to_num(env_get(benchmark_env, "IPERF3_RUNTIME_SEC", get_path(test_start, c("duration"), NA_real_))),
      omit_sec = to_num(env_get(benchmark_env, "IPERF3_OMIT_SEC", get_path(test_start, c("omit"), NA_real_))),
      parallel_streams = to_num(env_get(benchmark_env, "IPERF3_PARALLEL", get_path(test_start, c("num_streams"), NA_real_))),
      tcp_length = tcp_length,
      tcp_length_bytes = tcp_length_bytes,
      udp_target_bitrate = udp_target_bitrate,
      udp_target_bitrate_bits_per_sec = udp_target_bitrate_bits,
      udp_target_bitrate_gbit_per_sec = udp_target_bitrate_bits / 1e9,
      udp_length_bytes = udp_length_bytes,
      sender_mbit_per_sec = sender_bits / 1e6,
      receiver_mbit_per_sec = receiver_bits / 1e6,
      sender_bytes = to_num(get_path(sum_sent, c("bytes"), NA_real_)),
      receiver_bytes = to_num(get_path(sum_received, c("bytes"), NA_real_)),
      retransmits = to_num(get_path(sum_sent, c("retransmits"), NA_real_)),
      jitter_ms = jitter_ms,
      lost_packets = lost_packets,
      packets = packets,
      lost_percent = lost_percent,
      cpu_host_total_pct = to_num(get_path(cpu, c("host_total"), NA_real_)),
      cpu_host_user_pct = to_num(get_path(cpu, c("host_user"), NA_real_)),
      cpu_host_system_pct = to_num(get_path(cpu, c("host_system"), NA_real_)),
      cpu_remote_total_pct = to_num(get_path(cpu, c("remote_total"), NA_real_)),
      cpu_remote_user_pct = to_num(get_path(cpu, c("remote_user"), NA_real_)),
      cpu_remote_system_pct = to_num(get_path(cpu, c("remote_system"), NA_real_)),
      client_ip = as.character(get_path(connected, c("local_host"), NA_character_)),
      server_ip = as.character(get_path(connected, c("remote_host"), NA_character_)),
      server_port = to_num(get_path(connected, c("remote_port"), NA_real_)),
      iperf3_version = as.character(get_path(doc, c("start", "version"), NA_character_)),
      timestamp = as.character(get_path(doc, c("start", "timestamp", "time"), NA_character_)),
      timestamp_epoch = to_num(get_path(doc, c("start", "timestamp", "timesecs"), NA_real_)),
      stringsAsFactors = FALSE
    )
  )
}

parse_iperf3_intervals <- function(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path) {
  doc <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(doc)) return(NULL)
  intervals <- get_path(doc, c("intervals"), default = list())
  if (!is.list(intervals) || length(intervals) == 0) return(NULL)
  protocol <- tolower(env_get(benchmark_env, "IPERF3_PROTOCOL", tolower(get_path(doc, c("start", "test_start", "protocol"), NA_character_))))

  rows <- lapply(seq_along(intervals), function(i) {
    interval <- intervals[[i]]
    sum <- get_path(interval, c("sum"), default = list())
    omitted <- as.logical(get_path(sum, c("omitted"), FALSE))
    cbind(
      common_measurement_fields(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path),
      data.frame(
        protocol = protocol,
        interval_index = i,
        interval_start_sec = to_num(get_path(sum, c("start"), NA_real_)),
        interval_end_sec = to_num(get_path(sum, c("end"), NA_real_)),
        interval_seconds = to_num(get_path(sum, c("seconds"), NA_real_)),
        omitted = omitted,
        perspective = "client_sender",
        bits_per_second = to_num(get_path(sum, c("bits_per_second"), NA_real_)),
        mbit_per_sec = to_num(get_path(sum, c("bits_per_second"), NA_real_)) / 1e6,
        bytes = to_num(get_path(sum, c("bytes"), NA_real_)),
        packets = to_num(get_path(sum, c("packets"), NA_real_)),
        retransmits = to_num(get_path(sum, c("retransmits"), NA_real_)),
        jitter_ms = to_num(get_path(sum, c("jitter_ms"), NA_real_)),
        lost_packets = to_num(get_path(sum, c("lost_packets"), NA_real_)),
        lost_percent = to_num(get_path(sum, c("lost_percent"), NA_real_)),
        stringsAsFactors = FALSE
      )
    )
  })
  bind_rows_with_schema(rows, iperf3_interval_cols)
}

extract_first_line <- function(lines, pattern) {
  hit <- grep(pattern, lines, perl = TRUE, value = TRUE)
  if (length(hit) == 0) return(NA_character_)
  hit[[1]]
}

extract_first_num <- function(lines, pattern) {
  line <- extract_first_line(lines, pattern)
  if (is.na(line)) return(NA_real_)
  m <- regexec(pattern, line, perl = TRUE)
  r <- regmatches(line, m)[[1]]
  if (length(r) < 2) return(NA_real_)
  to_num(r[[2]])
}

parse_sockperf_summary <- function(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path) {
  lines <- strip_ansi(readLines(path, warn = FALSE))
  if (length(lines) == 0) return(NULL)

  target_line <- extract_first_line(lines, "^\\[\\s*[0-9]+\\]\\s+IP\\s*=\\s*([^[:space:]]+)")
  target_ip <- if (is.na(target_line)) NA_character_ else sub("^\\[\\s*[0-9]+\\]\\s+IP\\s*=\\s*([^[:space:]]+).*$", "\\1", target_line, perl = TRUE)
  target_port <- if (is.na(target_line)) NA_real_ else to_num(sub("^.*PORT\\s*=\\s*([0-9]+).*$", "\\1", target_line, perl = TRUE))
  protocol <- tolower(env_get(benchmark_env, "SOCKPERF_PROTOCOL", if (grepl("# TCP", target_line, fixed = TRUE)) "tcp" else "udp"))

  # What the client actually delivered, as opposed to what it was asked for. A
  # rung whose achieved rate falls short of its offered rate is measuring the
  # generator's ceiling rather than the network's, and its latency figures
  # describe a load that was never applied.
  sent_messages <- extract_first_num(lines, "\\[Valid Duration\\].*SentMessages=([0-9]+)")
  valid_duration_sec <- extract_first_num(lines, "\\[Valid Duration\\]\\s+RunTime=([0-9.]+)\\s+sec")
  achieved_mps <- if (!is.na(sent_messages) && !is.na(valid_duration_sec) && valid_duration_sec > 0) {
    sent_messages / valid_duration_sec
  } else {
    NA_real_
  }

  cbind(
    common_measurement_fields(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path),
    data.frame(
      protocol = protocol,
      mode = env_get(benchmark_env, "SOCKPERF_MODE"),
      msg_size_bytes = to_num(env_get(benchmark_env, "SOCKPERF_MSG_SIZE")),
      configured_runtime_sec = to_num(env_get(benchmark_env, "SOCKPERF_RUNTIME_SEC")),
      # under-load only; NA for ping-pong, which has no controlled offered rate.
      offered_mps = to_num(env_get(benchmark_env, "SOCKPERF_MPS")),
      burst = to_num(env_get(benchmark_env, "SOCKPERF_BURST")),
      reply_every = to_num(env_get(benchmark_env, "SOCKPERF_REPLY_EVERY")),
      target_ip = target_ip,
      target_port = target_port,
      runtime_sec = extract_first_num(lines, "\\[Total Run\\]\\s+RunTime=([0-9.]+)\\s+sec"),
      warmup_msec = extract_first_num(lines, "Warm up time=([0-9.]+)\\s+msec"),
      valid_duration_sec = valid_duration_sec,
      sent_messages = sent_messages,
      received_messages = extract_first_num(lines, "\\[Valid Duration\\].*ReceivedMessages=([0-9]+)"),
      achieved_mps = achieved_mps,
      avg_rtt_us = extract_first_num(lines, "avg-rtt=([0-9.]+)"),
      stddev_rtt_us = extract_first_num(lines, "std-dev=([0-9.]+)"),
      min_rtt_us = extract_first_num(lines, "<MIN> observation\\s*=\\s*([0-9.]+)"),
      p25_rtt_us = extract_first_num(lines, "percentile\\s+25\\.000\\s*=\\s*([0-9.]+)"),
      p50_rtt_us = extract_first_num(lines, "percentile\\s+50\\.000\\s*=\\s*([0-9.]+)"),
      p75_rtt_us = extract_first_num(lines, "percentile\\s+75\\.000\\s*=\\s*([0-9.]+)"),
      p90_rtt_us = extract_first_num(lines, "percentile\\s+90\\.000\\s*=\\s*([0-9.]+)"),
      p99_rtt_us = extract_first_num(lines, "percentile\\s+99\\.000\\s*=\\s*([0-9.]+)"),
      p999_rtt_us = extract_first_num(lines, "percentile\\s+99\\.900\\s*=\\s*([0-9.]+)"),
      p9999_rtt_us = extract_first_num(lines, "percentile\\s+99\\.990\\s*=\\s*([0-9.]+)"),
      p99999_rtt_us = extract_first_num(lines, "percentile\\s+99\\.999\\s*=\\s*([0-9.]+)"),
      max_rtt_us = extract_first_num(lines, "<MAX> observation\\s*=\\s*([0-9.]+)"),
      dropped_messages = extract_first_num(lines, "# dropped messages =\\s*([0-9]+)"),
      duplicated_messages = extract_first_num(lines, "# duplicated messages =\\s*([0-9]+)"),
      out_of_order_messages = extract_first_num(lines, "# out-of-order messages =\\s*([0-9]+)"),
      stringsAsFactors = FALSE
    )
  )
}

# A run directory is one that holds scenario directories -- not one whose name
# matches the default timestamp format.
#
# Keying on the name alone silently loses data: --run-id accepts any string, so
# a run launched as --run-id stackit-ladder-01 produced a directory that "all"
# skipped without reporting anything. An explicit id at least failed loudly;
# "all" simply returned a smaller dataset than the artifacts on disk contained,
# which is the harder error to notice.
#
# The name pattern is kept as a fast path so an in-progress run whose
# scenario.env has not landed yet is still recognised. The structural test
# excludes artifacts/network/runner-control, whose immediate children are run
# directories rather than scenario directories.
discover_run_ids <- function(repo_root) {
  artifact_root <- file.path(repo_root, "artifacts", "network")
  if (!dir.exists(artifact_root)) return(character(0))
  dirs <- list.dirs(artifact_root, full.names = FALSE, recursive = FALSE)
  keep <- vapply(dirs, function(d) {
    if (grepl("^run-[0-9]{8}-[0-9]{6}$", d)) return(TRUE)
    scenario_dirs <- list.dirs(file.path(artifact_root, d), full.names = TRUE, recursive = FALSE)
    any(file.exists(file.path(scenario_dirs, "scenario.env")))
  }, logical(1))
  sort(dirs[keep])
}

discover_runs_with_scenarios <- function(repo_root, run_ids) {
  run_ids[vapply(run_ids, function(run_id) {
    length(Sys.glob(file.path(repo_root, "artifacts", "network", run_id, "*", "scenario.env"))) > 0
  }, logical(1))]
}

parse_run <- function(repo_root, run_id) {
  run_dir <- file.path(repo_root, "artifacts", "network", run_id)
  if (!dir.exists(run_dir)) stop(sprintf("Network artifacts directory not found: %s", run_dir))

  scenario_dirs <- list.dirs(run_dir, full.names = TRUE, recursive = FALSE)
  scenario_dirs <- scenario_dirs[file.exists(file.path(scenario_dirs, "scenario.env"))]

  scenario_rows <- list()
  iperf3_rows <- list()
  iperf3_interval_rows <- list()
  sockperf_rows <- list()
  failure_rows <- list()

  for (scenario_dir in scenario_dirs) {
    scenario_name <- basename(scenario_dir)
    # node-facts.env and cpu-idle.env are written by the runner alongside
    # scenario.env. Both are absent for runs recorded before those files
    # existed, in which case the columns they feed are simply NA.
    scenario_env <- merge_env(
      read_env_file(file.path(scenario_dir, "scenario.env")),
      read_env_file(file.path(scenario_dir, "node-facts.env")),
      read_env_file(file.path(scenario_dir, "os-tuning.env")),
      # The client is where latency is observed, so its facts carry the unadorned
      # column names. The server's are kept under SERVER_ so a pair whose two
      # ends differ is visible rather than represented by the client alone.
      read_env_file(file.path(scenario_dir, "cpu-idle-client.env")),
      prefix_env(read_env_file(file.path(scenario_dir, "server", "cpu-idle-server.env")), "SERVER_"),
      prefix_env(read_env_file(file.path(scenario_dir, "server", "node-facts.env")), "SERVER_"),
      # fetch_results.sh has always pulled the server os-tuning.env, but nothing
      # read it, so a pair where only one end accepted a profile looked fully
      # tuned. That matters most for the receive-path knobs: sockperf under-load
      # puts a receive path on both ends, so a busy_poll or rps_cpus setting that
      # took on the client and not on the server is a half-applied treatment.
      prefix_env(read_env_file(file.path(scenario_dir, "server", "os-tuning.env")), "SERVER_")
    )
    scenario_rows[[length(scenario_rows) + 1]] <- scenario_common_row(run_id, scenario_name, scenario_env)

    benchmark_dirs <- list.dirs(file.path(scenario_dir, "benchmarks"), full.names = TRUE, recursive = FALSE)
    benchmark_dirs <- benchmark_dirs[file.exists(file.path(benchmark_dirs, "benchmark.env"))]

    for (benchmark_dir in benchmark_dirs) {
      benchmark_name <- basename(benchmark_dir)
      benchmark_env <- read_env_file(file.path(benchmark_dir, "benchmark.env"))
      tool <- env_get(benchmark_env, "BENCHMARK_TOOL")
      rep_dirs <- list.dirs(benchmark_dir, full.names = TRUE, recursive = FALSE)
      rep_dirs <- rep_dirs[grepl("/rep-[0-9]+$", rep_dirs)]

      for (rep_dir in rep_dirs) {
        rep <- to_num(sub("^rep-", "", basename(rep_dir)))
        status_env <- read_env_file(file.path(rep_dir, "status.env"))
        rep_valid <- env_get(status_env, "REP_VALID")
        rep_status <- env_get(status_env, "REP_EXIT_STATUS")
        rep_reason <- env_get(status_env, "REP_FAILURE_REASON")

        path <- if (identical(tool, "iperf3")) {
          file.path(rep_dir, "client", "iperf3.json")
        } else if (identical(tool, "sockperf")) {
          file.path(rep_dir, "client", "sockperf.log")
        } else {
          NA_character_
        }

        # A repetition counts as failed when the runner recorded a non-zero exit
        # or when the expected output is simply absent. Both are invisible in
        # the measurement tables, which only ever contain rows that parsed.
        output_missing <- is.na(path) || !file.exists(path)
        if (identical(rep_valid, "0") || output_missing) {
          failure_rows[[length(failure_rows) + 1]] <- cbind(
            scenario_common_row(run_id, scenario_name, scenario_env),
            data.frame(
              benchmark_name = benchmark_name,
              benchmark_tool = tool,
              repetition = rep,
              expected_output = if (is.na(path)) NA_character_ else path,
              output_present = !output_missing,
              exit_status = to_num(rep_status),
              failure_reason = if (!is.na(rep_reason) && nzchar(rep_reason)) {
                rep_reason
              } else if (output_missing) {
                "benchmark output missing"
              } else {
                NA_character_
              },
              stringsAsFactors = FALSE
            )
          )
        }

        if (identical(tool, "iperf3")) {
          if (file.exists(path)) {
            iperf3_rows[[length(iperf3_rows) + 1]] <- parse_iperf3_summary(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path)
            iperf3_interval_rows[[length(iperf3_interval_rows) + 1]] <- parse_iperf3_intervals(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path)
          }
        } else if (identical(tool, "sockperf")) {
          if (file.exists(path)) {
            sockperf_rows[[length(sockperf_rows) + 1]] <- parse_sockperf_summary(run_id, scenario_name, scenario_env, benchmark_name, benchmark_env, rep, path)
          }
        }
      }
    }
  }

  list(
    scenarios = bind_rows_with_schema(scenario_rows, scenario_cols),
    iperf3 = bind_rows_with_schema(iperf3_rows, iperf3_cols),
    iperf3_intervals = bind_rows_with_schema(iperf3_interval_rows, iperf3_interval_cols),
    sockperf = bind_rows_with_schema(sockperf_rows, sockperf_cols),
    failures = bind_rows_with_schema(failure_rows, failure_cols)
  )
}

write_network_csvs <- function(repo_root = NULL, run_spec = NULL) {
  repo_root <- if (is.null(repo_root)) detect_repo_root() else normalizePath(repo_root)
  all_runs <- discover_run_ids(repo_root)
  if (length(all_runs) == 0) stop("No network run-* directories found under artifacts/network")

  if (is.null(run_spec) || !nzchar(run_spec)) {
    runs_with_scenarios <- discover_runs_with_scenarios(repo_root, all_runs)
    if (length(runs_with_scenarios) == 0) stop("No network runs with scenario.env found under artifacts/network")
    run_ids <- tail(runs_with_scenarios, 1)
    out_id <- run_ids[[1]]
  } else if (identical(run_spec, "all")) {
    run_ids <- all_runs
    out_id <- "all"
  } else if (grepl(",", run_spec, fixed = TRUE)) {
    run_ids <- trimws(strsplit(run_spec, ",", fixed = TRUE)[[1]])
    out_id <- paste(c("combined", run_ids), collapse = "__")
  } else {
    run_ids <- run_spec
    out_id <- run_spec
  }

  missing_runs <- setdiff(run_ids, all_runs)
  if (length(missing_runs) > 0) {
    stop(sprintf("Unknown network run id(s): %s", paste(missing_runs, collapse = ", ")))
  }

  parsed <- lapply(run_ids, function(run_id) parse_run(repo_root, run_id))
  out_dir <- file.path(repo_root, "analysis", "network", out_id)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  scenarios <- bind_rows_with_schema(lapply(parsed, `[[`, "scenarios"), scenario_cols)
  iperf3 <- bind_rows_with_schema(lapply(parsed, `[[`, "iperf3"), iperf3_cols)
  iperf3_intervals <- bind_rows_with_schema(lapply(parsed, `[[`, "iperf3_intervals"), iperf3_interval_cols)
  sockperf <- bind_rows_with_schema(lapply(parsed, `[[`, "sockperf"), sockperf_cols)
  failures <- bind_rows_with_schema(lapply(parsed, `[[`, "failures"), failure_cols)

  safe_write_csv(scenarios, file.path(out_dir, "network_scenarios.csv"), scenario_cols)
  safe_write_csv(iperf3, file.path(out_dir, "network_iperf3.csv"), iperf3_cols)
  safe_write_csv(iperf3_intervals, file.path(out_dir, "network_iperf3_intervals.csv"), iperf3_interval_cols)
  safe_write_csv(sockperf, file.path(out_dir, "network_sockperf.csv"), sockperf_cols)
  safe_write_csv(failures, file.path(out_dir, "network_failures.csv"), failure_cols)

  message(sprintf("Wrote network CSVs to %s", out_dir))
  message(sprintf("scenarios=%d iperf3=%d iperf3_intervals=%d sockperf=%d failures=%d",
                  nrow(scenarios), nrow(iperf3), nrow(iperf3_intervals), nrow(sockperf), nrow(failures)))
  if (nrow(failures) > 0) {
    message(sprintf("NOTE: %d repetition(s) produced no usable measurement; see network_failures.csv", nrow(failures)))
  }
  invisible(out_dir)
}

scenario_cols <- c(
  "run_id", "scenario_name", "is_control", "base_scenario_name", "provider",
  "client_machine_type", "server_machine_type",
  "client_availability_zone", "server_availability_zone",
  "placement_class", "placement_mode", "server_region", "pair_class",
  "instance_affinity", "os_tuning", "access_mode",
  "client_private_ip", "server_private_ip",
  "client_cpu_list", "server_cpu_list",
  "tuning_congestion_control", "tuning_qdisc",
  "tuning_rmem_max", "tuning_netdev_max_backlog", "tuning_netdev_budget",
  "busy_poll_requested", "tuning_busy_poll_usec", "tuning_busy_read_usec",
  "rps_cpus_requested", "rps_cpus_effective",
  "cpu_idle_pinning_requested", "cpu_idle_pinning_supported",
  "cpu_idle_pinning_verified", "cpu_idle_driver", "cpu_idle_states",
  "cpu_idle_deep_entries_delta",
  "cpufreq_driver", "cpufreq_governor", "cpufreq_available_governors",
  "cpufreq_governor_uniform", "cpufreq_cur_freq_khz",
  "cpufreq_min_freq_khz", "cpufreq_max_freq_khz",
  "server_cpu_idle_pinning_supported", "server_cpu_idle_pinning_verified",
  "server_cpu_idle_pinning_reason", "server_cpu_idle_driver",
  "server_cpu_idle_deep_entries_delta",
  "server_cpufreq_driver", "server_cpufreq_governor",
  "server_tuning_congestion_control", "server_tuning_netdev_budget",
  "server_tuning_busy_poll_usec", "server_rps_cpus_effective",
  "server_kernel_release", "server_primary_iface_mtu",
  "use_spot_requested", "purchase_model", "server_purchase_model",
  "kernel_release", "image_id", "primary_iface", "primary_iface_mtu",
  "irq_count", "irq_cpus", "irq_cpu_count", "irqbalance_running",
  "rx_queues", "tx_queues", "rps_enabled", "xps_enabled",
  "server_irq_cpus", "server_irq_cpu_count", "server_irqbalance_running",
  "server_rx_queues", "server_rps_enabled",
  "iperf3_tool_version", "sockperf_tool_version", "fio_tool_version"
)

measurement_prefix_cols <- c(
  scenario_cols,
  "benchmark_name", "benchmark_tool", "repetition", "configured_repetitions",
  "cooldown_sec", "source_file"
)

iperf3_cols <- c(
  measurement_prefix_cols,
  "protocol", "runtime_sec", "omit_sec", "parallel_streams",
  "tcp_length", "tcp_length_bytes",
  "udp_target_bitrate", "udp_target_bitrate_bits_per_sec", "udp_target_bitrate_gbit_per_sec",
  "udp_length_bytes",
  "sender_mbit_per_sec", "receiver_mbit_per_sec",
  "sender_bytes", "receiver_bytes", "retransmits",
  "jitter_ms", "lost_packets", "packets", "lost_percent",
  "cpu_host_total_pct", "cpu_host_user_pct", "cpu_host_system_pct",
  "cpu_remote_total_pct", "cpu_remote_user_pct", "cpu_remote_system_pct",
  "client_ip", "server_ip", "server_port",
  "iperf3_version", "timestamp", "timestamp_epoch"
)

iperf3_interval_cols <- c(
  measurement_prefix_cols,
  "protocol", "interval_index", "interval_start_sec", "interval_end_sec",
  "interval_seconds", "omitted", "perspective",
  "bits_per_second", "mbit_per_sec", "bytes", "packets", "retransmits",
  "jitter_ms", "lost_packets", "lost_percent"
)

sockperf_cols <- c(
  measurement_prefix_cols,
  "protocol", "mode", "msg_size_bytes", "configured_runtime_sec",
  "offered_mps", "burst", "reply_every",
  "achieved_mps",
  "target_ip", "target_port",
  "runtime_sec", "warmup_msec", "valid_duration_sec",
  "sent_messages", "received_messages",
  "avg_rtt_us", "stddev_rtt_us", "min_rtt_us",
  "p25_rtt_us", "p50_rtt_us", "p75_rtt_us", "p90_rtt_us",
  "p99_rtt_us", "p999_rtt_us", "p9999_rtt_us", "p99999_rtt_us",
  "max_rtt_us",
  "dropped_messages", "duplicated_messages", "out_of_order_messages"
)

failure_cols <- c(
  scenario_cols,
  "benchmark_name", "benchmark_tool", "repetition",
  "expected_output", "output_present", "exit_status", "failure_reason"
)

is_direct_cli_invocation <- function() {
  file_arg <- grep("^--file=", commandArgs(), value = TRUE)
  if (length(file_arg) == 0) return(FALSE)
  identical(basename(normalizePath(sub("^--file=", "", file_arg[[1]]), mustWork = FALSE)), "build_csv.R")
}

if (identical(environment(), globalenv()) && is_direct_cli_invocation()) {
  args <- commandArgs(trailingOnly = TRUE)
  run_spec <- if (length(args) >= 1) args[[1]] else NULL
  write_network_csvs(run_spec = run_spec)
}
