# Implementing ADR-0023: microvm.nix Store Disk Transport Selection

Date: 2026-03-11
Kind: Guide
Status: Active
Priority: 1
Requires: [ADR-0023]

## Narrative Summary (1-minute read)

This guide implements first-class store image transport selection for
`microvm.nix` without breaking the existing option surface. The key design is:

- keep `microvm.storeDisk` as the generated image path
- add `microvm.storeDiskInterface = "blk" | "pmem"`
- teach guest mount logic to understand the selected transport
- teach Cloud Hypervisor and Firecracker runners to attach the built store
  image through their native `blk` or `pmem` interfaces

The initial scope is intentionally narrow: the immutable built store image only,
with `pmem` restricted to `erofs`.

## What Changed

- 2026-03-11: Initial implementation guide drafted against the current
  `microvm.nix` tree and Choir downstream usage.
- 2026-03-11: Added compressed-erofs assertion, reordered phases (alignment
  artifact before runners), added Firecracker v1.14.0 API details and
  backend-specific alignment behavior.

## What To Do Next

Implement in this order:

1. add option + assertions (including compressed-erofs guard)
2. build 2 MiB-aligned pmem artifact in the Nix build graph
3. make guest mount logic transport-aware
4. add Cloud Hypervisor native `pmem` (uses aligned artifact)
5. add Firecracker native `pmem` (uses original artifact — auto-pads)
6. add tests + docs

---

## Phase 1: Add the New Option Without Breaking `microvm.storeDisk`

### 1a. Add `microvm.storeDiskInterface`

**File:** `nixos-modules/microvm/options.nix`

Add:

```nix
storeDiskInterface = mkOption {
  type = types.enum [ "blk" "pmem" ];
  default = "blk";
  description = ''
    Transport used to attach the built immutable store image.
    `blk` uses a normal block device.
    `pmem` uses a persistent-memory device and is intended for immutable
    read-only store images on supported hypervisors.
  '';
};
```

Do not rename or restructure `microvm.storeDisk`; that option already exists as
the generated store image path.

### 1b. Add Assertions

**File:** `nixos-modules/microvm/asserts.nix`

Add assertions:

- `storeDiskInterface = "pmem"` requires `storeOnDisk = true`
- `storeDiskInterface = "pmem"` requires `storeDiskType = "erofs"`
- `storeDiskInterface = "pmem"` requires uncompressed erofs (no `-z` flags)
- `storeDiskInterface = "pmem"` only valid for `cloud-hypervisor` and
  `firecracker` (v1.14.0+)

Example shapes:

```nix
{
  assertion =
    config.microvm.storeDiskInterface != "pmem"
    || config.microvm.storeOnDisk;
  message = ''
    MicroVM ${hostName}: `microvm.storeDiskInterface = "pmem"` requires
    `microvm.storeOnDisk = true`.
  '';
}
{
  assertion =
    config.microvm.storeDiskInterface != "pmem"
    || config.microvm.storeDiskType == "erofs";
  message = ''
    MicroVM ${hostName}: `microvm.storeDiskInterface = "pmem"` requires
    `microvm.storeDiskType = "erofs"`.
  '';
}
{
  assertion =
    config.microvm.storeDiskInterface != "pmem"
    || !builtins.any (f: lib.hasPrefix "-z" f) config.microvm.storeDiskErofsFlags;
  message = ''
    MicroVM ${hostName}: `microvm.storeDiskInterface = "pmem"` requires
    uncompressed erofs. Compressed erofs (lz4, lz4hc) cannot use DAX —
    this is a hard kernel limitation. Remove compression flags from
    `microvm.storeDiskErofsFlags`.
  '';
}
```

### Verify

```bash
nix flake check
```

---

## Phase 2: Build 2 MiB-Aligned pmem Artifact

Cloud Hypervisor strictly rejects `--pmem` backing files whose size is not a
multiple of 2 MiB. Firecracker auto-pads internally with anonymous pages and
does not need alignment.

This phase must come before the runner phases because the Cloud Hypervisor
runner needs the aligned artifact path.

### 2a. Add an Internal Aligned Artifact Derivation

**File:** `nixos-modules/microvm/store-disk.nix`

When `storeDiskInterface = "pmem"`, produce a 2 MiB-aligned copy of the store
image alongside the original:

```nix
config.microvm._internal.storeDiskPmemImage =
  if config.microvm.storeDiskInterface == "pmem"
  then pkgs.runCommand "store-disk-pmem-aligned" {
    inherit (config.microvm) storeDisk;
  } ''
    cp $storeDisk $out
    size=$(stat -c%s $out)
    align=$((2 * 1024 * 1024))
    aligned=$(( ((size + align - 1) / align) * align ))
    truncate -s "$aligned" $out
  ''
  else config.microvm.storeDisk;
```

