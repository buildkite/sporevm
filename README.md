# SporeVM

SporeVM is an experimental virtual machine monitor for aarch64 Linux microVMs.
It treats a suspended VM as a cheap, forkable object that can be resumed or
fanned out across compatible hosts.

One Zig codebase targets two hypervisors:

- KVM on Linux/aarch64
- Hypervisor.framework on Apple Silicon macOS

Both backends share the same minimal device model: virtio-mmio console, block,
net, vsock, rng, and the SporeVM generation device. Cross-backend restore is a
useful portability diagnostic, but the primary product path is fork/fan-out on
identical host classes.

A sealed checkpoint artifact is called a **spore**. A spore is a manifest of
content-addressed memory chunks, guest machine state, device state, and
eventually disk state. v0 spores do not capture disk bytes yet, so disk-backed
resume still requires the same backing disk out of band.

The target lifecycle property is that common operations avoid scaling with RAM
size:

- **Suspend** is a pause plus a small dirty tail flush.
- **Fork** is a metadata write.
- **Resume** is bounded by the working set, not total guest RAM.

## Status

SporeVM is early, pre-release software. Breaking changes are expected before
1.0. The plan of record is
[docs/plans/foundation.md](docs/plans/foundation.md).

Current `main` can:

- boot the pinned aarch64 Linux kernel on HVF and KVM;
- inspect host platform facts with `spore host-info`;
- summarize a spore manifest with `spore inspect <spore-dir>`;
- run one explicit argv request in a throwaway VM with `spore run`;
- stream fresh run stdout/stderr and exit with the guest command status;
- capture a long-running `spore run` on a host signal with
  `--capture-on-abort`;
- mint metadata-only child spores with `spore fork`;
- resume one diskless spore with `spore resume`;
- pack and unpack local chunkpack bundles with `spore pack` / `spore unpack`;
- build deterministic ext4 rootfs images from OCI images with
  `spore rootfs build`;
- run from an explicit read-only rootfs with `spore run --rootfs`;
- build or reuse a cached rootfs directly from an OCI ref with
  `spore run --image`.

Create and suspend as long-lived product verbs are still planned. The backend
smoke harnesses exercise the lower-level capture path today.

## Development

