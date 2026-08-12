#!/usr/bin/env Rscript

detect_repo_root <- function() {
  file_arg <- grep("^--file=", commandArgs(), value = TRUE)
  if (length(file_arg) > 0) {
    script_path <- normalizePath(sub("^--file=", "", file_arg[[1]]))
    return(normalizePath(file.path(dirname(script_path), "..", "..")))
  }
  normalizePath(getwd())
}

repo_root <- detect_repo_root()
args <- commandArgs(trailingOnly = TRUE)

usage <- function() {
  cat(
    "usage: render_network_benchmark_analysis.R [RESULT_ID] [--config FILE] [--note TEXT]\n",
    file = stderr()
  )
}

# Flag parsing mirrors analysis/storage/render_storage_benchmark_analysis.R.
# Bare positional arguments keep working so existing invocations are unaffected.
result_id <- "all"
config_file <- NULL
note <- NULL
positional <- character(0)

i <- 1
while (i <= length(args)) {
  arg <- args[[i]]
  if (arg == "--config") {
    if (i == length(args)) {
      usage()
      stop("--config requires a file path")
    }
    config_file <- args[[i + 1]]
    i <- i + 2
  } else if (arg == "--note") {
    if (i == length(args)) {
      usage()
      stop("--note requires text")
    }
    note <- args[[i + 1]]
    i <- i + 2
  } else if (startsWith(arg, "--")) {
    usage()
    stop(sprintf("unknown option: %s", arg))
  } else {
    positional <- c(positional, arg)
    i <- i + 1
  }
}

if (length(positional) >= 1 && nzchar(positional[[1]])) result_id <- positional[[1]]
if (length(positional) >= 2 && nzchar(positional[[2]]) && is.null(note)) note <- positional[[2]]

if (!is.null(config_file)) {
  if (!grepl("^/", config_file)) config_file <- file.path(repo_root, config_file)
  config_file <- normalizePath(config_file, mustWork = TRUE)
}

source(file.path(repo_root, "analysis", "network", "build_csv.R"), local = TRUE)
write_network_csvs(repo_root = repo_root, run_spec = result_id)

if (grepl(",", result_id, fixed = TRUE)) {
  run_ids <- trimws(strsplit(result_id, ",", fixed = TRUE)[[1]])
  result_id <- paste(c("combined", run_ids), collapse = "__")
}

output_dir <- file.path(repo_root, "analysis", "network", result_id)
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

output_file <- sprintf("network_benchmark_analysis_%s.html", result_id)

rmarkdown::render(
  input = file.path(repo_root, "analysis", "network", "network_benchmark_analysis.Rmd"),
  params = list(result_id = result_id, note = note, config_file = config_file),
  output_file = output_file,
  output_dir = output_dir,
  envir = new.env(parent = globalenv())
)
