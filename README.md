# yocto-kas-community

Kas configuration for community Yocto test builds. For a given **release** (currently
wrynose) it builds a list of **targets** from upstream poky-style layers (OpenEmbedded-Core,
meta-openembedded and community BSP layers) to check that they build, and boot-tests the
QEMU targets. It replaces the old `repo` + `yocto-manifest` workflow.

Checkouts and build output are not in this repo. They live under a work directory you
configure per host.

## Vocabulary

The terms below are defined in [GLOSSARY.md](GLOSSARY.md).

- **Release**: a named Yocto release such as wrynose. Each release has its own kas file.
- **Target**: a MACHINE name built and tested for a release. The unit that gets built.
- **Kas file**: one kas YAML configuration.
- **Base config**: `kas/base.yml`, the settings every release's kas file includes.
- **Overlay**: a kas file in `kas/overlays/` that adds the vendor layers for one family of
  targets (meta-ti, meta-raspberrypi, ...). The driver includes it only for targets in that
  family.

## Layout

```
build.sh                 the driver: build one, several or all targets
all-targets.txt          the target file: every target and its overlay
local.env.example        template for the per-host environment file
kas/base.yml             base config
kas/<release>.yml        release kas file (pins the branch of each core layer)
kas/overlays/<name>.yml  overlays
kas/testimage.yml        boot-test settings, added for QEMU targets only
kas/patches/             patches kas applies to upstream layers that need them
scripts/                 helpers used by build.sh
tests/                   tests for the driver and a check that the kas files resolve
```

## Set up a host

1. Install kas 5.5 or newer and put it on `PATH`. The kas files use configuration format
   version 14.
2. Install the host packages the Yocto Project requires for builds, and make sure
   `python3` and `git` are available.
3. Clone this repo and create the environment file:

   ```sh
   cp local.env.example local.env
   ```

4. Edit `local.env` (git-ignored). All three paths are required:

   | Variable | Meaning |
   |---|---|
   | `DL_DIR` | Shared download cache, reused across releases and builds |
   | `SSTATE_DIR` | Shared sstate cache (also holds the hash equivalence database) |
   | `WORK_ROOT` | Per-release work directories are created under this |

   Optional: `BB_NUMBER_THREADS` and `PARALLEL_MAKE` cap build parallelism. Both default to
   the CPU count. Cap them on a host with unstable memory, for example
   `BB_NUMBER_THREADS=12` and `PARALLEL_MAKE=-j8`.

The driver exits with status 2 and names the problem if `local.env` or one of the three
variables is missing.

## Build

```sh
./build.sh [--update] <release> [target...]
```

```sh
./build.sh wrynose                           # every target in all-targets.txt
./build.sh wrynose qemux86-64                # one target
./build.sh wrynose beagleplay raspberrypi4-64
./build.sh --update wrynose               # first move the checkouts to the current branch tips
```

Targets are built in the order they appear in `all-targets.txt`, whatever order you name
them. A failed target does not stop the rest. Each target is built with
`kas/<release>.yml`, plus its overlay if it has one.

The work directory for a release is `$WORK_ROOT/<release>/`:

- the layer checkouts, which kas creates on first use
- `build/`, the BitBake build directory shared by all targets of the release. Images are in
  `build/tmp/deploy/images/<machine>/`.
- `logs/<timestamp>/<machine>.log`, one log per target for each run

When all targets have been tried the driver prints a summary, one line per target:

```
== Summary ==
PASS  qemux86-64
FAIL  milkv-duo  build  /path/to/logs/20261122-101500/milkv-duo.log
```

A failure is labeled `build`, `boot-test` (QEMU targets only) or `manifest` (see below),
and names the log. The exit status is 0 if every target passed, 1 if any failed, and 2 for a
usage or configuration error (unknown release, unknown target, missing `local.env`).

## The target file

`all-targets.txt` lists the targets. Each line is two whitespace-separated columns:

