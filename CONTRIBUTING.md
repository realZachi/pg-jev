# Contributing

Thanks for helping. The extension is a single PL/Python function plus SQL wrappers, so most changes are small.

## Ground rules

- Open an issue before a large change so we can agree on the shape.
- Every behaviour change needs a regression test in `test/sql/` with matching `test/expected/` output.
  Tests run against `test/mock_api.py`, never the live API, so they are free and deterministic.
- Keep the SQL API stable. New functions are fine; changing signatures needs a major version and an upgrade script.
- Changes to the model prompt (the `instructions`/`criteria` built in `_jev_eval`) should come with a note on
  what you measured on real data, because they change results for every user.

## Workflow

```bash
make docker-test                  # full run in a container (PG_MAJOR=16 default)
make docker-test PG_MAJOR=14      # oldest supported major
```

Or locally with a server on `PATH`: `make install`, start `python3 test/mock_api.py`, then `make installcheck`.
When a test's output changes intentionally, copy `test/results/<name>.out` over `test/expected/<name>.out`
and review the diff.

## Versioning an SQL change

1. Bump `default_version` in `jev.control` and add a new `sql/jev--<new>.sql` (full install script).
2. Add an upgrade script `sql/jev--<old>--<new>.sql` so `ALTER EXTENSION jev UPDATE` works.
3. Update `META.json`, `CHANGELOG.md` and the version returned by `jev_version()`.

## Code of conduct

Be kind. Assume good intent. Disagreements go to the issue tracker, not to individuals.
