# Spore Format

**Status:** stub — manifest v0 is specified in slice 3 of
[plans/foundation.md](plans/foundation.md). This document becomes the
normative format reference when that slice lands.

A spore is a sealed, content-addressed checkpoint of a VM. The format, not the
implementation, is the product: two SporeVM builds on different hypervisors
interoperate through this document.

Planned shape:

```text
spore manifest
├── platform contract (arch, kernel build, device model ver, CPU profile)
├── machine state: architectural vCPU state per CPU, GICv3 state,
│   virtio queue state, timer offsets — normalized, hypervisor-neutral
├── memory manifest: ordered chunk refs (blake3, zstd), zero-elided
├── disk manifest: chunk refs over the block device
└── access trace: page-touch order from prior resumes (prefetch hint)
```

Invariants that hold regardless of version:

- Chunk ids are BLAKE3-256 of chunk contents (`src/chunk.zig`).
- Machine state is normalized architectural aarch64 state; raw KVM or
  Hypervisor.framework structures never appear in the format.
- Manifests carry a format version; consumers fail closed on versions or
  platform contracts they cannot satisfy.
- Pre-1.0 versions carry no compatibility promise.
