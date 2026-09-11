# Maintainer guide

## Releases

Pushing a `v*` tag builds and publishes `x86_64` and `aarch64` archives for
Linux and macOS. Linux releases are statically linked with musl. macOS releases
are currently unsigned and unnotarized.

```sh
git tag v0.1.0
git push origin v0.1.0
```

The Release workflow can also be run manually to build downloadable Actions
artifacts without creating a GitHub Release.
