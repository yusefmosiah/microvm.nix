{ self, nixpkgs, system }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;

  # Helper to build a NixOS config with given microvm settings
  mkConfig = { hypervisor, storeDiskInterface ? "blk", extraModules ? [] }:
    (lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.microvm
        {
          networking.hostName = "pmem-test";
          microvm = {
            inherit hypervisor storeDiskInterface;
            storeOnDisk = true;
            storeDiskType = "erofs";
            storeDiskErofsFlags = [];
            socket = "pmem-test.sock";
          };
          system.stateVersion = lib.trivial.release;
        }
      ] ++ extraModules;
    });

  # Cloud Hypervisor with pmem
  chPmem = mkConfig {
    hypervisor = "cloud-hypervisor";
    storeDiskInterface = "pmem";
  };

  # Cloud Hypervisor with blk (default)
  chBlk = mkConfig {
    hypervisor = "cloud-hypervisor";
    storeDiskInterface = "blk";
  };

  # Firecracker with pmem
  fcPmem = mkConfig {
    hypervisor = "firecracker";
    storeDiskInterface = "pmem";
  };

  # Firecracker with blk (default)
  fcBlk = mkConfig {
    hypervisor = "firecracker";
    storeDiskInterface = "blk";
  };

  # Read the generated runner script
  chPmemRunner = chPmem.config.microvm.declaredRunner;
  chBlkRunner = chBlk.config.microvm.declaredRunner;
  fcPmemRunner = fcPmem.config.microvm.declaredRunner;
  fcBlkRunner = fcBlk.config.microvm.declaredRunner;

  # Verify alignment of pmem image
  chPmemImage = chPmem.config.microvm.storeDiskPmemImage;

  # Verify mount options include dax for pmem
  chPmemMountOpts = chPmem.config.fileSystems."/nix/store".options;
  chBlkMountOpts = chBlk.config.fileSystems."/nix/store".options;

in
{
  pmem-runner-generation = pkgs.runCommandLocal "pmem-runner-generation" {
    nativeBuildInputs = [ pkgs.gnugrep ];
  } ''
    set -euo pipefail

    echo "=== Cloud Hypervisor pmem runner ==="
    chPmemScript=$(cat ${chPmemRunner}/bin/microvm-run)
    echo "$chPmemScript"

    # CH pmem runner must have --pmem
    echo "$chPmemScript" | grep -q -- '--pmem' || {
      echo "FAIL: cloud-hypervisor pmem runner missing --pmem"
      exit 1
    }
    echo "PASS: cloud-hypervisor pmem runner has --pmem"

    # CH pmem runner must have readonly=on in pmem arg
    echo "$chPmemScript" | grep -q 'readonly=on' || {
      echo "FAIL: cloud-hypervisor pmem runner missing readonly=on"
      exit 1
    }
    echo "PASS: cloud-hypervisor pmem runner has readonly=on"

    echo ""
    echo "=== Cloud Hypervisor blk runner ==="
    chBlkScript=$(cat ${chBlkRunner}/bin/microvm-run)

    # CH blk runner must NOT have --pmem
    if echo "$chBlkScript" | grep -q -- '--pmem'; then
      echo "FAIL: cloud-hypervisor blk runner should not have --pmem"
      exit 1
    fi
    echo "PASS: cloud-hypervisor blk runner has no --pmem"

    # CH blk runner must have --disk with store
    echo "$chBlkScript" | grep -q -- '--disk' || {
      echo "FAIL: cloud-hypervisor blk runner missing --disk"
      exit 1
    }
    echo "PASS: cloud-hypervisor blk runner has --disk"

    echo ""
    echo "=== Firecracker pmem config ==="
    fcPmemConfig=$(cat ${fcPmemRunner}/bin/microvm-run)
    echo "$fcPmemConfig"

    echo ""
    echo "=== Firecracker blk config ==="
    fcBlkConfig=$(cat ${fcBlkRunner}/bin/microvm-run)

    echo ""
    echo "=== Alignment check ==="
    size=$(stat -c%s ${chPmemImage})
    align=$((2 * 1024 * 1024))
    remainder=$((size % align))
    if [ "$remainder" -ne 0 ]; then
      echo "FAIL: pmem image size $size is not 2 MiB aligned (remainder: $remainder)"
      exit 1
    fi
    echo "PASS: pmem image is 2 MiB aligned (size: $size)"

    echo ""
    echo "=== Mount options check ==="
    chPmemOpts="${builtins.concatStringsSep " " chPmemMountOpts}"
    chBlkOpts="${builtins.concatStringsSep " " chBlkMountOpts}"

    echo "CH pmem mount options: $chPmemOpts"
    echo "CH blk mount options: $chBlkOpts"

    echo "$chPmemOpts" | grep -q 'dax' || {
      echo "FAIL: pmem mount options missing 'dax'"
      exit 1
    }
    echo "PASS: pmem mount options include 'dax'"

    if echo "$chBlkOpts" | grep -q 'dax'; then
      echo "FAIL: blk mount options should not include 'dax'"
      exit 1
    fi
    echo "PASS: blk mount options do not include 'dax'"

    echo ""
    echo "All pmem runner generation checks passed!"
    mkdir $out
  '';
}
