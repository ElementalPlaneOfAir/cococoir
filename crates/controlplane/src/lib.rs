// SPDX-License-Identifier: AGPL-3.0-or-later
//! fortress-controlplane — the remote-access provisioning service
//! that runs on the edge box (which *is* the control plane). Owns the
//! `fortress-edge` binary and the `[profiles.edge]` secret contract.

pub mod controlplane;

pub use controlplane::{
    app, control_plane, forwarder, generate_wg_keypair, init_globals, validate_machine_name,
    AdminKey, ControlPlane, ControlPlaneError, DnsApiClient, DnsError, HetznerDns, Machine,
    MockDnsApiClient, MockWgClient, RealWgClient, SignupResponse, Subnet64, WgClient, WgError,
    WgSubnet, DUMMY_EDGE_WG_PRIV, DUMMY_ROOT_DOMAIN,
};
pub use controlplane::web::{
    account_error_message, clear_session_cookie_header, read_cookie_from_headers,
    session_cookie_header, SESSION_COOKIE,
};
