# ADR-0023: microvm.nix Store Disk Transport Selection (`blk` vs `pmem`)

Date: 2026-03-11
Kind: Decision
Status: Proposed
Priority: 1
Requires: [ADR-0018, ADR-0020]
Authors: wiz + Codex

## Narrative Summary (1-minute read)

`microvm.nix` already builds an immutable store image for `/nix/store` when
`microvm.storeOnDisk = true`, but it does not let the operator choose how that
image is attached to the guest. Today the built store image is treated as a
normal block device by Cloud Hypervisor and Firecracker. Choir currently works
around this for Cloud Hypervisor by rewriting the generated runner command to
replace the store `--disk` with `--pmem`.

This ADR proposes a first-class `microvm.storeDiskInterface = "blk" | "pmem"`
option for the built immutable store image. `blk` remains the default and the
safe multi-tenant choice. `pmem` becomes the DAX-enabled optimization path for
supported hypervisors and filesystems, initially restricted to `erofs`.

The immediate result is:

- no downstream `sed` patching of generated Cloud Hypervisor runner commands
- clean backend parity for Cloud Hypervisor and Firecracker
- explicit security documentation for shared `pmem` backing files
- a stable abstraction for testing `blk` and `pmem` back-to-back in Choir

## What Changed

- 2026-03-11: Initial ADR drafted from Choir downstream requirements and
  review of the current `microvm.nix` runner/mount implementation.
- 2026-03-11: Added alignment decision (Decision 7), compressed-erofs
  assertion, Firecracker v1.14.0 pmem API details, backend alignment
  differences.

## What To Do Next

Implement the feature in this order:

1. Add a non-breaking transport selector option.
2. Make guest mount logic transport-aware.
3. Add Cloud Hypervisor native `--pmem` support for the store image.
4. Add Firecracker native `pmem` support for the store image.
5. Add boot tests and security-focused documentation.

---

## Context

`microvm.nix` already has the core pieces:

- `microvm.storeOnDisk` chooses a built immutable store image instead of a
  host store share.
- `microvm.storeDiskType` chooses the filesystem format (`erofs` or
  `squashfs`).
- `nixos-modules/microvm/store-disk.nix` builds the store image artifact.
- `nixos-modules/microvm/mounts.nix` mounts it inside the guest.
- backend runners attach the built image:
  - `lib/runners/cloud-hypervisor.nix` uses `--disk`
  - `lib/runners/firecracker.nix` emits a `drives` entry

What is missing is the transport choice for the built immutable store image.

That choice matters:

- `blk` is simpler, conservative, and safer for multi-tenant isolation.
- `pmem` enables DAX for immutable images and can reduce duplicate guest page
  cache overhead.
- shared `pmem` backing files expose a cross-VM observation channel around page
  access patterns, so the faster path is not automatically the safer path.

Choir’s current Cloud Hypervisor deployment proves the missing abstraction:
the generated runner command is post-processed to remove the store `--disk` and
inject `--pmem` instead.

---

## Problem Statement

The current `microvm.nix` behavior couples three separate concerns:

1. building the immutable store image
2. choosing its guest filesystem format
3. attaching it through a hypervisor-specific device transport

The image builder and guest mount logic already exist, but the transport is
hard-coded to the backend’s default block-device path. That creates three
problems:

- downstream users must patch generated runner commands to use `pmem`
- `blk` versus `pmem` cannot be tested or documented as an explicit policy
- the security tradeoff around shared `pmem` backing files is hidden instead of
  exposed as a first-class operator choice

---

## Decision 1: Add `microvm.storeDiskInterface = "blk" | "pmem"`

Add a new option:

```nix
microvm.storeDiskInterface = "blk"; # or "pmem"
```

This is a new option. It must not replace the existing `microvm.storeDisk`
option because `microvm.storeDisk` already means the generated path to the
built store image.

### Consequences

- no breaking change to the existing option surface
- transport becomes explicit and testable
- backend runners can map the same logical choice to their native device model

---

## Decision 2: Keep `blk` as the Default

`blk` remains the default store image transport.

`pmem` is an opt-in optimization for operators who want DAX behavior and accept
the resulting trust-model tradeoff.

### Consequences

- existing users keep current behavior
- multi-tenant deployments do not silently adopt shared-`pmem` risk
- documentation can describe `pmem` precisely as an optimization path rather
  than a universal upgrade

---

## Decision 3: Restrict `pmem` to Uncompressed `erofs` on Disk

The first PR should restrict `pmem` to the built immutable store image, and
only when:

- `microvm.storeOnDisk = true`
- `microvm.storeDiskType = "erofs"`
- `microvm.storeDiskErofsFlags` does not include compression flags (`-zlz4`,
  `-zlz4hc`, etc.)

Compressed erofs cannot use DAX — this is a hard kernel limitation
(`CONFIG_FS_DAX` requires direct byte-addressable access to the backing store,
which is incompatible with compressed block layouts). Allowing `pmem` with
compressed erofs would silently fall back to non-DAX behavior, defeating the
purpose of the transport selection.

`pmem` is not generalized to arbitrary `microvm.volumes` in the first PR.

### Consequences

- the implementation stays narrow and upstreamable
- guest mount semantics remain well-defined
- compressed-erofs misconfigurations fail at evaluation time, not at mount time
- `squashfs + pmem` and arbitrary volume transport can be addressed later if
  needed

---

## Decision 4: Make Guest Mount Logic Transport-Aware

