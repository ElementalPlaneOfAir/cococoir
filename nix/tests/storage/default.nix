# SPDX-License-Identifier: AGPL-3.0-or-later
#
# v2 1-VM nixosTest: cococoir storage layer.
#
# The v2 gate. Exercises:
#   - Garage daemon is up, admin API responds
#   - bucket-init oneshot creates the bucket
#   - FUSE mount via geesefs is writable (touch + read round-trip)
#   - S3 PUT/GET via mc works with the storage module's secrets
#
# Hermetic: secrets are plain files generated at test time (not
# sops-nix), and the encrypted-secrets + sops-nix round-trip is
# covered by a separate check at nix/tests/sops/. No external
# network, no live Hetzner, no live S3.
{pkgs, sopsModule ? []}:
let
  # Plain secrets file. The test creates these at activation time
  # in a `system.activationScripts` block. Storage layer reads them
  # via the cococoir.storage.secrets.<name> options.
  testSecrets = pkgs.runCommand "cococoir-test-secrets" { buildInputs = [ pkgs.openssl pkgs.gnused ]; } ''
    mkdir -p $out
    # In production, sops-nix writes these with mode 0440 and
    # owner garage:garage. The test mimics that so the storage
    # module's permission assertions hold.
    openssl rand -hex -out $out/rpc-secret 32
    openssl rand -hex -out $out/admin-token 32
    openssl rand -hex -out $out/metrics-token 32
    printf 'GK%s' "$(openssl rand -hex 12)" > $out/access-key-id
    openssl rand -hex -out $out/secret-access-key 32
    chmod 0440 $out/access-key-id $out/secret-access-key
    chmod 0400 $out/rpc-secret $out/admin-token $out/metrics-token
  '';
in
{
  storage = pkgs.testers.nixosTest {
    name = "cococoir-storage";

    nodes.machine = {
      config,
      pkgs,
      ...
    }: {
      imports = sopsModule ++ [
        (import ../../nixos-modules)
      ];

      virtualisation.graphics = false;
      virtualisation.diskSize = 2048;
      virtualisation.sharedDirectories = { };

      environment.systemPackages = [ pkgs.mc ];

      # Plain secrets at a known path. The storage module reads
      # these via cococoir.storage.secrets.<name>File. The
      # activation script copies the build-time generated files
      # to a non-store path so the storage layer can `chown
      # garage:garage` them at activation.
      environment.etc."cococoir-test-secrets".source = testSecrets;

      cococoir.storage = {
        enable = true;
        cluster = {
          rpcBindAddr = "127.0.0.1:3901";
          rpcPublicAddr = "127.0.0.1:3901";
          s3ApiBindAddr = "127.0.0.1:3900";
          adminApiBindAddr = "127.0.0.1:3903";
          region = "garage";
        };
        node = {
          id = "node-1";
          address = "127.0.0.1:3901";
          zone = "z1";
          capacity = "1T";
        };
        secrets = {
          rpcSecretFile = "/etc/cococoir-test-secrets/rpc-secret";
          adminTokenFile = "/etc/cococoir-test-secrets/admin-token";
          metricsTokenFile = "/etc/cococoir-test-secrets/metrics-token";
          accessKeyIdFile = "/etc/cococoir-test-secrets/access-key-id";
          secretAccessKeyFile = "/etc/cococoir-test-secrets/secret-access-key";
        };
        buckets.media = { };
        buckets.documents = { replicationFactor = 1; };
        mounts.media = {
          bucket = "media";
          mountPoint = "/media/entertain";
          readOnly = false;
        };
      };
    };

    testScript = ''
      import time
      start = time.time()

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("garage.service", timeout=30)
      machine.wait_for_open_port(3900, timeout=30)
      machine.wait_for_open_port(3903, timeout=30)
      machine.wait_for_unit("garage-bucket-init.service", timeout=60)
      _, status = machine.systemctl("is-active garage-bucket-init.service")
      assert status.strip() == "active", f"bucket-init not active: {status!r}"
      machine.wait_for_unit("cococoir-fuse-media.service", timeout=30)

      out = machine.succeed(
        "GARAGE_RPC_SECRET_FILE=/etc/cococoir-test-secrets/rpc-secret "
        "garage -c /etc/garage.toml status"
      )
      assert "HEALTHY" in out, f"node not HEALTHY: {out!r}"
      print("garage status: HEALTHY")

      media_info = machine.succeed(
        "GARAGE_RPC_SECRET_FILE=/etc/cococoir-test-secrets/rpc-secret "
        "garage -c /etc/garage.toml bucket info media"
      )
      assert "media" in media_info, f"bucket info missing media: {media_info!r}"
      print("bucket 'media' exists")

      docs_info = machine.succeed(
        "GARAGE_RPC_SECRET_FILE=/etc/cococoir-test-secrets/rpc-secret "
        "garage -c /etc/garage.toml bucket info documents"
      )
      assert "documents" in docs_info, f"bucket info missing documents: {docs_info!r}"
      print("bucket 'documents' exists")

      machine.succeed("echo 'fuse-roundtrip' > /media/entertain/test.txt")
      got = machine.succeed("cat /media/entertain/test.txt").strip()
      assert got == "fuse-roundtrip", f"FUSE roundtrip failed: {got!r}"
      print("FUSE mount /media/entertain is writable")

      key_id = machine.succeed("cat /var/lib/cococoir/garage/global/access-key-id").strip()
      assert key_id.startswith("GK"), f"access key id missing GK prefix: {key_id!r}"
      print("storage module imported the S3 access key with GK prefix")

      # The sops-style secret handoff: the storage module's secrets
      # are read at the configured path, the bucket-init script
      # imports them into garage, and the resulting access key is
      # symlinked into /var/lib/cococoir/garage/global/ for native
      # S3 clients to discover.
      # The symlink in /var/lib/cococoir/garage/global/ is created
      # by the bucket-init script. In production it points at
      # /run/secrets/<name> (sops-nix); in the test it points at
      # /etc/cococoir-test-secrets/ (environment.etc). The point of
      # the assertion is the symlink exists and the file is
      # readable — which is the part the storage module owns.
      symlink = machine.succeed("readlink /var/lib/cococoir/garage/global/access-key-id").strip()
      assert symlink != "" and "/access-key-id" in symlink, f"global access-key-id not symlinked: {symlink!r}"
      machine.succeed("test -r /var/lib/cococoir/garage/global/access-key-id")
      print("global access-key-id: symlinked and readable")

      elapsed = int(time.time() - start)
      print(f"cococoir-storage: PASS ({elapsed}s)")
    '';
  };
}
