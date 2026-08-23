// SPDX-License-Identifier: AGPL-3.0-or-later
//! cococoir-controlplane — the remote-access provisioning service
//! that runs on the edge box (which *is* the control plane). Owns the
//! `cococoir-edge` binary and the `[profiles.edge]` secret contract.

pub mod controlplane;

pub use controlplane::{
    app, control_plane, forwarder, generate_wg_keypair, init_globals, routing_table,
    validate_username, AdminKey, ControlPlane, ControlPlaneError, Customer, DnsApiClient, DnsError,
    HetznerDns, MockDnsApiClient, RealWgClient, RoutingTable, SignupResponse, Subnet64, WgClient,
    WgError, WgPeer, WgSubnet,
};
