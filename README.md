# 🍄 SporeVM

SporeVM is a virtual machine monitor for aarch64 Linux microVMs that treats a
suspended VM as a cheap, portable, forkable object. One Zig codebase targets
two hypervisors — KVM on Linux and Hypervisor.framework on macOS — with an
identical minimal device model on both, so a VM suspended on one host can
resume on the other.

The sealed checkpoint artifact is called a **spore**: a manifest of
content-addressed memory and disk chunks plus a small normalized machine-state
blob. Spores are the unit of suspend, fork, fan-out, and cross-platform
transfer.

The defining design property: no lifecycle operation scales with RAM size.

- **Suspend** is a pause plus a small tail flush (~tens of ms at any RAM size)
- **Fork** is a metadata write — `spore fork --count 10000` is sub-second
- **Resume** is bounded by the working set, not memory size, on either OS

```console
spore create --kernel ... --disk ... my-vm
spore suspend my-vm
spore fork my-vm --count 10000
spore pull <spore-id> && spore resume <spore-id>   # on a different OS
```

## Status

Early development, pre-release. The plan of record is
[docs/plans/foundation.md](docs/plans/foundation.md). Current `main` boots a
pinned aarch64 Linux kernel on Hypervisor.framework to an interactive shell and
on KVM/aarch64 to an Alpine shell prompt, with the shared virtio-mmio console,
block, net, vsock, rng, and generation devices. The HVF and KVM paths can also
write/resume a v0 spore on the same host. The CLI can report current host
platform facts with `spore host-info` and summarise a spore manifest with
`spore inspect <spore-dir>`.

The cross-hypervisor restore matrix is still pending.

## Development

Tooling is pinned with [mise](https://mise.jdx.dev):

```bash
mise install
mise run build    # zig build
mise run test     # zig build test
mise exec -- zig build hvf-boot   # build/sign the HVF kernel boot harness
mise exec -- zig build hvf-gic-probe # probe HVF GICv3 portable-state support
mise exec -- zig build kvm-boot   # build the KVM kernel boot harness on Linux/aarch64
```

The `hvf-boot` and `kvm-boot` harnesses accept `--initrd root.cpio` for
diskless smoke workloads (`rdinit=/init` by default when no disk is supplied).
Use an initrd-capable kernel such as the `cleanroom-kernels` `initrd` profile;
the default `rootfs` profile intentionally ignores external initrds.

KVM work needs an aarch64 Linux host with KVM; Hypervisor.framework work needs
an Apple Silicon Mac on macOS 15+.

## Rootfs Images

`spore rootfs build` can materialize a digest-pinned OCI image into a
deterministic ext4 rootfs image. The builder verifies fetched blobs against
their SHA256 descriptors, applies OCI whiteouts, rejects unsafe tar paths, and
shells out to `mkfs.ext4 -F -d` plus `debugfs` for the final filesystem.

The generated ext4 image uses UUID and directory hash seeds derived from the
selected OCI manifest digest, normalizes filesystem and inode timestamps to the
Unix epoch, and omits the ext4 journal/metadata checksum features so repeated
builds of the same image produce identical bytes.

```bash
spore rootfs build ghcr.io/org/image@sha256:<digest> \
  --platform linux/arm64 \
  --output rootfs.ext4 \
  --metadata rootfs.ext4.json
```

`mkfs.ext4` and `debugfs` are auto-detected from `PATH`, common Linux
locations, and Homebrew's `e2fsprogs` prefix. Use `--mkfs` and `--debugfs` to
override the detected binaries.

## Security

SporeVM is an isolation boundary. Read [SECURITY.md](SECURITY.md) before
touching virtqueue parsing, manifest decoding, or guest memory access.

## License

[MIT](LICENSE)
