# cococoir/garage

S3-compatible object storage powered by [Garage](https://garagehq.deuxfleurs.fr/),
with bucket automation and FUSE mounts driven by the per-service modules
under `cococoir.services.*`.

This clan-service owns the cluster: the RPC secret, the node identity
(address, capacity), the global S3 access key, and the garage daemon. It
reads bucket and mount declarations from `cococoir.storage.buckets` and
`cococoir.storage.mounts`, which cococoir service modules (cryptpad,
jellyfin, qBittorrent, etc.) populate automatically. The user does not
declare buckets or mounts by hand.

## Roles

### `node`

A single garage node providing S3 storage.

#### Settings

- `address` — required. RPC bind address, e.g. `"10.0.0.2:3901"`.
- `capacity` — default `"1T"`. Storage this node contributes to its
  zone (used for capacity reporting in the bucket-init oneshot).

## Outputs (`cococoir.storage.derived.*`)

- `gatewayAddress` — e.g. `"127.0.0.1:3900"`.
- `buckets.<name>.{name,endpoint,host,port,region,accessKeyIdFile,secretAccessKeyFile}`
  — for native-S3 clients (e.g. Nextcloud).
- `mounts.<bucket>.{mountPoint,readOnly}` — for FUSE-consuming services
  (e.g. cryptpad, jellyfin).

## Clan vars

- `garage-rpc-secret` (shared) — cluster-wide RPC secret.
- `garage-global-s3-key` (shared) — pre-generated S3 access key and
  secret. Native-S3 modules read it via `builtins.readFile` at
  evaluation time; `bucket-init.sh` imports it into garage on first
  boot.
- `garage-admin-token`, `garage-metrics-token` (per-node).

## Example

```nix
clan.inventory.instances.cococoir-garage = {
  module = { input = "cococoir"; name = "cococoir-garage"; };
  roles.node = {
    machines.amon-sul = { };
    settings = {
      address = "192.168.0.7:3901";
      capacity = "1T";
    };
  };
};
```
