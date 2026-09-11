// SPDX-License-Identifier: AGPL-3.0-or-later
//! fortress-client — the customer box: the L4 forwarder that receives
//! traffic from the edge and the embedded config dashboard, run as one
//! process (`fortress-client`).

pub mod app;
pub mod dashboard;
pub mod tunnel;
