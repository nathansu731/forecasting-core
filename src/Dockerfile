# ---- Stage 1: Build R from source on Amazon Linux 2 ----
FROM amazonlinux:2 AS r-builder

ARG R_VERSION=4.3.3

RUN yum update -y && yum install -y \
    gcc gcc-c++ gcc-gfortran make cmake \
    libgfortran libgfortran-devel \
    libcurl-devel libxml2-devel \
    readline-devel pcre2-devel zlib-devel bzip2 bzip2-devel xz xz-devel \
    tar gzip wget curl which perl perl-core ncurses-devel \
    pkgconfig libicu-devel \
    blas-devel lapack-devel \
    openblas-devel \
    openssl11 openssl11-devel \
    texinfo git \
    && yum clean all

ENV CC=/usr/bin/gcc
ENV CXX=/usr/bin/g++
ENV FC=/usr/bin/gfortran

WORKDIR /tmp

# Build R from source
RUN curl -fsSL https://cran.r-project.org/src/base/R-4/R-${R_VERSION}.tar.gz -o R-${R_VERSION}.tar.gz \
 && tar -xzf R-${R_VERSION}.tar.gz \
 && cd R-${R_VERSION} \
 && ./configure --prefix=/opt/R/${R_VERSION} --enable-R-shlib --with-x=no --without-recommended-packages \
 && make -j"$(nproc)" \
 && make install

# Install R packages here (while compiler is available)
COPY requirements.R /tmp/requirements.R
COPY requirements.lock /tmp/requirements.lock
RUN cat <<'RSCRIPT' > /tmp/install_packages.R
options(download.file.method = "libcurl")
deps <- c("Depends", "Imports", "LinkingTo")

read_lock_config <- function(path) {
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nzchar(lines)]
  keys <- sub("=.*$", "", lines)
  values <- sub("^[^=]+=", "", lines)
  stats::setNames(as.list(values), keys)
}

lock_config <- read_lock_config("/tmp/requirements.lock")
snapshot_repo <- lock_config[["SNAPSHOT_REPO"]]
if (is.null(snapshot_repo) || !nzchar(snapshot_repo)) {
  stop("requirements.lock is missing SNAPSHOT_REPO")
}
fallback_repo <- lock_config[["FALLBACK_REPO"]]
if (is.null(fallback_repo) || !nzchar(fallback_repo)) {
  fallback_repo <- "https://cloud.r-project.org"
}
repos <- c(PRIMARY = snapshot_repo, FALLBACK = fallback_repo)
message("Using locked CRAN snapshot repo: ", snapshot_repo)
message("Using CRAN fallback repo: ", fallback_repo)

ensure_matrix <- function() {
  if ("Matrix" %in% rownames(installed.packages())) return(invisible(TRUE))
  message("Installing Matrix from locked archive URL")
  url <- lock_config[["MATRIX_URL"]]
  tryCatch({
    install.packages(url, repos = NULL, type = "source", dependencies = deps, quiet = TRUE)
  }, error = function(e) {
    message("Matrix install failed: ", e$message)
  })
}

ensure_matrix()

install_source_with_log <- function(url, package_name) {
  tarball <- basename(url)
  dest <- file.path("/tmp", tarball)
  log_file <- file.path("/tmp", paste0(package_name, "_install.log"))
  unlink(dest)
  unlink(log_file)
  download.file(url, destfile = dest, quiet = TRUE)
  cmd <- sprintf(
    "cd /tmp && /opt/R/${R_VERSION}/bin/R CMD INSTALL %s > %s 2>&1",
    shQuote(dest),
    shQuote(log_file)
  )
  status <- system(cmd)
  if (!identical(status, 0L)) {
    message(package_name, " source install failed. Last 200 log lines:")
    if (file.exists(log_file)) {
      lines <- readLines(log_file, warn = FALSE)
      tail_n <- min(length(lines), 200L)
      if (tail_n > 0) cat(paste(tail(lines, tail_n), collapse = "\n"), "\n")
    }
    return(FALSE)
  }
  TRUE
}

ensure_data_table <- function() {
  if ("data.table" %in% rownames(installed.packages())) return(invisible(TRUE))
  message("Installing data.table from CRAN")
  tryCatch({
    install.packages("data.table", repos = repos, dependencies = deps, Ncpus = 1, quiet = FALSE)
  }, error = function(e) {
    message("data.table install failed: ", e$message)
  })
}

ensure_xgboost <- function() {
  if ("xgboost" %in% rownames(installed.packages())) return(invisible(TRUE))
  ensure_data_table()
  if (!("data.table" %in% rownames(installed.packages()))) {
    message("Skipping xgboost archive install because data.table is unavailable")
    return(invisible(FALSE))
  }
  message("Installing xgboost from locked archive URL")
  url <- lock_config[["XGBOOST_URL"]]
  tryCatch({
    install_source_with_log(url, "xgboost")
  }, error = function(e) {
    message("xgboost archive install failed: ", e$message)
  })
}