This is a pure Nix derivation — no imperative host-side scripts.

### 2b. Runner Selection Logic

Each backend runner selects the right artifact:

- **Cloud Hypervisor:** uses `config.microvm._internal.storeDiskPmemImage`
  (always aligned)
- **Firecracker:** uses `config.microvm.storeDisk` directly (Firecracker
  auto-pads, no copy needed)

### 2c. Keep `microvm.storeDisk` Unchanged

`microvm.storeDisk` retains its current meaning: the unpadded built store
image. The aligned derivative is internal only.

### Verify

```bash
nix build .#nixosConfigurations.<vm>.config.microvm._internal.storeDiskPmemImage
size=$(stat -c%s result)
echo "$size % (2*1024*1024) = $(( size % (2*1024*1024) ))"  # must be 0
```

---

## Phase 3: Make Guest Mount Logic Transport-Aware

### 3a. Make Store Device Selection Transport-Aware

**File:** `nixos-modules/microvm/mounts.nix`

Today `roStoreDisk` should be inferred as:

- `/dev/pmem0` for `pmem`
- `/dev/disk/by-label/nix-store` for blk `erofs`
- `/dev/vda` otherwise

Use an explicit pmem device for the pmem transport:

```nix
roStoreDisk =
  if !storeOnDisk then
    throw "No disk device when /nix/store is not on disk"
  else if storeDiskInterface == "pmem" then
    "/dev/pmem0"
  else if storeDiskType == "erofs" then
    "/dev/disk/by-label/nix-store"
  else
    "/dev/vda";
```

The current Choir and boot-test results support `/dev/pmem0` for the pmem
path. If a future environment proves label-based pmem lookup is reliable, this
can be relaxed with tests.

### 3b. Add DAX Mount Flags for `pmem + erofs`

For the store mount and the overlay lowerdir mount, add:

- `blk + erofs` -> `ro`
- `pmem + erofs` -> `ro` plus DAX option

Keep this explicit and narrow. Do not infer DAX for non-EROFS filesystems.

Conceptually:

```nix
storeMountOptions =
  [ "ro" "x-systemd.after=systemd-modules-load.service" ]
  ++ lib.optional (storeDiskInterface == "pmem" && storeDiskType == "erofs") "dax";
```

Use the exact option spelling that works with the current guest kernels and
existing test matrix.

### 3c. Keep Writable Overlay Behavior Unchanged

The overlay logic in `mounts.nix` should remain transport-agnostic from the
user’s point of view. Only the lowerdir source changes.

### Verify

Run backend boot tests for:

- `cloud-hypervisor + blk + erofs`
- `cloud-hypervisor + pmem + erofs`

and verify inside the guest:

```bash
mount | grep /nix/store          # should show dax flag for pmem
findmnt -n -o SOURCE /nix/store      # /dev/pmem0 for pmem, label path for blk
```

---

## Phase 4: Cloud Hypervisor Native `pmem`

### 4a. Keep `blk` on `--disk`

**File:** `lib/runners/cloud-hypervisor.nix`

Do not introduce a `--blk` CLI. Cloud Hypervisor’s normal block-device path is
already `--disk`.

For `storeDiskInterface = "blk"`:

- keep the built store image in the existing store `--disk` entry

### 4b. Emit `--pmem` for Store Image When Selected

For `storeDiskInterface = "pmem"`:

- remove the built store image from the `--disk` list
- emit a `--pmem` entry for that image instead
- keep normal user volumes on `--disk`

Use the aligned artifact from Phase 2:

```nix
+ lib.optionals (storeOnDisk && storeDiskInterface == "pmem") [
  "--pmem"
  "file=${toString config.microvm._internal.storeDiskPmemImage},discard_writes=on"
]
```

Cloud Hypervisor requires the file to be 2 MiB-aligned. The aligned artifact
from Phase 2 satisfies this — no runtime padding needed.

### 4c. No Imperative Runtime Rewrites

The alignment is handled by the Nix build graph (Phase 2). Do not add
`ExecStartPre` scripts to pad or copy the image at runtime.

### Verify

Inspect the generated runner command:

```bash
rg -- '--pmem|--disk' result*/bin/microvm-run
```

Expected:

- `blk`: store image appears under `--disk`
- `pmem`: store image appears under `--pmem`, mutable volumes remain under
  `--disk`

---

## Phase 5: Firecracker Native `pmem`

