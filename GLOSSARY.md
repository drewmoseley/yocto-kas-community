# Community Yocto Test Builds

Kas configuration for building upstream Yocto (poky and community layers) at a given release, to check that it builds and boots.

## Language

**Release**:
A named Yocto release, e.g. wrynose. Each release has its own kas file.
_Avoid_: Version, branch

**Target**:
A MACHINE name built and tested for a release. The unit that gets built.
_Avoid_: Build, config, job, board

**Kas file**:
One kas YAML configuration describing the layers and settings for a release.
_Avoid_: Manifest, recipe

**Base config**:
The kas file holding settings shared by every release's kas file, which they include.
_Avoid_: Common file, template