```
# machine            overlay   ('-' = no overlay)
beagleplay           ti
qemux86-64           -
```

- The first column is the MACHINE name. It is passed to kas as `KAS_MACHINE`.
- The second column is the overlay name, meaning `kas/overlays/<name>.yml`, or `-` for none.
- Blank lines and lines starting with `#` are ignored.
- The driver rejects a target name on the command line that is not in this file.

To add a target, add a line. If it needs layers that no existing overlay provides, add an
overlay under `kas/overlays/` first.

## Boot tests

Targets whose name starts with `qemu` are boot-tested. The driver builds them with
`kas/testimage.yml` added (it enables the login features the test needs), then runs
`kas build --task testimage`, which boots the image under QEMU and runs the `ping` and `ssh`
suites. A boot failure shows as `FAIL <target> boot-test` in the summary.

Hardware targets are built only. Nothing here boots them.

## Build records

After each successful build, the driver resolves the floating refs with `kas dump
--resolve-refs --resolve-local` and writes `build-manifest.json` next to that machine's
images (`build/tmp/deploy/images/<machine>/`). It records the release, machine, image, build
host and time, and for every layer the exact revision and its upstream branch. This repo
appears as the layer `this`. The schema matches the `yocto-build-manifest` script used with
the old workflow.

A failed build writes no record. If the record itself cannot be written, the target shows as
`FAIL <target> manifest`.

## Reproduce a failure with a lockfile

The release kas files track branches, so a rebuild can pick up different upstream commits.
To rebuild exactly what failed, pin the commits with a kas lockfile.

1. On the host that has the failing checkouts, write the lockfile for the failing target's
   configuration. It must be named after the release kas file and sit beside it:

   ```sh
   set -a; . ./local.env; set +a
   KAS_WORK_DIR="$WORK_ROOT/wrynose" kas dump --lock \
       kas/wrynose.yml:kas/overlays/ti.yml > /tmp/wrynose.lock.yml
   mv /tmp/wrynose.lock.yml kas/wrynose.lock.yml
   ```

   Leave out the overlay for a target that has none. Do not redirect straight into
   `kas/wrynose.lock.yml`: the shell empties the file first, and kas then fails trying to load
   it. Delete an existing lockfile before writing a new one.

2. Copy `kas/wrynose.lock.yml` to the host that should reproduce the failure (or commit it
   deliberately, see below) and run the same `./build.sh` command there. kas finds
   `kas/<release>.lock.yml` on its own, so `build.sh` needs no option. Every target in that
   run is built at the pinned commits.

3. Delete the lockfile to go back to floating refs.

The lockfile is an `overrides:` list of commits. A lock that pins repos a target does not use
is accepted, so one lock can cover several overlays if you merge the lists by hand.

`*.lock.yml` is git-ignored because a lockfile is generated to reproduce one failure, and
committing one by accident would pin every later run. To commit one on purpose, use
`git add -f`.

## Updating the checkouts

kas reuses an existing checkout as it is and fetches new upstream commits only when asked
with `--update`. Without it, a work directory stays at the commits it first cloned, even
though the kas files name branches. Pass `--update` to `build.sh` to move the checkouts to
the current branch tips as part of the build:

```sh
./build.sh --update wrynose
```

The flag goes to the `kas build` step of every target, not to the boot test. Targets that
share layers fetch them again, so if upstream pushes during a long run, later targets can
build newer commits than earlier ones. The build record of each target shows which.

## Tests

```sh
tests/test-build.sh      # the driver, run against a stubbed kas
tests/check-configs.sh   # every release kas file still resolves (no build)
```

## Attribution

The agent skills in `.claude/skills/` are copied from
[mattpocock/skills](https://github.com/mattpocock/skills), Copyright (c) 2026 Matt Pocock,
used under the MIT License. Versions are pinned in `skills-lock.json`.
