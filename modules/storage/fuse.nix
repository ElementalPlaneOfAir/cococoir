# SPDX-License-Identifier: MIT
{ config, lib, pkgs, ... }:
let
  cfg = config.cococoir.storage;
  enabledMounts = lib.filterAttrs (_: m: m.enable) cfg.mounts;
  localHost = builtins.elemAt (lib.splitString ":" cfg.node.address) 0;
  s3Port = toString cfg.cluster.s3ApiPort;
  globalKeyDir = "/var/lib/cococoir/garage/global";
in
{
  config = lib.mkIf cfg.enable {
    # Tmpfiles: ensure mount points exist
    systemd.tmpfiles.rules = lib.concatMap (m: [
      "d ${m.mountPoint} 0755 root root -"
    ]) (lib.attrValues enabledMounts);

    # FUSE mount units
    systemd.services = lib.mapAttrs' (name: m: {
      name = "var-lib-cococoir-mounts-${name}";
      value = {
        description = "Mount S3 bucket ${m.bucket} at ${m.mountPoint} (geesefs)";
        before = [ "var-lib-cococoir-mounts-${name}.mount" ];
        wantedBy = [ "var-lib-cococoir-mounts-${name}.mount" ];
        after = [ "network-online.target" "garage-bucket-init.service" ];
        requires = [ "garage-bucket-init.service" ];
        enable = m.enable;
        serviceConfig = {
          Type = "forking";
          User = "root";
          ExecStart = toString (lib.escapeShellArgs ([
            "${m.package}/bin/geesefs"
            "--endpoint" "http://${localHost}:${s3Port}"
            "--access-key-file" "${globalKeyDir}/access-key-id"
            "--secret-key-file" "${globalKeyDir}/secret-access-key"
            (if m.readOnly then "--ro" else "")
            "--allow-other"
          ] ++ m.extraOptions ++ [ m.bucket m.mountPoint ]));
          ExecStop = "${pkgs.fuse}/bin/fusermount -u ${m.mountPoint}";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    }) enabledMounts;

    systemd.mounts = lib.mapAttrs' (name: m: {
      name = "var-lib-cococoir-mounts-${name}";
      value = {
        description = "geesefs mount of bucket ${m.bucket} at ${m.mountPoint}";
        where = m.mountPoint;
        what = m.bucket;
        type = "fuse.geesefs";
        mountConfig = {
          Options = lib.concatStringsSep "," ([
            "allow_other"
            (if m.readOnly then "ro" else "rw")
          ] ++ m.extraOptions);
        };
      };
    }) enabledMounts;
  };
}
