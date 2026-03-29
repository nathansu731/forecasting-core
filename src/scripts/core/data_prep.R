normalize_columns <- function(df) {
  names(df) <- trimws(tolower(names(df)))
  if ("isle" %in% names(df) && ! ("aisle" %in% names(df))) {
    names(df)[names(df) == "isle"] <- "aisle"
  }
  df
}

normalize_column_key <- function(value) {
  key <- tolower(trimws(as.character(value)))
  gsub("[^a-z0-9]+", "", key)
}

parse_dates_by_format <- function(values, date_format) {
  format_key <- normalize_column_key(ifelse(is.null(date_format) || date_format == "", "dd/mm/yyyy", date_format))
  format_map <- list(
    "ddmmyyyy" = "%d/%m/%Y",
    "mmddyyyy" = "%m/%d/%Y",
    "yyyymmdd" = "%Y-%m-%d"
  )

  fmt <- format_map[[format_key]]
  parsed <- if (!is.null(fmt)) as.Date(values, format = fmt) else as.Date(values)
  if (all(is.na(parsed))) {
    parsed <- as.Date(values, tryFormats = c("%d/%m/%Y", "%m/%d/%Y", "%Y-%m-%d", "%Y/%m/%d"))
  }
  parsed
}

safe_bool <- function(x) {
  value <- tolower(as.character(x))
  value %in% c("true", "1", "yes", "y")
}

calc_status <- function(variance) {
  if (is.na(variance)) return("stable")
  if (variance > 0.05) return("positive")
  if (variance < -0.05) return("negative")
  "stable"
}

resolve_column <- function(df, candidates) {
  for (candidate in candidates) {
    if (candidate %in% names(df)) return(candidate)
  }
  NULL
}

detect_frequency <- function(dates) {
  unique_dates <- sort(unique(as.Date(dates)))
  if (length(unique_dates) < 2) return("daily")
  diffs <- diff(unique_dates)
  median_days <- median(as.numeric(diffs))
  if (is.na(median_days) || median_days <= 1) return("daily")
  if (median_days <= 7) return("weekly")
  if (median_days <= 31) return("monthly")
  if (median_days <= 92) return("quarterly")
  "yearly"
}

period_key <- function(date, frequency) {
  d <- as.Date(date)
  if (frequency == "daily") return(format(d, "%Y-%m-%d"))
  if (frequency == "weekly") {
    start <- d - as.integer(format(d, "%u")) + 1
    return(format(start, "%Y-%m-%d"))
  }
  if (frequency == "monthly") return(format(d, "%m-%Y"))
  if (frequency == "quarterly") {
    q <- ((as.integer(format(d, "%m")) - 1) %/% 3) + 1
    return(paste0("Q", q, "-", format(d, "%Y")))
  }
  format(d, "%Y")
}

period_start <- function(date, frequency) {
  d <- as.Date(date)
  if (frequency == "daily") return(d)
  if (frequency == "weekly") return(d - as.integer(format(d, "%u")) + 1)
  if (frequency == "monthly") return(as.Date(format(d, "%Y-%m-01")))
  if (frequency == "quarterly") {
    m <- as.integer(format(d, "%m"))
    q_start <- (m - 1) %/% 3 * 3 + 1
    return(as.Date(paste0(format(d, "%Y"), "-", sprintf("%02d", q_start), "-01")))
  }
  as.Date(paste0(format(d, "%Y"), "-01-01"))
}

sequence_periods <- function(last_date, frequency, horizon) {
  if (frequency == "daily") return(seq(last_date + 1, by = "day", length.out = horizon))
  if (frequency == "weekly") return(seq(last_date + 7, by = "7 days", length.out = horizon))
  if (frequency == "monthly") return(seq(last_date %m+% months(1), by = "1 month", length.out = horizon))
  if (frequency == "quarterly") return(seq(last_date %m+% months(3), by = "3 months", length.out = horizon))
  seq(last_date %m+% years(1), by = "1 year", length.out = horizon)
}

to_named_map <- function(keys, values) {
  result <- as.list(values)
  names(result) <- keys
  result
}
