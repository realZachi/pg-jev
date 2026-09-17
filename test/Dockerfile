# Throwaway image that installs the extension and runs the regression suite.
ARG PG_MAJOR=16
FROM postgres:${PG_MAJOR}
ARG PG_MAJOR
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-plpython3-${PG_MAJOR} postgresql-server-dev-${PG_MAJOR} make python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY . /src
WORKDIR /src
RUN make install && chown -R postgres:postgres /src
ENV POSTGRES_HOST_AUTH_METHOD=trust
USER postgres
CMD ["bash", "test/run.sh"]