pkgs <- Filter(nzchar, readLines("/tmp/requirements.R"))
failed <- c()
for (p in pkgs) {
  if (p == "Matrix") {
    if ("Matrix" %in% rownames(installed.packages())) {
      message("Matrix already installed, skipping CRAN install")
      next
    }
    message("Matrix missing after ensure_matrix; attempting archive install again")
    ensure_matrix()
    if ("Matrix" %in% rownames(installed.packages())) {
      next
    }
  }
  if (p == "xgboost") {
    ensure_xgboost()
    if ("xgboost" %in% rownames(installed.packages())) {
      next
    }
    failed <- c(failed, p)
    message("xgboost missing after pinned archive install; skipping latest CRAN fallback on AL2/GCC 7")
    next
  }
  message("begin installing package ", p)
  ok <- TRUE
  tryCatch({
    install.packages(p, repos = repos, dependencies = deps, Ncpus = 1, quiet = FALSE)
  }, error = function(e) {
    ok <<- FALSE
    message("install failed for ", p, ": ", e$message)
  })
  if (!(p %in% rownames(installed.packages()))) {
    ok <- FALSE
  }
  if (!ok) failed <- c(failed, p)
}
if (length(failed)) {
  message("Missing R packages: ", paste(failed, collapse = ", "))
  stop("R package install incomplete")
}
if (!("RcppArmadillo" %in% rownames(installed.packages()))) {
  message("RcppArmadillo install failed. Showing config.log if present.")
  if (file.exists("/tmp/RcppArmadillo_config.log")) {
    cat(readLines("/tmp/RcppArmadillo_config.log"), sep = "\n")
  }
}
if (!("xgboost" %in% rownames(installed.packages()))) {
  message("xgboost install failed. Dumping site-library contents for inspection.")
  print(.libPaths())
  print(rownames(installed.packages()))
}
installed_summary <- installed.packages()[, c("Package", "Version")]
installed_summary <- installed_summary[order(installed_summary[, "Package"]), , drop = FALSE]
write.table(
  installed_summary,
  file = "/tmp/installed-r-packages.lock",
  sep = "\t",
  quote = FALSE,
  row.names = FALSE
)
RSCRIPT
RUN /opt/R/${R_VERSION}/bin/Rscript -e "lock <- readLines('/tmp/requirements.lock'); repo <- sub('^[^=]+=','', lock[grepl('^SNAPSHOT_REPO=', lock)]); download.packages('Rcpp', destdir='/tmp', type='source', repos=repo)" \
    || /opt/R/${R_VERSION}/bin/Rscript -e "lock <- readLines('/tmp/requirements.lock'); repo <- sub('^[^=]+=','', lock[grepl('^FALLBACK_REPO=', lock)]); if (!length(repo)) repo <- 'https://cloud.r-project.org'; download.packages('Rcpp', destdir='/tmp', type='source', repos=repo)" \
    && TAR_FILE=$(ls /tmp/Rcpp_*.tar.gz | head -n 1) \
    && /opt/R/${R_VERSION}/bin/R CMD INSTALL $TAR_FILE
RUN RCPPARMA_URL=$(awk -F= '/^RCPPARMADILLO_URL=/{print $2}' /tmp/requirements.lock) \
    && curl -fsSL "${RCPPARMA_URL}" -o /tmp/RcppArmadillo.tar.gz \
    && /opt/R/${R_VERSION}/bin/R CMD INSTALL /tmp/RcppArmadillo.tar.gz > /tmp/rcpparmadillo.log 2>&1 \
    || (echo 'RcppArmadillo install log:' && tail -n 200 /tmp/rcpparmadillo.log && exit 1)
RUN /opt/R/${R_VERSION}/bin/Rscript /tmp/install_packages.R

# ---- Stage 2: Lambda runtime with R ----
FROM public.ecr.aws/lambda/provided:al2

ARG R_VERSION=4.3.3

# Runtime dependencies only (no gcc here)
RUN yum install -y \
    libgfortran \
    libgomp \
    zlib bzip2 xz \
    libcurl \
    libxml2 \
    pcre pcre2 \
    readline ncurses \
    expat krb5-libs \
    tar gzip which \
    && yum clean all

# Copy R + prebuilt packages
COPY --from=r-builder /opt/R/${R_VERSION} /opt/R/${R_VERSION}
COPY --from=r-builder /tmp/installed-r-packages.lock /opt/R/${R_VERSION}/installed-r-packages.lock

# Set R environment
ENV PATH="/opt/R/${R_VERSION}/bin:${PATH}"
ENV R_HOME="/opt/R/${R_VERSION}/lib64/R"

# Copy app code + bootstrap
WORKDIR /var/task
COPY scripts/ /var/task/scripts/
COPY entrypoint.R /var/task/
COPY bootstrap /var/task/bootstrap
RUN chmod +x /var/task/bootstrap \
    && chmod -R a+rX /var/task/scripts \
    && chmod a+r /var/task/entrypoint.R

# Lambda entrypoint
ENTRYPOINT ["/var/task/bootstrap"]
