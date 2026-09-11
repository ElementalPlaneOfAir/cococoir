// SPDX-License-Identifier: AGPL-3.0-or-later
//! fortress-controlplane — the remote-access provisioning service
//! that runs on the edge box (which *is* the control plane). Owns the
//! `fortress-edge` binary and the `[profiles.edge]` secret contract.

pub mod controlplane;

pub use controlplane::{
    app, control_plane, forwarder, generate_wg_keypair, init_globals, validate_username, AdminKey,
    ControlPlane, ControlPlaneError, Customer, DnsApiClient, DnsError, HetznerDns, MockDnsApiClient,
    RealWgClient, SignupResponse, Subnet64, WgClient, WgError, WgSubnet,
};
