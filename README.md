# Infinity Scheduler

This project is an attempt to modify Fair, RT, and the DRM GPU schedulers to give consistent performance and latency that work better for desktop use.
It is using a completely different approach compared to the [old version of the Infinity project](https://github.com/galpt/infinity-scheduler).

> [!NOTE]
> This project is not for beginners. You are expected to already know how to work with patch files. You are welcome to be an early tester and your feedback would be greatly appreciated.

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

Independent revert of each patch restores the stock file. QA, fidelity and performance gates hold, including the H1 livelock fix.

Concretely, the fair patch was checked against stock 7.2.6 EEVDF sources with `git apply --check`, then stacked with rt and gpu in series order and again in reverse order.

The drm select scan was reviewed for the blocked head case so a stalled entity cannot wedge the ring. The H1 review closed the livelock path found in an earlier revision.

All verification so far is at source level. Kernel build plus boot plus schbench and cyclictest plus GPU kunit remain open.

## What still needs testing

What still needs testing is a full kernel build plus a boot run, followed by schbench and cyclictest on the CPU side and GPU kunit on the drm side.

Scale checks on large CPU counts and mixed interactive plus batch mixes are still open. Reports from testers on the 7.2 tree will shape the deferred ports.

Until those runs land, treat every performance claim here as a design goal rather than a measured result.

## Known behaviors

- *"Wakeup preemption is positional by design (head entity preempts). A tail wakee waits at most until the current head exhausts its quantum and rotates to tail on expiry — worst-case added latency ≈ 1 max quantum (admission share q = Q_BASE·w/W ≤ Q_BASE = 1 ms). No weight-aware preemption is performed (out of scope)."*
- *"Known behavior (signed): `sched_rr_get_interval` returns 0 for RR (RR quantum neutered; 0 = infinity per the timespec convention). `sched_rr_timeslice` sysctl//proc entries and `time_slice` storage are retained ABI-only and side-effect-free."*
- DRM revert: `sched_policy=1` boot param restores FIFO; Infinity is default (POLICY_INFINITY=3).

There are no stats and every constant is frozen. The 1 ms quantum base, the 7 plus 1 bound and the policy default are compiled in with no runtime tunables.

## Credits

- **[EEVDF](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/fair.c)** — Earliest Eligible Virtual Deadline First scheduling algorithm by Ion Stoica and Hussein Abdel-Wahab (1995), implemented in the Linux kernel by Peter Zijlstra and the kernel community. EEVDF serves as the foundation that the Infinity scheduler modifies.
- **[scx_flow 3.1.0](https://github.com/sched-ext/scx/tree/main/rust/scx_layered/scx_flow)** — BPF sched-ext fair-share scheduler by the sched-ext community. The budget model and interactive floor logic are adapted from this implementation.
- **[BORE](https://github.com/firelzrd/bore-scheduler)** — Burst-Oriented Response Enhancer scheduler by Masahito S ([firelzrd](https://github.com/firelzrd)). BORE's approach to CPU-bound task suppression through burst scoring provided a reference point for Infinity's accelerating consumption design.
- **[BMQ / PDS / LF-BMQ](https://gitlab.com/alfredchen/projectc)** — BitMap Queue schedulers by Alfred Chen (Project C). Research into BMQ's complete scheduler replacement approach validated the decision to keep Infinity within EEVDF rather than replacing it entirely.
- **[Tvrtko Ursulin — Fair(er) DRM GPU scheduler](https://blogs.igalia.com/tursulin/fair-er-drm-gpu-scheduler/)** — Igalia blog post demonstrating a CFS-inspired fair scheduler for the DRM GPU scheduler. The approach to unified virtual time scheduling and priority de-strictification directly informs Infinity's GPU extension.
- **[LINUX DO](https://linux.do/)** — Chinese Linux community where the Infinity scheduler is discussed and promoted. Feedback from the community helps shape the project's development direction.
- **[CachyOS community](https://cachyos.org/)** — Testers and early adopters who provided real-world feedback during development, helping validate the scheduler's behavior under diverse workloads.
- **[u3z05en](https://github.com/u3z05en)** — Jonathan, for helping with the code review, addressing several subtle issues that made Infinity more correct and robust.
- **[lostf1sh](https://github.com/lostf1sh)** — Bug reports and code review, helping identify issues and improve the scheduler's correctness.
- **[RiverOnVenus](https://github.com/RiverOnVenus)** — Code review, helping identify issues and improve the scheduler's correctness.
- **[dim-geo](https://github.com/dim-geo)** — CachyOS packaging: contributed the adapted 7.1 patch series under `patches/cachyos/7.1/`.
- **[sxlmnwb](https://github.com/sxlmnwb)** — Salman Wahib, for moving the `infinity_stats` rows to a heap allocation, fixing the stack frame warning and the error-path cleanup.