The guest mount path needs both DAX-specific mount flags and transport-aware
device selection. For the current pmem path, the store must mount from
`/dev/pmem0`. The blk path keeps the current erofs label-based lookup at
`/dev/disk/by-label/nix-store`.

Mount policy:

- `blk + erofs` -> mount `/dev/disk/by-label/nix-store` read-only
- `pmem + erofs` -> mount `/dev/pmem0` read-only with `dax`

This is intentionally narrow. If a future backend or kernel combination makes
label-based pmem lookup reliable, that can be revisited with tests.

### Consequences

- device naming logic in `mounts.nix` is transport-aware for the store
- mount flags also change based on transport
- downstream guest configs no longer need to override `/nix/store` manually

---

## Decision 5: Use Native Backend Shapes

The logical transport selector maps to each backend’s native interface:

- Cloud Hypervisor:
  - `blk` -> existing `--disk`
  - `pmem` -> `--pmem file=<path>,discard_writes=on`
- Firecracker (v1.14.0+):
  - `blk` -> existing `drives` entry
  - `pmem` -> `pmem` config array entry (`id`, `path_on_host`,
    `root_device`, `read_only`)

Do not invent backend-specific user-facing option names such as
`storeDiskCloudHypervisorMode`.

### Consequences

- the API stays backend-neutral
- the implementation remains backend-specific only in runner generation
- downstream users can compare Cloud Hypervisor and Firecracker under the same
  logical config
- environment-specific compatibility shims remain a downstream concern

---

## Decision 6: Treat Shared `pmem` as a Trust-Tier Feature

The documentation for `pmem` must explicitly state:

- `pmem` is intended for immutable images where DAX and page-cache avoidance
  matter
- sharing the same backing file across VMs may expose access-pattern or timing
  side channels
- `blk` is the default for private multi-tenant workloads
- shared `pmem` is appropriate only for same-trust-domain workloads or public
  immutable corpora

This feature should be described as a policy choice, not just a performance
toggle.

### Consequences

- the performance/security tradeoff is documented at the abstraction boundary
  where operators make the choice
- downstream systems such as Choir can cleanly map:
  - free/public tier -> shared `pmem`
  - paid/private tier -> `blk`

---

## Decision 7: Build-Time 2 MiB Alignment for Cloud Hypervisor

Cloud Hypervisor strictly rejects `--pmem` backing files whose size is not a
multiple of 2 MiB (`0x200000`). The check is in `device_manager.rs`:

```rust
if size % 0x20_0000 != 0 {
    return Err(DeviceManagerError::PmemSizeNotAligned);
}
```

Firecracker handles this differently: it auto-pads with anonymous
`PRIVATE | ANONYMOUS` memory pages between the file end and the next 2 MiB
boundary. No pre-alignment is needed for Firecracker.

The aligned artifact must be produced by the Nix build graph, not by imperative
host-side scripts. Choir currently works around this with a runtime
`cp + truncate` in `ExecStartPre` — that workaround should be eliminated by
this feature.

Produce a derived artifact when `storeDiskInterface = "pmem"` and the backend
is `cloud-hypervisor`:

```nix
storeDiskPmemImage = pkgs.runCommand "store-disk-pmem" {} ''
  cp ${storeDisk} $out
  size=$(stat -c%s $out)
  align=$((2 * 1024 * 1024))
  aligned=$(( ((size + align - 1) / align) * align ))
  truncate -s "$aligned" $out
'';
```

Expose this internally (e.g. `config.microvm._internal.storeDiskPmemImage`)
so the Cloud Hypervisor runner uses the aligned artifact while Firecracker
uses the original `storeDisk` directly.

### Consequences

- Cloud Hypervisor pmem works without downstream runtime padding
- Firecracker avoids unnecessary copies (uses original artifact directly)
- the alignment difference between backends is handled once, in the build graph
- `microvm.storeDisk` retains its current meaning (the unpadded image)

---

## Non-Goals

This ADR does not include:

- generic `pmem` transport for arbitrary `microvm.volumes`
- generic DAX policy for all filesystems
- changing writable store overlay semantics
- compressing `erofs` in the `pmem` path
- redesigning all backend device graphs at once

---

## Implementation Notes

- The store image builder in `nixos-modules/microvm/store-disk.nix` should stay
  the source of truth for the built immutable image artifact.
- Cloud Hypervisor requires 2 MiB-aligned pmem files (see Decision 7).
  Firecracker auto-pads internally and does not need alignment.
- Cloud Hypervisor support should land first because existing downstream users
  are already carrying a runtime rewrite workaround for it.
- Firecracker pmem requires v1.14.0+ (released with virtio-pmem support).
  The config schema uses `pmem` as a top-level array, not nested under
  `drives`.
- Guest kernel requirements for pmem: `CONFIG_VIRTIO_PMEM=y`,
  `CONFIG_LIBNVDIMM=y`, `CONFIG_FS_DAX=y`. These are already required by
  Choir's kernel config (ADR-0018 Phase 7).

---

## Source References

- `nixos-modules/microvm/store-disk.nix`
- `nixos-modules/microvm/mounts.nix`
- `lib/runners/cloud-hypervisor.nix`
- `lib/runners/firecracker.nix`
- Firecracker pmem docs: `docs/pmem.md` (v1.14.0+, PR #5463)
- Cloud Hypervisor `device_manager.rs` (pmem alignment check)
- Choir runtime workaround: `nix/hosts/ovh-node.nix` (ExecStartPre padding)
