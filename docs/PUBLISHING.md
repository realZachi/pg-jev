# Publishing a PostgreSQL extension

This is the checklist for releasing `jev`. It doubles as a guide to how PostgreSQL extensions reach developers.

## Where developers get extensions

| Channel | What it is | How they install |
| --- | --- | --- |
| **GitHub / git** | Source of truth. `make install` via PGXS works on any machine with `pg_config`. | `git clone … && make install` |
| **PGXN** (pgxn.org) | The PostgreSQL Extension Network: a CPAN-style index of source distributions. Requires a (free, manually approved) account at manager.pgxn.org. | `pgxn install jev` |
| **Trunk** (pgt.dev) | Pre-built binaries per PG version; used by Tembo and others. Optional. | `trunk install jev` |
| **pgxman** | apt-style packages for extensions. Optional. | `pgxman install jev` |
| **Docker image** | Easiest way to try it. Publish to GHCR or Docker Hub. | `docker run ghcr.io/realzachi/pg-jev` |
| **Distro / PGDG packages** | Debian/RPM packages in apt.postgresql.org and yum.postgresql.org. Ask the PGDG packagers on the pgsql-pkg lists once the project is stable. | `apt install postgresql-16-jev` |
| **Managed providers** | RDS, Cloud SQL, Neon, Supabase etc. each curate their own allow-list. Only reachable by request, and `plpython3u` is not allowed on most of them. | – |

For a PL/Python extension like this one there is nothing to compile, so the source distribution *is* the
binary: PGXN plus a Docker image covers nearly everyone.

## Release checklist

1. **Version bump.** Update `default_version` in `jev.control`, rename/add `sql/jev--X.Y.Z.sql`, add an upgrade
   script `sql/jev--OLD--NEW.sql` if the SQL objects changed, update `jev_version()`, `META.json`, `CHANGELOG.md`.
2. **Test.** `make docker-test PG_MAJOR=14` … `17`. CI does the same on every push.
3. **Check the bundle.** `docker run --rm --platform linux/amd64 -v "$PWD":/repo -w /repo pgxn/pgxn-tools pgxn-bundle`
   validates `META.json` and writes `jev-X.Y.Z.zip` (same content as `make dist`; `.gitattributes` keeps
   `.agents`, `.claude`, `.github` and dotfiles out of it). Note that `git archive` reads `.gitattributes` from the
   commit, so those rules have to be committed to take effect.
4. **Tag.** `git tag -a vX.Y.Z -m "jev X.Y.Z" && git push origin vX.Y.Z`. The release workflow attaches the zip
   to a GitHub release and, when the `PGXN_USERNAME` / `PGXN_PASSWORD` repository secrets are set, uploads it to
   PGXN with `pgxn-release`. The distribution appears at https://pgxn.org/dist/jev/ within minutes and is then
   installable with `pgxn install jev`.
   Manual alternative: upload the zip at https://manager.pgxn.org/upload. A version can only be released once;
   fixing a published release means bumping the version.
5. **Docker.** `docker build -t ghcr.io/realzachi/pg-jev:X.Y.Z-pg16 --build-arg PG_MAJOR=16 .` for each supported
   major, push, and add `latest`.
6. **Announce.** pgsql-announce@lists.postgresql.org (moderated, extensions welcome), the PostgreSQL
   Slack/Discord `#extensions`, and the TypeSafe community.

## What a good extension repo has

- `EXTENSION.control` + `sql/EXTENSION--VERSION.sql`, versioned, with upgrade scripts between releases.
- A PGXS `Makefile` so `make install` and `make installcheck` just work.
- `META.json` (PGXN spec 1.0.0) with abstract, license, provides, prereqs and resources.
- An OSI license. PostgreSQL License and MIT are the norm in this ecosystem.
- Regression tests (`pg_regress`) that don't depend on network or secrets.
- CI across all supported PostgreSQL majors.
- README covering install, every function and setting, security notes, and cost.
- CHANGELOG, CONTRIBUTING, and a clear statement of which PostgreSQL versions are supported.
