FROM public.ecr.aws/lambda/provided:al2

# Install R
RUN yum install -y R R-devel

# Copy R scripts
COPY scripts/ /var/task/scripts/
COPY entrypoint.R /var/task/

# Install R dependencies
COPY requirements.R /tmp/requirements.R
RUN Rscript -e "pkgs <- readLines('/tmp/requirements.R'); install.packages(pkgs, repos='https://cloud.r-project.org')"

# Set Lambda entrypoint
CMD [ "entrypoint.handler" ]