Tooling is pinned with [mise](https://mise.jdx.dev):

```bash
mise install
mise run check
mise run smoke
```

Useful task split:

```bash
mise run test
mise run build
mise run smoke:run
mise run smoke:run-capture
mise run smoke:resume
```

`mise run check` runs unit tests, the product build, and diff hygiene.
`mise run smoke` builds once, then runs product run, run-capture, and resume
smokes.

`zig build` installs the minimal exec initrd used by `spore run`, so `cpio`
must be available in `PATH`.

KVM work needs an aarch64 Linux host with KVM. Hypervisor.framework work needs
an Apple Silicon Mac on macOS 15 or newer.

## Product CLI

Run one command in a throwaway VM:

```bash
zig-out/bin/spore run -- /bin/writeout
```

`spore run` defaults to the managed SporeVM run kernel and the minimal exec
initrd installed by `zig build`. Override the boot assets with `--kernel` and
`--initrd`, or set `SPOREVM_KERNEL_IMAGE` and `SPOREVM_RUN_INITRD`.

The minimal agent streams command stdout and stderr over a small framed vsock
protocol. The host forwards stdout frames to stdout, stderr frames to stderr,
and exits with the guest command status. The old `--json` final-frame mode is
not part of the product CLI.

Capture a long-running run on a host signal:

```bash
zig-out/bin/spore run \
  --capture-on-abort /tmp/run.spore \
  --capture-signal USR1 \
  -- /bin/sleeper &
run_pid=$!

kill -USR1 "$run_pid"
wait "$run_pid"
zig-out/bin/spore resume /tmp/run.spore
```

When `--capture-on-abort` is set, the default capture signal is `INT`. In an
interactive terminal, the first Ctrl-C requests capture and the second exits
with status 130. Non-interactive callers can pass `--capture-signal INT`,
`TERM`, `HUP`, `USR1`, or `USR2`, with or without the `SIG` prefix.

Captured runs exit zero after writing the spore and print the capture path to
stderr. A command that finishes before capture still exits with its guest
status.

Fork an existing spore:

```bash
zig-out/bin/spore fork /tmp/run.spore --count 100 --out /tmp/forks
```

Children are named `000000`, `000001`, and so on, and share the parent's chunk
store.

Resume one captured or forked diskless spore:

```bash
zig-out/bin/spore resume /tmp/forks/000000
```

Product resume streams the restored guest console and defaults RAM size from
the spore manifest. Disk-backed restore still needs the backend harness plus
the original backing disk.

Pack and unpack a spore:

```bash
zig-out/bin/spore pack /tmp/run.spore --out /tmp/run.bundle
zig-out/bin/spore unpack /tmp/run.bundle --out /tmp/run.unpacked
```

Both commands report a `bundle_digest` for cache identity.

## Rootfs Images

Build a deterministic ext4 rootfs from an OCI image:

```bash
zig-out/bin/spore rootfs build docker.io/library/alpine:3.20 \
  --platform linux/arm64 \
  --output alpine.ext4
```

Run from that rootfs read-only:

```bash
zig-out/bin/spore run --rootfs alpine.ext4 -- /bin/echo hi
```

Or let `spore run` build and reuse a cached rootfs from an OCI reference:

```bash
zig-out/bin/spore run --image docker.io/library/alpine:3.20 -- /bin/echo hi
```

`--image` still runs the explicit argv after `--`. It does not apply OCI
Entrypoint, Cmd, User, Env, or Workdir yet. Set `SPOREVM_ROOTFS_CACHE_DIR` to
override the cache directory.

Run the end-to-end OCI rootfs smoke with:

```bash
scripts/smoke-run-oci-rootfs.sh -- /bin/echo hi
```

See [docs/rootfs.md](docs/rootfs.md) for tag resolution, metadata, and ext4
tooling details.

## Backend Harnesses And Smokes

Lower-level backend harnesses remain available for targeted debugging:

```bash
mise exec -- zig build hvf-boot
mise exec -- zig build hvf-gic-probe
mise exec -- zig build kvm-boot
```

The `hvf-boot` and `kvm-boot` harnesses accept `--initrd root.cpio` for
diskless smoke workloads. When no disk is supplied they default to
`rdinit=/init`.

The smoke scripts auto-download pinned `cleanroom-kernels` assets and cache
them under the platform cache directory. Pass `--kernel` or set
`SPOREVM_KERNEL_IMAGE` for local kernel experiments.

Build the ticker initrd used by restore smokes:

```bash
scripts/make-smoke-initrd.sh /tmp/sporevm-smoke.cpio
```

Run same-host restore smokes, or split cross-host capture/resume legs:

```bash
scripts/smoke-restore-leg.sh same-host \
  --backend hvf \
  --initrd /tmp/sporevm-smoke.cpio
```

Fork fan-out smokes use the separate SporeVM kernel asset because the
fork-aware initrd needs `/dev/mem` access to the fixed generation MMIO window:

```bash
CC="zig cc -target aarch64-linux-musl" \
  scripts/smoke-fork-fanout.sh --backend hvf
```

To exercise the first cross-host bundle path over SSM and S3:

```bash
scripts/smoke-remote-bundle.sh \
  --region REGION \
  --source-instance ID \
  --dest-instance ID \
  --bucket BUCKET
```

It stages tracked `HEAD` plus the current tracked/staged diff. Stage new files
you want included in the remote run. Add `--cache-dir DIR --dest-repeat N` to
prove host-local bundle cache reuse across repeated restores. Add
`--source-peer-ip IP --source-peer-port 20000` to serve the bundle from the
source host over east-west HTTP so destinations avoid direct S3 bundle
downloads.

For a lower-bound boot/exec probe comparable to Cleanroom's minimal
`darwin-vz` benchmark:

```bash
scripts/benchmark-sporevm-minimal.sh \
  --backend hvf \
  --iterations 30
```

The benchmark builds a tiny initrd whose `/init` listens on virtio-vsock, sends
one `/bin/true` argv request from the host, and writes JSONL timings for VM
start, vsock connect, and first exec response.

## Security

SporeVM is an isolation boundary. Read [SECURITY.md](SECURITY.md) before
touching virtqueue parsing, manifest decoding, or guest memory access.

## License

[MIT](LICENSE)
