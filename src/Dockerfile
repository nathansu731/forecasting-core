# ---- Stage 1: Build R from source on Amazon Linux 2 ----
FROM amazonlinux:2 AS r-builder

ARG R_VERSION=4.3.3

RUN yum update -y && yum install -y \
    gcc gcc-c++ gcc-gfortran make \
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
RUN cat <<'RSCRIPT' > /tmp/install_packages.R
options(download.file.method = "libcurl")
repos <- "https://cloud.r-project.org"
deps <- c("Depends", "Imports", "LinkingTo")

ensure_matrix <- function() {
  if ("Matrix" %in% rownames(installed.packages())) return(invisible(TRUE))
  message("Installing Matrix from CRAN archive (R 4.3.x compatible)")
  url <- "https://cran.r-project.org/src/contrib/Archive/Matrix/Matrix_1.6-5.tar.gz"
  tryCatch({
    install.packages(url, repos = NULL, type = "source", dependencies = deps, quiet = TRUE)
  }, error = function(e) {
    message("Matrix install failed: ", e$message)
  })
}

ensure_matrix()

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
  message("begin installing package ", p)
  ok <- TRUE
  tryCatch({
    install.packages(p, repos = repos, dependencies = deps, Ncpus = 1, quiet = TRUE)
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
RSCRIPT
RUN /opt/R/${R_VERSION}/bin/Rscript -e "download.packages('Rcpp', destdir='/tmp', type='source', repos='https://cloud.r-project.org')" \
    && TAR_FILE=$(ls /tmp/Rcpp_*.tar.gz | head -n 1) \
    && /opt/R/${R_VERSION}/bin/R CMD INSTALL $TAR_FILE
RUN RCPPARMA_VER=0.12.4.1.0 \
    && curl -fsSL https://cran.r-project.org/src/contrib/Archive/RcppArmadillo/RcppArmadillo_${RCPPARMA_VER}.tar.gz -o /tmp/RcppArmadillo_${RCPPARMA_VER}.tar.gz \
    && /opt/R/${R_VERSION}/bin/R CMD INSTALL /tmp/RcppArmadillo_${RCPPARMA_VER}.tar.gz > /tmp/rcpparmadillo.log 2>&1 \
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

# Set R environment
ENV PATH="/opt/R/${R_VERSION}/bin:${PATH}"
ENV R_HOME="/opt/R/${R_VERSION}/lib64/R"

# Copy app code + bootstrap
WORKDIR /var/task
COPY scripts/ /var/task/scripts/
COPY entrypoint.R /var/task/
COPY bootstrap /var/task/bootstrap
RUN chmod +x /var/task/bootstrap

# Lambda entrypoint
ENTRYPOINT ["/var/task/bootstrap"]
