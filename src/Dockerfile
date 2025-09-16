# ---- Stage 1: Build R from source on Amazon Linux 2 ----
FROM amazonlinux:2 AS r-builder

ARG R_VERSION=4.3.3

RUN yum update -y && yum install -y \
    gcc gcc-c++ gcc-gfortran make \
    libcurl-devel libxml2-devel openssl-devel \
    readline-devel pcre2-devel zlib-devel bzip2 bzip2-devel xz xz-devel \
    tar gzip wget curl which perl perl-core ncurses-devel \
    texinfo git \
    && yum clean all

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
RUN /opt/R/${R_VERSION}/bin/Rscript -e "pkgs <- Filter(nzchar, readLines('/tmp/requirements.R')); \
    if (length(pkgs)) install.packages(pkgs, repos='https://cloud.r-project.org')"

# ---- Stage 2: Lambda runtime with R ----
FROM public.ecr.aws/lambda/provided:al2

ARG R_VERSION=4.3.3

# Runtime dependencies only (no gcc here)
RUN yum update -y && yum install -y \
    libgfortran \
    libgomp \
    zlib bzip2 xz \
    libcurl \
    libxml2 \
    openssl \
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
