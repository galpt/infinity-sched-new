# For Cachymod

This variant carries the Infinity queue for CachyMod trees. It keeps CachyMod defaults intact and adds bounded last in first out ordering with weighted quantum and expiry.

## Target

The exact target combines `7.2.6-1`, `7.2.7`, reverts, and CachyMod defaults. Credit sleep `0350` is present, and the fair revert `0360` is absent.

```text
7.2.6-1
7.2.7
0000 reverts
0260
0280
0290
0350 present
0360 absent
```

## Apply

The apply order is `fair->rt->gpu`. Dry run first with no fuzz, and proceed only on clean dry run.

```sh
patch -p1 -N -F 0 --dry-run < cpu/fair/0001-infinity-fair-7.2.patch
patch -p1 -N -F 0 --dry-run < cpu/rt/0001-infinity-rt-7.2.patch
patch -p1 -N -F 0 --dry-run < gpu/0001-infinity-drm-7.2.patch
patch -p1 -N -F 0 < cpu/fair/0001-infinity-fair-7.2.patch
patch -p1 -N -F 0 < cpu/rt/0001-infinity-rt-7.2.patch
patch -p1 -N -F 0 < gpu/0001-infinity-drm-7.2.patch
```

## Revert

The revert order is `gpu->rt->fair`.

```sh
patch -p1 -R < gpu/0001-infinity-drm-7.2.patch
patch -p1 -R < cpu/rt/0001-infinity-rt-7.2.patch
patch -p1 -R < cpu/fair/0001-infinity-fair-7.2.patch
```

## BORE note

BORE credit needs explicit opt in, and the opt in path is uncovered in this series. Default runs keep credit disabled, and credit enabled runs were not measured here.

RR `sched_rr_get_interval` returns 0 (infinity) with RR timeslice neutered.

Quantum is root-normalized with per-level list position; see `set_next_entity`.
