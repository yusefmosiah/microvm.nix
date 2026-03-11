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

  # Helper to build a NixOS config for KVM boot tests
  mkBootConfig = { hypervisor }: lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.microvm
      ({ config, lib, pkgs, ... }: {
        networking = {
          hostName = "pmem-boot-test";
          useDHCP = false;
        };
        microvm = {
          inherit hypervisor;
          storeDiskInterface = "pmem";
          storeDiskType = "erofs";
          storeDiskErofsFlags = [];
          volumes = [ {
            image = "output.img";
            label = "output";
            mountPoint = "/output";
            size = 32;
          } ];
          socket = "pmem-boot-test.sock";
        };
        systemd.services.poweroff-again = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "idle";
          script =
            let
              exit = {
                cloud-hypervisor = "poweroff";
                firecracker = "reboot";
              }.${hypervisor};
            in ''
              ${pkgs.util-linux}/bin/findmnt -n -o SOURCE /nix/store > /output/store-source
              ${pkgs.util-linux}/bin/findmnt -n -o OPTIONS /nix/store > /output/store-options
              ${exit}
            '';
        };
        system.stateVersion = lib.trivial.release;
      })
    ];
  };

  chPmemBoot = mkBootConfig { hypervisor = "cloud-hypervisor"; };
  fcPmemBoot = mkBootConfig { hypervisor = "firecracker"; };

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

  # Verify store device and mount options for pmem
  chPmemStoreDevice = chPmem.config.fileSystems."/nix/store".device;
  chBlkStoreDevice = chBlk.config.fileSystems."/nix/store".device;
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

    # CH pmem runner must have discard_writes=on in pmem arg
    echo "$chPmemScript" | grep -q 'discard_writes=on' || {
      echo "FAIL: cloud-hypervisor pmem runner missing discard_writes=on"
      exit 1
    }
    echo "PASS: cloud-hypervisor pmem runner has discard_writes=on"

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
    fcPmemScript=$(cat ${fcPmemRunner}/bin/microvm-run)
    fcPmemConfigPath=$(printf '%s\n' "$fcPmemScript" | grep -o '/nix/store/[^ ]*firecracker-[^ ]*\.json' | head -1)
    test -n "$fcPmemConfigPath" || {
      echo "FAIL: could not find Firecracker pmem config JSON path"
      exit 1
    }
    fcPmemConfig=$(cat "$fcPmemConfigPath")
    echo "$fcPmemConfig"

    printf '%s\n' "$fcPmemConfig" | grep -q '"pmem"' || {
      echo "FAIL: firecracker pmem config missing pmem section"
      exit 1
    }
    printf '%s\n' "$fcPmemConfig" | grep -q '"path_on_host"' || {
      echo "FAIL: firecracker pmem config missing path_on_host"
      exit 1
    }
    echo "PASS: firecracker pmem config has pmem section"

    echo ""
    echo "=== Firecracker blk config ==="
    fcBlkScript=$(cat ${fcBlkRunner}/bin/microvm-run)
    fcBlkConfigPath=$(printf '%s\n' "$fcBlkScript" | grep -o '/nix/store/[^ ]*firecracker-[^ ]*\.json' | head -1)
    test -n "$fcBlkConfigPath" || {
      echo "FAIL: could not find Firecracker blk config JSON path"
      exit 1
    }
    fcBlkConfig=$(cat "$fcBlkConfigPath")

    if printf '%s\n' "$fcBlkConfig" | grep -q '"pmem"'; then
      echo "FAIL: firecracker blk config should not have pmem section"
      exit 1
    fi
    printf '%s\n' "$fcBlkConfig" | grep -q '"drives"' || {
      echo "FAIL: firecracker blk config missing drives section"
      exit 1
    }
    echo "PASS: firecracker blk config uses drives only"

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
    echo "=== Store mount config check ==="
    chPmemOpts="${builtins.concatStringsSep " " chPmemMountOpts}"
    chBlkOpts="${builtins.concatStringsSep " " chBlkMountOpts}"

    chPmemDevice="${chPmemStoreDevice}"
    chBlkDevice="${chBlkStoreDevice}"
    [ "$chPmemDevice" = "/dev/pmem0" ] || {
      echo "FAIL: pmem store device should be /dev/pmem0 (got: $chPmemDevice)"
      exit 1
    }
    echo "PASS: pmem store device uses /dev/pmem0"
    [ "$chBlkDevice" = "/dev/disk/by-label/nix-store" ] || {
      echo "FAIL: blk store device should be /dev/disk/by-label/nix-store (got: $chBlkDevice)"
      exit 1
    }
    echo "PASS: blk store device uses label-based lookup"

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

  pmem-boot-cloud-hypervisor = pkgs.runCommandLocal "pmem-boot-cloud-hypervisor" {
    nativeBuildInputs = [
      chPmemBoot.config.microvm.declaredRunner
      pkgs.p7zip
    ];
    requiredSystemFeatures = [ "kvm" ];
    meta.timeout = 120;
  } ''
    microvm-run
    7z e output.img store-source store-options

    echo "Store source: $(cat store-source)"
    echo "Store options: $(cat store-options)"

    grep -q 'pmem' store-source || {
      echo "FAIL: /nix/store not pmem-backed (got: $(cat store-source))"
      exit 1
    }
    echo "PASS: /nix/store is pmem-backed"

    grep -q 'dax' store-options || {
      echo "FAIL: /nix/store missing dax mount option (got: $(cat store-options))"
      exit 1
    }
    echo "PASS: /nix/store has dax mount option"

    mkdir $out
    cp {store-source,store-options} $out
  '';

  pmem-boot-firecracker = pkgs.runCommandLocal "pmem-boot-firecracker" {
    nativeBuildInputs = [
      fcPmemBoot.config.microvm.declaredRunner
      pkgs.p7zip
    ];
    requiredSystemFeatures = [ "kvm" ];
    meta.timeout = 120;
  } ''
    microvm-run
    7z e output.img store-source store-options

    echo "Store source: $(cat store-source)"
    echo "Store options: $(cat store-options)"

    grep -q 'pmem' store-source || {
      echo "FAIL: /nix/store not pmem-backed (got: $(cat store-source))"
      exit 1
    }
    echo "PASS: /nix/store is pmem-backed"

    grep -q 'dax' store-options || {
      echo "FAIL: /nix/store missing dax mount option (got: $(cat store-options))"
      exit 1
    }
    echo "PASS: /nix/store has dax mount option"

    mkdir $out
    cp {store-source,store-options} $out
  '';
}
