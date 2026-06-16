# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Usage in a machine's disko.nix:
#   { inputs, ... }: {
#     imports = [ (inputs.cococoir.lib.mkGarageDataDisko {
#       device = "/dev/disk/by-id/...";
#       mountPoint = "/var/lib/cococoir/garage/data";
#     }) ];
#   }
#
# For multi-disk / multi-mountpoint layouts, inline disko directly and
# just point cococoir's dataDir at the resulting mountpoint.
{
  device,
  mountPoint,
  fsType ? "ext4",
}: {
  disko.devices.disk."cococoir-garage-data" = {
    inherit device;
    type = "disk";
    content = {
      type = "gpt";
      partitions.primary = {
        size = "100%";
        content = {
          type = "filesystem";
          format = fsType;
          mountpoint = mountPoint;
        };
      };
    };
  };
}
