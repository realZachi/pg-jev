# PGXS build for the jev extension (PL/Python only, nothing to compile).
#
#   make install                # copies control + SQL into the server's extension dir
#   make installcheck           # pg_regress against a running server (needs test/mock_api.py, see README)
#   make docker-test            # full test run inside a throwaway container
#   make dist                   # zip for PGXN

EXTENSION    = jev
EXTVERSION   = $(shell grep default_version $(EXTENSION).control | sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")
DATA         = $(wildcard sql/$(EXTENSION)--*.sql)
DOCS         = README.md
REGRESS      = $(patsubst test/sql/%.sql,%,$(sort $(wildcard test/sql/*.sql)))
REGRESS_OPTS = --inputdir=test --outputdir=test --load-extension=plpython3u
PG_CONFIG   ?= pg_config
PGXS        := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

PG_MAJOR ?= 16

.PHONY: dist docker-test
dist:
	git archive --format zip --prefix=$(EXTENSION)-$(EXTVERSION)/ -o $(EXTENSION)-$(EXTVERSION).zip HEAD

docker-test:
	docker build --build-arg PG_MAJOR=$(PG_MAJOR) -t pg-jev-test -f test/Dockerfile .
	docker run --rm pg-jev-test
