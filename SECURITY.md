# Security policy

## Supported versions

Azu is released from `master` on every green merge (see the `release` job in `.github/workflows/crystal.yml`). Security
fixes land on `master` and ship in the next release; they are not backported to earlier minor versions. Keep your
application on the latest release of the minor line you use (`version: ~> 0.10.0` in `shard.yml` follows the
patch releases of 0.10) and read [Breaking changes](docs/reference/breaking-changes.md) before moving to a newer minor.

| Version | Supported |
| --- | --- |
| latest release | yes |
| earlier releases | no: upgrade |

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/azutoolkit/azu/security/advisories/new) for this
repository, or by email to the maintainer listed in `shard.yml`.

Include what you can of: the affected component (handler, helper, Spark, the CQL bridge, ...), the version, a
reproduction (a request, a template, a spec), and the impact you see.

What to expect:

- an acknowledgement within 5 working days;
- a fix or a mitigation on `master` as soon as one is ready, with a GitHub security advisory and a CVE where one applies;
- credit in the advisory unless you prefer otherwise;
- a coordinated disclosure window of up to 90 days from the report, shorter once a release carries the fix.

## Scope

In scope: the framework itself (`src/`), the Spark browser client (`js/`, shipped as `src/azu/spark/client/azu_spark.js`)
and the code Azu generates through the [Azu CLI](https://github.com/azutoolkit/azu_cli).

Out of scope: vulnerabilities in dependencies (report them to the dependency, and tell us so we can pin a fixed version),
the playground and benchmark applications, and findings that need a misconfiguration the documentation warns against
(for example running with `CRYSTAL_ENV` unset on a public interface, or `TEMPLATE_AUTOESCAPE=false`).