Firecracker added `virtio-pmem` in v1.14.0 (PR #5463). Unlike Cloud
Hypervisor, Firecracker auto-pads backing files to 2 MiB alignment with
anonymous `PRIVATE | ANONYMOUS` pages — no pre-alignment needed.

### 5a. Keep `blk` on `drives`

**File:** `lib/runners/firecracker.nix`

For `storeDiskInterface = "blk"`:

- keep the existing `drives = [ { drive_id = "store"; ... } ]`

### 5b. Emit a `pmem` Device When Selected

For `storeDiskInterface = "pmem"`:

- omit the store image from `drives`
- emit the store image in Firecracker’s `pmem` config array
- keep user volumes in `drives`
- use the **original** `storeDisk` directly (not the aligned artifact —
  Firecracker handles alignment internally)

Firecracker v1.14.0 `pmem` config schema (`PUT /pmem/{id}`):

```nix
baseConfig = {
  ...
  drives = optionalStoreDrive ++ map volumeToDrive volumes;
  pmem = lib.optional (storeOnDisk && storeDiskInterface == "pmem") {
    id = "store";
    path_on_host = toString config.microvm.storeDisk;
    root_device = false;
    read_only = true;
  };
};
```

Note the field names differ from the `drives` schema: `id` (not `drive_id`),
`path_on_host`, `root_device`, `read_only`.

### 5c. Respect Existing Volume Behavior

Do not change:

- `microvm.firecracker.driveIoEngine`
- normal block volume emission

### 5d. Security Note

Firecracker warns: on aarch64, writes to a read-only pmem device cause the VM
to stop (ENOSYS from KVM). On x86_64, writes are silently discarded with a log
warning. Using `read_only = true` for the immutable store is correct.

### Verify

Inspect the rendered Firecracker config JSON:

```bash
jq . result*/firecracker-*.json
```

Expected:

- `blk`: store appears in `drives`
- `pmem`: store appears in `pmem` array (not `drives`), uses original
  unpadded image path

---

## Phase 6: Documentation

Update:

- `README.md`
- `doc/src/options.md`
- example configs for:
  - Cloud Hypervisor + `blk`
  - Cloud Hypervisor + `pmem`
  - Firecracker + `blk`
  - Firecracker + `pmem`

Required documentation points:

- `blk` is the default and safe multi-tenant choice
- `pmem` is an optimization for immutable same-trust-domain or public corpora
- shared `pmem` backing files may leak access-pattern information across VMs
- `pmem` currently requires `storeOnDisk = true`, `storeDiskType = "erofs"`,
  and uncompressed erofs (no `-z` flags)
- Cloud Hypervisor requires 2 MiB-aligned backing files (handled by build graph)
- Firecracker auto-pads internally (no alignment needed)

---

## Phase 7: Tests

At minimum, add coverage for:

1. Cloud Hypervisor + `blk` immutable store boots and mounts `/nix/store`
2. Cloud Hypervisor + `pmem` immutable `erofs` store boots and mounts with DAX
3. Firecracker + `blk` immutable store boots and mounts `/nix/store`
4. Firecracker + `pmem` immutable `erofs` store boots and mounts with DAX
5. `pmem` on unsupported hypervisors fails evaluation
6. writable store overlay still works with either transport

Prefer tests that assert both:

- runner output/config generation
- guest-observed mount behavior

---

## Suggested PR Breakdown

### PR 1: Option + Alignment + Guest Mount + Cloud Hypervisor

This is the highest-value first merge because downstream Cloud Hypervisor users
already need the feature and currently patch around it.

Includes:

- `storeDiskInterface` option (Phase 1)
- assertions including compressed-erofs guard (Phase 1)
- 2 MiB-aligned artifact derivation (Phase 2)
- transport-aware guest mount logic (Phase 3)
- native Cloud Hypervisor `--pmem` (Phase 4)
- docs/tests for Cloud Hypervisor

### PR 2: Firecracker Parity

Add Firecracker `pmem` config generation (Phase 5) plus tests and docs.
Firecracker uses the original unpadded image directly.

### PR 3: Optional Follow-On Generalization

Only after the store-image path is stable:

- consider extending transport selection to other read-only volumes

---

## Downstream Validation Strategy

A downstream consumer that already uses Cloud Hypervisor should validate this
feature by:

1. vendoring the patched `microvm.nix`
2. removing any generated-runner rewrite for the store image
3. switching to `storeDiskInterface = "pmem"` for shared immutable tiers
4. keeping `storeDiskInterface = "blk"` for private tiers
5. comparing Cloud Hypervisor and Firecracker under the same logical config

This is the intended proving path for Choir.
