{ config, lib, pkgs, ... }:

let
  regInfo = pkgs.closureInfo {
    rootPaths = [ config.system.build.toplevel ];
  };

  erofs-utils =
    # Are any extended options specified?
    if lib.any (with lib; flip elem ["-Ededupe" "-Efragments"]) config.microvm.storeDiskErofsFlags
    then
      # If extended options are present,
      # stick to the single-threaded erofs-utils
      # to not scare anyone with warning messages.
      pkgs.buildPackages.erofs-utils
    else
      # If no extended options are configured,
      # rebuild mkfs.erofs with multi-threading.
      pkgs.buildPackages.erofs-utils.overrideAttrs (attrs: {
        configureFlags = attrs.configureFlags ++ [
          "--enable-multithreading"
        ];
      });

  erofsFlags = builtins.concatStringsSep " " config.microvm.storeDiskErofsFlags;
  squashfsFlags = builtins.concatStringsSep " " config.microvm.storeDiskSquashfsFlags;

  mkfsCommand =
    {
      squashfs = "gensquashfs ${squashfsFlags} -D store --all-root -q $out";
      erofs = "mkfs.erofs ${erofsFlags} -T 0 --all-root -L nix-store --mount-point=/nix/store $out store";
    }.${config.microvm.storeDiskType};

  writeClosure = pkgs.writeClosure or pkgs.writeReferencesToFile;

  storeDiskContents = writeClosure (
    [ config.system.build.toplevel ]
    ++
    lib.optional config.nix.enable regInfo
  );

in
{
  options.microvm.storeDisk = with lib; mkOption {
    type = types.path;
    description = ''
      Generated
    '';
  };

  options.microvm.storeDiskPmemImage = with lib; mkOption {
    type = types.path;
    internal = true;
    description = ''
      2 MiB-aligned store disk image for pmem attachment.
      Used by cloud-hypervisor which requires aligned backing files.
      Firecracker auto-pads internally and uses storeDisk directly.
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf (config.microvm.guest.enable && config.microvm.storeOnDisk) {
      # nixos/modules/profiles/hardened.nix forbids erofs.
      # HACK: Other NixOS modules populate
      # config.boot.blacklistedKernelModules depending on the boot
      # filesystems, so checking on that directly would result in an
      # infinite recursion.
      microvm.storeDiskType = lib.mkDefault (
        if config.security.virtualisation.flushL1DataCache == "always"
        then "squashfs"
        else "erofs"
      );
      boot.initrd.availableKernelModules = [
        config.microvm.storeDiskType
      ];

      microvm.storeDisk = pkgs.runCommandLocal "microvm-store-disk.${config.microvm.storeDiskType}" {
        nativeBuildInputs = [
          pkgs.buildPackages.time
          pkgs.buildPackages.bubblewrap
          {
            squashfs = pkgs.buildPackages.squashfs-tools-ng;
            erofs = erofs-utils;
          }.${config.microvm.storeDiskType}
        ];
        passthru = {
          inherit regInfo;
        };
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      } ''
        mkdir store
        BWRAP_ARGS="--dev-bind / / --chdir $(pwd)"
        for d in $(sort -u ${storeDiskContents}); do
          BWRAP_ARGS="$BWRAP_ARGS --ro-bind $d $(pwd)/store/$(basename $d)"
        done

        echo Creating a ${config.microvm.storeDiskType}
        bwrap $BWRAP_ARGS -- time ${mkfsCommand} || \
          (
            echo "Bubblewrap failed. Falling back to copying...">&2
            cp -a $(sort -u ${storeDiskContents}) store/
            time ${mkfsCommand}
          )
      '';
    })

    (lib.mkIf (config.microvm.guest.enable && config.microvm.storeOnDisk && config.microvm.storeDiskInterface == "pmem") {
      # virtio_pmem must be loaded early in the initrd so the pmem device
      # appears before systemd-udevd creates /dev/disk/by-label symlinks.
      # kernelModules force-loads at initrd start; availableKernelModules
      # only makes the module present but relies on hotplug autoloading,
      # which is too slow and causes device-wait timeouts.
      # cbc must come before virtio_pmem: encrypted-keys.ko (a dep of
      # libnvdimm.ko, which in turn is a dep of virtio_pmem.ko) calls
      # crypto_alloc_skcipher("cbc(aes)") in its module_init. With
      # CONFIG_KEY_DH_OPERATIONS=y (NixOS default), the "cbc(aes)" template
      # is selected. cbc.ko provides the template via CONFIG_CRYPTO_CBC=m
      # but is NOT listed in modules.dep for encrypted-keys.ko (it is a
      # runtime crypto registration, not a symbol export). Loading cbc
      # before virtio_pmem ensures the template is registered.
      boot.initrd.kernelModules = [ "cbc" "virtio_pmem" ];

      # On kernels built with CONFIG_NVDIMM_KEYS=y (the NixOS default),
      # libnvdimm.ko has a hard symbol dependency on encrypted-keys.ko,
      # which lists trusted.ko as a pre-softdep. trusted.ko probes TPM/TEE
      # backends at init time and returns -ENODEV in VMs without a vTPM,
      # causing the full dep chain (trusted → encrypted-keys → libnvdimm →
      # virtio_pmem) to fail in systemd-modules-load.service.
      #
      # The install rule intercepts modprobe calls for 'trusted' (including
      # those from dep resolution) and substitutes /bin/true, returning
      # success without loading the module. encrypted-keys.ko references
      # trusted only via a runtime request_key() lookup (MODULE_SOFTDEP,
      # not a hard symbol import), so it loads and exports key_type_encrypted
      # normally. libnvdimm.ko and virtio_pmem.ko then load successfully.
      #
      # boot.extraModprobeConfig is propagated into the initrd by NixOS
      # for both busybox (stage-1.nix) and systemd initrd.
      # /bin/true is provided by pkgs.coreutils, which is in initrdBin by
      # default.
      boot.extraModprobeConfig = "install trusted /bin/true";

      microvm.storeDiskPmemImage = pkgs.runCommand "store-disk-pmem-aligned" {} ''
        cp ${config.microvm.storeDisk} $out
        chmod u+w $out
        size=$(stat -c%s $out)
        align=$((2 * 1024 * 1024))
        aligned=$(( ((size + align - 1) / align) * align ))
        truncate -s "$aligned" $out
      '';
    })

    (lib.mkIf (config.microvm.registerClosure && config.nix.enable) {
      microvm.kernelParams = [
        "regInfo=${regInfo}/registration"
      ];
      boot.postBootCommands = ''
        if [[ "$(cat /proc/cmdline)" =~ regInfo=([^ ]*) ]]; then
          ${config.nix.package.out}/bin/nix-store --load-db < ''${BASH_REMATCH[1]}
        fi
      '';
    })
  ];
}
