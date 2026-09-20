# Infinity Scheduler

This project is an attempt to modify Fair, RT, and the DRM GPU schedulers to give consistent performance and latency that work better for desktop use.
It is using a completely different approach compared to the [old version of the Infinity project](https://github.com/galpt/infinity-scheduler).

> [!NOTE]
> 1. This project is not for beginners. You are expected to already know how to work with patch files. You are welcome to be an early tester and your feedback would be greatly appreciated.
> 2. The patches are intended to be applied together for Infinity to work correctly as a complete scheduler. Applying only part of the series (for example the CPU patches without the GPU patch, or vice versa) may result in unintended side effects.

## How to build a patched kernel

Pick the 7.2 series and apply it in series order, fair first, then rt, then gpu. Check that each patch applies cleanly with zero fuzz, then build as usual.

```sh
cd /path/to/linux-7.2.6
patch -p1 -N -F 0 --dry-run < /path/to/infinity-sched-new/patches/7.2/cpu/fair/0001-infinity-fair-7.2.patch
patch -p1 -N -F 0 --dry-run < /path/to/infinity-sched-new/patches/7.2/cpu/rt/0001-infinity-rt-7.2.patch
patch -p1 -N -F 0 --dry-run < /path/to/infinity-sched-new/patches/7.2/gpu/0001-infinity-drm-7.2.patch
patch -p1 -N -F 0 < /path/to/infinity-sched-new/patches/7.2/cpu/fair/0001-infinity-fair-7.2.patch
patch -p1 -N -F 0 < /path/to/infinity-sched-new/patches/7.2/cpu/rt/0001-infinity-rt-7.2.patch
patch -p1 -N -F 0 < /path/to/infinity-sched-new/patches/7.2/gpu/0001-infinity-drm-7.2.patch
make -j$(nproc)
```

Check apply state with git and lint each patch with checkpatch in strict mode.

```sh
git apply --check patches/7.2/cpu/fair/0001-infinity-fair-7.2.patch
git apply --check patches/7.2/cpu/rt/0001-infinity-rt-7.2.patch
git apply --check patches/7.2/gpu/0001-infinity-drm-7.2.patch
perl scripts/checkpatch.pl --strict --patch patches/7.2/cpu/fair/0001-infinity-fair-7.2.patch
perl scripts/checkpatch.pl --strict --patch patches/7.2/cpu/rt/0001-infinity-rt-7.2.patch
perl scripts/checkpatch.pl --strict --patch patches/7.2/gpu/0001-infinity-drm-7.2.patch
```

Fallback is revert of one patch or of the whole series. Each patch reverses cleanly on its own, and the drm policy reverts at runtime with the boot parameter below. To drop the series from a tree, reverse in gpu, rt, fair order.

```sh
cd /path/to/linux-7.2.6
patch -p1 -R < /path/to/infinity-sched-new/patches/7.2/gpu/0001-infinity-drm-7.2.patch
patch -p1 -R < /path/to/infinity-sched-new/patches/7.2/cpu/rt/0001-infinity-rt-7.2.patch
patch -p1 -R < /path/to/infinity-sched-new/patches/7.2/cpu/fair/0001-infinity-fair-7.2.patch
```

## How it is checked

Apply checks pass with zero fuzz in both series order and reverse order. Each of the three patches reports zero errors and zero warnings under checkpatch in strict mode.

Independent revert of each patch restores the stock file. Independent review holds, including a fix for a livelock found in an earlier revision.

Concretely, the fair patch was checked against stock 7.2.6 EEVDF sources with `git apply --check`, then stacked with rt and gpu in series order and again in reverse order.

The drm select scan was reviewed for the blocked head case so a stalled entity cannot wedge the ring. Review also closed the livelock path found in an earlier revision.

All verification so far is at source level. Kernel build plus boot plus schbench and cyclictest plus GPU kunit remain open.

## What still needs testing

What still needs testing is a full kernel build plus a boot run, followed by schbench and cyclictest on the CPU side and GPU kunit on the drm side.

Scale checks on large CPU counts and mixed interactive plus batch mixes are still open. Reports from testers on the 7.2 tree will shape the deferred ports.

Until those runs land, treat every performance claim here as a design goal rather than a measured result.

## Known behaviors

- *"Wakeup preemption is positional by design (head entity preempts). A tail wakee waits at most until the current head exhausts its quantum and rotates to tail on expiry — worst-case added latency ≈ 1 max quantum (admission share q = Q_BASE·w/W ≤ Q_BASE = 1 ms). No weight-aware preemption is performed (out of scope)."*
- *"Known behavior (signed): `sched_rr_get_interval` returns 0 for RR (RR quantum neutered; 0 = infinity per the timespec convention). `sched_rr_timeslice` sysctl//proc entries and `time_slice` storage are retained ABI-only and side-effect-free."*
- DRM revert: `sched_policy=1` boot param restores FIFO; Infinity is default (POLICY_INFINITY=3).

Live discipline stats are in debugfs: `/sys/kernel/debug/infinity_fair` (fair, this track), `/sys/kernel/debug/infinity_rt` (rt track) and `/sys/kernel/debug/infinity_drm` (drm track). Every constant stays frozen — the 1 ms quantum base, the 7 plus 1 bound and the policy default are compiled in with no runtime tunables. vruntime and tree fields in `/proc/sched_debug` are frozen under Infinity, so consult debugfs for live state.

## Credits

v5 is a clean rewrite built on bounded-LIFO with a weighted 1ms quantum, so most entries below honor work on the previous implementation that made this rewrite possible.

- **[EEVDF](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/fair.c)** — Earliest Eligible Virtual Deadline First scheduling algorithm by Ion Stoica and Hussein Abdel-Wahab (1995), implemented in the Linux kernel by Peter Zijlstra and the kernel community. EEVDF serves as the foundation that the Infinity scheduler modifies.
- Exploration of bounded-LIFO and fair share ideas informed by [scx_flow](https://github.com/galpt/scx_flow_new/tree/main/scheds/experimental/scx_flow) and [KPP](https://github.com/galpt/kpp-iosched), studied as background for the previous implementation and carried forward only as design thinking.
- [BORE](https://github.com/firelzrd/bore-scheduler) by Masahito S, whose burst scoring research informed exploration in the previous implementation.
- [BMQ / PDS / LF-BMQ](https://gitlab.com/alfredchen/projectc) by Alfred Chen, whose scheduler research informed exploration in the previous implementation.
- [Tvrtko Ursulin, Fair(er) DRM GPU scheduler](https://blogs.igalia.com/tursulin/fair-er-drm-gpu-scheduler/), whose fair GPU scheduling research informed exploration in the previous implementation.
- [LINUX DO](https://linux.do/), for discussion and support during development of the previous implementation.
- [CachyOS community](https://cachyos.org/), for testing and feedback during development of the previous implementation.
- [u3z05en](https://github.com/u3z05en), Jonathan, for code review that made the previous implementation more correct and robust.
- [lostf1sh](https://github.com/lostf1sh), for bug reports and code review on the previous implementation.
- [RiverOnVenus](https://github.com/RiverOnVenus), for code review on the previous implementation.
- [dim-geo](https://github.com/dim-geo), for CachyOS packaging of the 7.1 series in the previous repository line.
- [sxlmnwb](https://github.com/sxlmnwb), Salman Wahib, for the `infinity_stats` heap allocation fix in the previous implementation, a component this rewrite omits by design.
