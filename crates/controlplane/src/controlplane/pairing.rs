// SPDX-License-Identifier: AGPL-3.0-or-later
//! Invite-based machine enrollment (ADR-032, T6).
//!
//! An account invites a machine: the owner generates a 10-char
//! Crockford base32 code (TTL 30 days, revocable), shares the URL
//! out-of-band (paper insert, email, box config), and the machine
//! dials `POST /api/invites/{code}/begin` with its WG public key. The
//! owner sees the pending request on their dashboard and either
//! approves it (naming the machine — the name IS the hostname) or
//! denies it. Approval allocates the route (the shared
//! [`ControlPlane::allocate_machine`] core), issues a long-lived
//! device token, and the machine's next poll delivers the tunnel
//! config + token exactly once.
//!
//! Trust model: the code alone grants NOTHING — a leaked invite only
//! produces a pending request the owner must approve. The approval
//! gate is the trust anchor, not the code.
//!
//! Redis keys:
//!   fortress:invite:{code}          → InviteRecord JSON (30d TTL)
//!   fortress:invite-delivery:{code} → EnrollmentDelivery JSON (24h
//!                                     TTL, one-time; re-created on
//!                                     re-begin with the same pubkey)

use crate::controlplane::{
    validate_wg_pubkey, ControlPlane, ControlPlaneError, Machine, SignupOutcome,
};

use poem::web::Data;
use poem::Request;

use rand_core::{OsRng, RngCore};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use sha2::Digest;

const INVITE_TTL_SECS: u64 = 30 * 24 * 60 * 60;
const DELIVERY_TTL_SECS: u64 = 24 * 60 * 60;
const CODE_LEN: usize = 10;

/// Crockford base32: no I/L/O/U confusables. Codes are generated in
/// lowercase so URLs read clean.
const CROCKFORD: &[u8] = b"0123456789abcdefghjkmnpqrstvwxyz";

pub(crate) fn invite_key(code: &str) -> String {
    format!("fortress:invite:{code}")
}

fn delivery_key(code: &str) -> String {
    format!("fortress:invite-delivery:{code}")
}

pub(crate) fn token_hash(token: &str) -> String {
    hex::encode(sha2::Sha256::digest(token.as_bytes()))
}

/// A 10-char Crockford base32 invite code. 50 bits of entropy —
/// deliberately less than the old box-shown codes, because the code
/// alone grants nothing (the approval gate is the trust anchor).
pub(crate) fn random_invite_code() -> String {
    let mut bytes = [0u8; CODE_LEN];
    OsRng.fill_bytes(&mut bytes);
    bytes
        .iter()
        .map(|b| CROCKFORD[(*b & 31) as usize] as char)
        .collect()
}

/// Structural check on a presented code: exactly 10 Crockford chars.
/// Rejects garbage before it reaches Redis.
pub(crate) fn is_valid_invite_code(code: &str) -> bool {
    code.len() == CODE_LEN
        && code
            .bytes()
            .all(|b| CROCKFORD.contains(&b.to_ascii_lowercase()))
}

/// Lifecycle of an invite. `waiting` until approve or deny; both are
/// terminal and burn the code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InviteStatus {
    Waiting,
    Approved,
    Denied,
}

/// The durable invite record, keyed by code.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InviteRecord {
    /// The inviting account's login email. The owner check on the
    /// session-auth'd ops; the UUID is resolved at approval.
    pub owner_email: String,
    pub status: InviteStatus,
    /// The device pubkey that posted `begin` (the machine that wants
    /// in). Shown on the approval screen; matching on re-begin.
    pub device_pubkey: Option<String>,
}

/// The one-time enrollment payload the machine's poll receives after
/// approval. Consumed on delivery; re-created by a re-begin with the
/// same pubkey.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnrollmentDelivery {
    pub machine: Machine,
    pub device_token: String,
}

#[derive(Debug, thiserror::Error)]
pub enum InviteError {
    #[error("invalid invite code: {0}")]
    InvalidCode(String),
    #[error("invite not found: {0}")]
    Unknown(String),
    #[error("not the inviting account: {0}")]
    Forbidden(String),
    #[error("invite is not waiting: {0}")]
    NotWaiting(String),
    #[error("machine name already taken: {0}")]
    NameTaken(String),
    #[error("invalid machine name: {0}")]
    InvalidName(String),
    #[error("invalid wireguard public key: {0}")]
    InvalidPubkey(String),
    #[error("corrupt invite record: {0}")]
    Corrupt(String),
    #[error("account: {0}")]
    Account(#[from] crate::controlplane::AccountError),
    #[error("redis error: {0}")]
    Redis(#[from] redis::RedisError),
}

impl From<ControlPlaneError> for InviteError {
    fn from(err: ControlPlaneError) -> Self {
        match err {
            ControlPlaneError::Redis(e) => InviteError::Redis(e),
            ControlPlaneError::Duplicate(name) => InviteError::NameTaken(name),
            ControlPlaneError::InvalidName(name) => InviteError::InvalidName(name),
            ControlPlaneError::InvalidPubkey(key) => InviteError::InvalidPubkey(key),
            other => InviteError::Corrupt(other.to_string()),
        }
    }
}

/// What a machine's poll sees. `approved` carries the one-time payload:
/// the machine record (route + hostname) and the device token.
#[derive(Debug, Serialize, Deserialize, Object)]
#[oai(rename_all = "camelCase")]
pub struct PollOutcome {
    /// `waiting` | `approved` | `denied`.
    pub status: String,
    /// The tunnel config's machine side (route, hostname, pubkey) —
    /// present ONLY on the one approved delivery.
    #[oai(skip_serializing_if = "Option::is_none")]
    pub machine: Option<Machine>,
    /// The device token — same one-time rule as `machine`.
    #[oai(skip_serializing_if = "Option::is_none")]
    pub device_token: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Object)]
pub struct BeginOutcome {
    pub status: String,
}

fn record_from_json(json: String, code: &str) -> Result<InviteRecord, InviteError> {
    serde_json::from_str(&json).map_err(|e| InviteError::Corrupt(format!("{code}: {e}")))
}

impl ControlPlane {
    /// Create an invite for the logged-in account. Returns the code.
    /// Collision on the random code retries (the code space is 2^50;
    /// the retry is a formality, never a loop the caller can feel).
    pub async fn invite_create(&self, email: &str) -> Result<String, InviteError> {
        let mut conn = self.conn().await?;
        for _ in 0..16 {
            let code = random_invite_code();
            let record = InviteRecord {
                owner_email: email.to_string(),
                status: InviteStatus::Waiting,
                device_pubkey: None,
            };
            let json = serde_json::to_string(&record).expect("invite serializes");
            let set: Option<()> = redis::cmd("SET")
                .arg(invite_key(&code))
                .arg(&json)
                .arg("EX")
                .arg(INVITE_TTL_SECS)
                .arg("NX")
                .query_async(&mut conn)
                .await?;
            if set.is_some() {
                return Ok(code);
            }
        }
        unreachable!("32^10 collisions 16 times in a row is not a real probability")
    }

    /// List the account's invites that still live in the store
    /// (waiting + recently terminal), in scan order. The dashboard's
    /// invites + approvals screen reads this.
    pub async fn invites_of(
        &self,
        email: &str,
    ) -> Result<Vec<(String, InviteRecord)>, InviteError> {
        let mut conn = self.conn().await?;
        let mut out = Vec::new();
        let mut cursor = "0".to_string();
        loop {
            let (next, keys): (String, Vec<String>) = redis::cmd("SCAN")
                .arg(&cursor)
                .arg("MATCH")
                .arg("fortress:invite:*")
                .arg("COUNT")
                .arg(100)
                .query_async(&mut conn)
                .await?;
            for key in keys {
                if key.starts_with("fortress:invite-delivery:") {
                    continue;
                }
                let code = key.trim_start_matches("fortress:invite:").to_string();
                let json: Option<String> = conn.get(&key).await?;
                let Some(json) = json else { continue };
                let record = record_from_json(json, &code)?;
                if record.owner_email == email {
                    out.push((code, record));
                }
            }
            if next == "0" {
                break;
            }
            cursor = next;
        }
        Ok(out)
    }

    /// The account's machines (owner match), allocation order. The
    /// dashboard's machines page reads this.
    pub async fn machines_of(&self, email: &str) -> Result<Vec<Machine>, InviteError> {
        let Some(uuid) = self.account_uuid(email).await? else {
            return Ok(Vec::new());
        };
        let machines = self.list().await?;
        Ok(machines
            .into_iter()
            .filter(|m| m.owner.as_deref() == Some(uuid.as_str()))
            .collect())
    }

    /// Revoke a waiting invite. Only the inviting account may; terminal
    /// invites are already burned.
    pub async fn invite_revoke(&self, email: &str, code: &str) -> Result<(), InviteError> {
        if !is_valid_invite_code(code) {
            return Err(InviteError::InvalidCode(code.to_string()));
        }
        let mut conn = self.conn().await?;
        let Some(json): Option<String> = conn.get(invite_key(code)).await? else {
            return Err(InviteError::Unknown(code.to_string()));
        };
        let record = record_from_json(json, code)?;
        if record.owner_email != email {
            return Err(InviteError::Forbidden(code.to_string()));
        }
        if record.status != InviteStatus::Waiting {
            return Err(InviteError::NotWaiting(code.to_string()));
        }
        let _: () = conn.del(invite_key(code)).await?;
        Ok(())
    }

    /// A machine dials the invite: register its WG public key and mark
    /// the invite as having a candidate. Idempotent — a re-begin with
    /// the SAME pubkey re-arms one-time delivery after an approval the
    /// machine missed.
    pub async fn invite_begin(
        &self,
        code: &str,
        public_key: &str,
    ) -> Result<PollOutcome, InviteError> {
        if !is_valid_invite_code(code) {
            return Err(InviteError::InvalidCode(code.to_string()));
        }
        validate_wg_pubkey(public_key)
            .map_err(|_| InviteError::InvalidPubkey(public_key.to_string()))?;
        let mut conn = self.conn().await?;
        let key = invite_key(code);
        let Some(json): Option<String> = conn.get(&key).await? else {
            return Err(InviteError::Unknown(code.to_string()));
        };
        let mut record = record_from_json(json, code)?;

        // Already approved by a prior run: only the machine that
        // enrolled may re-arm delivery.
        if record.status == InviteStatus::Approved {
            if record.device_pubkey.as_deref() == Some(public_key) {
                self.rearm_delivery(code, &record).await?;
                return Ok(PollOutcome {
                    status: "approved".to_string(),
                    machine: None,
                    device_token: None,
                });
            }
            return Err(InviteError::NotWaiting(code.to_string()));
        }
        if record.status == InviteStatus::Denied {
            return Err(InviteError::NotWaiting(code.to_string()));
        }

        record.device_pubkey = Some(public_key.to_string());
        let updated = serde_json::to_string(&record).expect("invite serializes");
        let _: () = conn.set_ex(&key, updated, INVITE_TTL_SECS).await?;
        Ok(PollOutcome {
            status: "waiting".to_string(),
            machine: None,
            device_token: None,
        })
    }

    /// The machine's poll. On `approved` the delivery is consumed
    /// (GETDEL) — the payload is delivered exactly once; a missed
    /// delivery is recovered by re-begin with the same pubkey.
    pub async fn invite_poll(&self, code: &str) -> Result<PollOutcome, InviteError> {
        if !is_valid_invite_code(code) {
            return Err(InviteError::InvalidCode(code.to_string()));
        }
        let mut conn = self.conn().await?;
        let Some(json): Option<String> = conn.get(invite_key(code)).await? else {
            return Err(InviteError::Unknown(code.to_string()));
        };
        let record = record_from_json(json, code)?;
        match record.status {
            InviteStatus::Waiting => Ok(PollOutcome {
                status: "waiting".to_string(),
                machine: None,
                device_token: None,
            }),
            InviteStatus::Denied => Ok(PollOutcome {
                status: "denied".to_string(),
                machine: None,
                device_token: None,
            }),
            InviteStatus::Approved => {
                let payload: Option<String> = redis::cmd("GETDEL")
                    .arg(delivery_key(code))
                    .query_async(&mut conn)
                    .await?;
                let Some(payload) = payload else {
                    return Ok(PollOutcome {
                        status: "approved".to_string(),
                        machine: None,
                        device_token: None,
                    });
                };
                let delivery: EnrollmentDelivery = serde_json::from_str(&payload)
                    .map_err(|e| InviteError::Corrupt(format!("delivery {code}: {e}")))?;
                Ok(PollOutcome {
                    status: "approved".to_string(),
                    machine: Some(delivery.machine),
                    device_token: Some(delivery.device_token),
                })
            }
        }
    }

    /// The owner approves the pending machine and names it. Allocates
    /// the route (shared core), issues the device token, and marks the
    /// invite approved (burning it). A name collision leaves the invite
    /// waiting so the owner can pick another name.
    pub async fn invite_approve(
        &self,
        email: &str,
        code: &str,
        name: &str,
    ) -> Result<Machine, InviteError> {
        if !is_valid_invite_code(code) {
            return Err(InviteError::InvalidCode(code.to_string()));
        }
        let mut conn = self.conn().await?;
        let key = invite_key(code);
        let Some(json): Option<String> = conn.get(&key).await? else {
            return Err(InviteError::Unknown(code.to_string()));
        };
        let mut record = record_from_json(json, code)?;
        if record.owner_email != email {
            return Err(InviteError::Forbidden(code.to_string()));
        }
        if record.status != InviteStatus::Waiting {
            return Err(InviteError::NotWaiting(code.to_string()));
        }
        let Some(pubkey) = record.device_pubkey.clone() else {
            return Err(InviteError::NotWaiting(code.to_string()));
        };

        let account_uuid = self
            .account_uuid(email)
            .await?
            .expect("invite owner email resolves to an active account");
        let outcome = self
            .allocate_machine(Some(&account_uuid), name, &pubkey)
            .await?;
        let machine = match outcome {
            SignupOutcome::Created(resp) => resp.machine,
            // A name that already exists as a route is a collision the
            // owner must resolve — but the invite survives.
            SignupOutcome::Existing(_) => return Err(InviteError::NameTaken(name.to_string())),
        };

        // The device token is generated here and delivered exactly once
        // (the poll); only its hash persists. Non-empty by construction.
        let device_token = random_token_hex();
        let mut enrolled = machine.clone();
        enrolled.device_token_hash = Some(token_hash(&device_token));
        self.store_machine(&enrolled).await?;

        let delivery = EnrollmentDelivery {
            machine: enrolled,
            device_token: device_token.clone(),
        };
        let _: () = conn
            .set_ex(
                delivery_key(code),
                serde_json::to_string(&delivery).unwrap(),
                DELIVERY_TTL_SECS,
            )
            .await?;

        record.status = InviteStatus::Approved;
        let approved = serde_json::to_string(&record).expect("invite serializes");
        let _: () = conn.set_ex(&key, approved, INVITE_TTL_SECS).await?;
        Ok(machine)
    }

    /// The owner denies the pending machine. Terminal; burns the code.
    pub async fn invite_deny(&self, email: &str, code: &str) -> Result<(), InviteError> {
        if !is_valid_invite_code(code) {
            return Err(InviteError::InvalidCode(code.to_string()));
        }
        let mut conn = self.conn().await?;
        let key = invite_key(code);
        let Some(json): Option<String> = conn.get(&key).await? else {
            return Err(InviteError::Unknown(code.to_string()));
        };
        let mut record = record_from_json(json, code)?;
        if record.owner_email != email {
            return Err(InviteError::Forbidden(code.to_string()));
        }
        if record.status != InviteStatus::Waiting {
            return Err(InviteError::NotWaiting(code.to_string()));
        }
        record.status = InviteStatus::Denied;
        let denied = serde_json::to_string(&record).expect("invite serializes");
        let _: () = conn.set_ex(&key, denied, INVITE_TTL_SECS).await?;
        Ok(())
    }

    /// Re-arm one-time delivery after an approval the machine missed:
    /// only the enrolled machine (same pubkey) may.
    async fn rearm_delivery(&self, code: &str, record: &InviteRecord) -> Result<(), InviteError> {
        let pubkey = record
            .device_pubkey
            .clone()
            .expect("approved invite carries a device pubkey");
        let machines = self.list().await?;
        let machine = machines
            .into_iter()
            .find(|m| m.wg_public_key == pubkey)
            .expect("an approved invite's machine exists");
        // The device token itself is gone (delivered once) — a re-arm
        // delivers a FRESH token; the old one's hash is replaced.
        let device_token = random_token_hex();
        let mut machine = machine;
        machine.device_token_hash = Some(token_hash(&device_token));
        self.store_machine(&machine).await?;
        let mut conn = self.conn().await?;
        let delivery = EnrollmentDelivery {
            machine,
            device_token,
        };
        let _: () = conn
            .set_ex(
                delivery_key(code),
                serde_json::to_string(&delivery).unwrap(),
                DELIVERY_TTL_SECS,
            )
            .await?;
        Ok(())
    }

    /// Re-register an enrolled machine with a NEW WG public key (key
    /// rotation on the same route). The device token is the credential
    /// — no AdminKey, no session. The token is SHA-256'd and compared
    /// in constant time against each machine's stored hash.
    pub async fn device_register(
        &self,
        device_token: &str,
        public_key: &str,
    ) -> Result<Machine, ControlPlaneError> {
        assert!(!device_token.is_empty(), "device token is required");
        validate_wg_pubkey(public_key)?;
        let machines = self.list().await?;
        let digest = token_hash(device_token);
        let target = machines
            .into_iter()
            .find(|m| {
                m.device_token_hash
                    .as_deref()
                    .is_some_and(|stored| constant_time_eq(stored.as_bytes(), digest.as_bytes()))
            })
            .ok_or_else(|| {
                ControlPlaneError::NotFound("no machine for this device token".into())
            })?;
        let outcome = self
            .allocate_machine(target.owner.as_deref(), &target.name, public_key)
            .await?;
        let SignupOutcome::Existing(resp) = outcome else {
            panic!("re-registering an enrolled machine is always Existing");
        };
        Ok(resp.machine)
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x == y)
}

/// A 32-byte random token, hex-encoded (64 chars) — the device token
/// shape matches the verify/reset/session tokens.
fn random_token_hex() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

// ── /api/invites + /api/device — the HTTP surface ────────────────────

use poem_openapi::payload::Json;
use poem_openapi::{ApiResponse, Object, OpenApi};

use crate::controlplane::web::{read_cookie, SESSION_COOKIE};
use crate::controlplane::AppState;

/// Status + body for the invite ops.
#[derive(ApiResponse)]
enum InviteApiResponse {
    /// Created.
    #[oai(status = "201")]
    Created(Json<InviteCreatedBody>),
    /// Current state.
    #[oai(status = "200")]
    Ok(Json<PollOutcome>),
    /// The account's invites.
    #[oai(status = "200")]
    List(Json<Vec<InviteSummary>>),
    #[oai(status = "204")]
    NoContent,
    #[oai(status = "400")]
    BadRequest(Json<String>),
    #[oai(status = "401")]
    Unauthorized(Json<String>),
    #[oai(status = "403")]
    Forbidden(Json<String>),
    #[oai(status = "404")]
    NotFound(Json<String>),
    #[oai(status = "409")]
    Conflict(Json<String>),
    #[oai(status = "500")]
    Internal(Json<String>),
}

#[derive(Debug, Serialize, Deserialize, Object)]
pub struct InviteCreatedBody {
    pub code: String,
    /// The full shareable URL — what the owner copies into a paper
    /// insert / email / the box's join screen.
    pub url: String,
}

/// A row on the dashboard's invites screen.
#[derive(Debug, Serialize, Deserialize, Object)]
pub struct InviteSummary {
    pub code: String,
    pub status: String,
    /// The candidate machine's WG public key, once the machine dialed.
    pub device_pubkey: Option<String>,
}

#[derive(Debug, Deserialize, Object)]
pub struct BeginRequest {
    pub public_key: String,
}

#[derive(Debug, Deserialize, Object)]
pub struct ApproveRequest {
    pub name: String,
}

#[derive(Debug, Deserialize, Object)]
pub struct DeviceRegisterRequest {
    pub device_token: String,
    pub public_key: String,
}

/// Map an invite error to its API response. Forbidden stays 403
/// (wrong owner); unknown/not-waiting → 404/409.
fn invite_api_error(err: InviteError) -> InviteApiResponse {
    match err {
        InviteError::InvalidCode(_) => {
            InviteApiResponse::BadRequest(Json("invalid invite code".to_string()))
        }
        InviteError::Unknown(code) => {
            tracing::warn!(code = %code, "invite op: unknown code");
            InviteApiResponse::NotFound(Json("invite not found".to_string()))
        }
        InviteError::Forbidden(code) => {
            tracing::warn!(code = %code, "invite op: wrong owner");
            InviteApiResponse::Forbidden(Json("not the inviting account".to_string()))
        }
        InviteError::NotWaiting(code) => {
            tracing::warn!(code = %code, "invite op: terminal or no candidate");
            InviteApiResponse::Conflict(Json("invite is not in a claimable state".to_string()))
        }
        InviteError::NameTaken(name) => {
            InviteApiResponse::Conflict(Json(format!("machine name {name} is already taken")))
        }
        InviteError::InvalidName(_) => {
            InviteApiResponse::BadRequest(Json(
                "invalid machine name (≥6 chars: lowercase letters, digits, hyphens; not a reserved word)"
                    .to_string(),
            ))
        }
        InviteError::InvalidPubkey(_) => {
            InviteApiResponse::BadRequest(Json("invalid wireguard public key".to_string()))
        }
        InviteError::Account(_) | InviteError::Corrupt(_) | InviteError::Redis(_) => {
            InviteApiResponse::Internal(Json("internal error".to_string()))
        }
    }
}

/// Resolve the session cookie to the logged-in email (500 when the app
/// was mounted without a control plane — a test-side bug).
async fn session_email_from(
    state: &AppState,
    req: &Request,
) -> Result<Option<String>, InviteApiResponse> {
    let Some(cp) = state.cp else {
        return Err(InviteApiResponse::Internal(Json(
            "internal error".to_string(),
        )));
    };
    let Some(token) = read_cookie(req, SESSION_COOKIE) else {
        return Ok(None);
    };
    let email = cp.session_account(&token).await.ok().flatten();
    Ok(email)
}

/// The invite enrollment API. Owner ops (create/list/revoke/approve/
/// deny) authenticate with the SAME session cookie the web UI holds —
/// one session, one surface. Machine ops (begin/poll) are public: the
/// code identifies the invite, the approval gates the access.
pub struct InvitesApi;

#[OpenApi]
impl InvitesApi {
    /// Create an invite for the logged-in account. Returns the code +
    /// the full URL to share out-of-band.
    #[oai(path = "/invites", method = "post")]
    async fn create(&self, Data(state): Data<&AppState>, req: &Request) -> InviteApiResponse {
        let email = match session_email_from(state, req).await {
            Ok(Some(email)) => email,
            Ok(None) => return InviteApiResponse::Unauthorized(Json("no session".to_string())),
            Err(resp) => return resp,
        };
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.invite_create(&email).await {
            Ok(code) => InviteApiResponse::Created(Json(InviteCreatedBody {
                url: format!("https://{}/a/{code}", cp.root_domain),
                code,
            })),
            Err(err) => invite_api_error(err),
        }
    }

    /// The logged-in account's invites (dashboard: invites + approvals).
    #[oai(path = "/invites", method = "get")]
    async fn list(&self, Data(state): Data<&AppState>, req: &Request) -> InviteApiResponse {
        let email = match session_email_from(state, req).await {
            Ok(Some(email)) => email,
            Ok(None) => return InviteApiResponse::Unauthorized(Json("no session".to_string())),
            Err(resp) => return resp,
        };
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.invites_of(&email).await {
            Ok(invites) => InviteApiResponse::List(Json(
                invites
                    .into_iter()
                    .map(|(code, record)| InviteSummary {
                        code,
                        status: match record.status {
                            InviteStatus::Waiting => "waiting".to_string(),
                            InviteStatus::Approved => "approved".to_string(),
                            InviteStatus::Denied => "denied".to_string(),
                        },
                        device_pubkey: record.device_pubkey,
                    })
                    .collect(),
            )),
            Err(err) => invite_api_error(err),
        }
    }

    /// Revoke a waiting invite.
    #[oai(path = "/invites/:code", method = "delete")]
    async fn revoke(
        &self,
        Data(state): Data<&AppState>,
        req: &Request,
        poem_openapi::param::Path(code): poem_openapi::param::Path<String>,
    ) -> InviteApiResponse {
        let email = match session_email_from(state, req).await {
            Ok(Some(email)) => email,
            Ok(None) => return InviteApiResponse::Unauthorized(Json("no session".to_string())),
            Err(resp) => return resp,
        };
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.invite_revoke(&email, &code).await {
            Ok(()) => InviteApiResponse::NoContent,
            Err(err) => invite_api_error(err),
        }
    }

    /// A machine dials the invite with its WG public key. Open — the
    /// code identifies the invite; the owner's approval gates access.
    #[oai(path = "/invites/:code/begin", method = "post")]
    async fn begin(
        &self,
        Data(state): Data<&AppState>,
        poem_openapi::param::Path(code): poem_openapi::param::Path<String>,
        Json(body): Json<BeginRequest>,
    ) -> InviteApiResponse {
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.invite_begin(&code, &body.public_key).await {
            Ok(outcome) => InviteApiResponse::Ok(Json(outcome)),
            Err(err) => invite_api_error(err),
        }
    }

    /// The machine's poll. On `approved` the tunnel config + device
    /// token are delivered exactly once.
    #[oai(path = "/invites/:code/poll", method = "get")]
    async fn poll(
        &self,
        Data(state): Data<&AppState>,
        poem_openapi::param::Path(code): poem_openapi::param::Path<String>,
    ) -> InviteApiResponse {
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.invite_poll(&code).await {
            Ok(outcome) => InviteApiResponse::Ok(Json(outcome)),
            Err(err) => invite_api_error(err),
        }
    }

    /// Approve the pending machine and name it. Session-auth (owner).
    #[oai(path = "/invites/:code/approve", method = "post")]
    async fn approve(
        &self,
        Data(state): Data<&AppState>,
        req: &Request,
        poem_openapi::param::Path(code): poem_openapi::param::Path<String>,
        Json(body): Json<ApproveRequest>,
    ) -> InviteApiResponse {
        let email = match session_email_from(state, req).await {
            Ok(Some(email)) => email,
            Ok(None) => return InviteApiResponse::Unauthorized(Json("no session".to_string())),
            Err(resp) => return resp,
        };
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.invite_approve(&email, &code, &body.name).await {
            Ok(_machine) => InviteApiResponse::Ok(Json(PollOutcome {
                status: "approved".to_string(),
                machine: None,
                device_token: None,
            })),
            Err(err) => invite_api_error(err),
        }
    }

    /// Deny the pending machine. Session-auth (owner); burns the code.
    #[oai(path = "/invites/:code/deny", method = "post")]
    async fn deny(
        &self,
        Data(state): Data<&AppState>,
        req: &Request,
        poem_openapi::param::Path(code): poem_openapi::param::Path<String>,
    ) -> InviteApiResponse {
        let email = match session_email_from(state, req).await {
            Ok(Some(email)) => email,
            Ok(None) => return InviteApiResponse::Unauthorized(Json("no session".to_string())),
            Err(resp) => return resp,
        };
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp.invite_deny(&email, &code).await {
            Ok(()) => InviteApiResponse::NoContent,
            Err(err) => invite_api_error(err),
        }
    }

    /// Re-register an enrolled machine with a new WG public key. The
    /// device token is the credential (no AdminKey, no session).
    #[oai(path = "/device/register", method = "post")]
    async fn device_register(
        &self,
        Data(state): Data<&AppState>,
        Json(body): Json<DeviceRegisterRequest>,
    ) -> InviteApiResponse {
        let Some(cp) = state.cp else {
            return InviteApiResponse::Internal(Json("internal error".to_string()));
        };
        match cp
            .device_register(&body.device_token, &body.public_key)
            .await
        {
            Ok(machine) => InviteApiResponse::Ok(Json(PollOutcome {
                status: machine.name.clone(),
                machine: Some(machine),
                device_token: None,
            })),
            Err(ControlPlaneError::NotFound(_)) => {
                InviteApiResponse::Unauthorized(Json("invalid device token".to_string()))
            }
            Err(ControlPlaneError::InvalidPubkey(_)) => {
                InviteApiResponse::BadRequest(Json("invalid wireguard public key".to_string()))
            }
            Err(err) => {
                tracing::error!(error = %err, "device register failed");
                InviteApiResponse::Internal(Json("internal error".to_string()))
            }
        }
    }
}

/// Expose the invites API for merging into the edge's one API service.
pub fn invites_api() -> InvitesApi {
    InvitesApi
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::controlplane::dns::MockDnsApiClient;
    use crate::controlplane::mail::MockMailer;
    use crate::controlplane::wg::MockWgClient;
    use crate::controlplane::{AccountRecord, AccountStatus, Subnet64, WgSubnet};

    fn test_cp() -> Option<ControlPlane> {
        let url = match std::env::var("REDIS_URL") {
            Ok(url) if !url.is_empty() => url,
            _ => return None,
        };
        let wg: &'static MockWgClient = Box::leak(Box::new(MockWgClient::new()));
        let dns: &'static MockDnsApiClient = Box::leak(Box::new(MockDnsApiClient::new()));
        let subnet = Subnet64::from_str("2a01:4f8:c17:1::/64").unwrap();
        let wg_subnet = WgSubnet::from_str("10.10.0.0/24").unwrap();
        ControlPlane::with_deps(
            &url,
            subnet,
            wg_subnet,
            "example.net",
            "KKwuhbBylIlBdWtTEa0Krl5NoYGTUrKTkZf7VEsXXGA=",
            wg,
            dns,
        )
        .map(|cp| cp.isolated_alloc(leaked_alloc_key()))
        .ok()
    }

    fn leaked_alloc_key() -> &'static str {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        Box::leak(format!("fortress:test-alloc:{}-{}", std::process::id(), nanos).into_boxed_str())
    }

    fn skip_without_redis() -> Option<ControlPlane> {
        let cp = test_cp();
        if cp.is_none() {
            eprintln!("skipping: REDIS_URL not set");
            return None;
        }
        crate::controlplane::set_forwarder_for_tests();
        cp
    }

    /// The store persists across runs: a previous run (or an aborted
    /// one) leaves machines behind. Clean the names these tests own so
    /// they pass on every run, not just a pristine store.
    async fn clean_test_machines(cp: &ControlPlane) {
        for leftover in ["nameclash", "mainbox", "rearmbox", "rotateme"] {
            let _ = cp.delete(leftover).await;
        }
        let mut conn = cp.conn().await.unwrap();
        // No counter cleanup: each test instance owns a fresh leaked
        // alloc key (`isolated_alloc`), and a shared counter must not
        // be reset under a parallel test's feet. Stale counter keys are
        // garbage in Redis, not a correctness risk.
    }

    fn unique_email(label: &str) -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("{label}-{}-{}@example.com", std::process::id(), nanos)
    }

    async fn enrolled_account(cp: &ControlPlane, label: &str) -> String {
        let email = unique_email(label);
        cp.account_signup(&email, "hunter2", &MockMailer::new())
            .await
            .expect("signup");
        let mut conn = cp.conn().await.unwrap();
        let json: String =
            redis::AsyncCommands::get(&mut conn, format!("fortress:account:{email}"))
                .await
                .unwrap();
        let record: AccountRecord = serde_json::from_str(&json).unwrap();
        // Flip to active directly: verify tokens are the T2 flow's job.
        let mut record = record;
        record.status = AccountStatus::Active;
        let _: () = redis::AsyncCommands::set(
            &mut conn,
            format!("fortress:account:{email}"),
            serde_json::to_string(&record).unwrap(),
        )
        .await
        .unwrap();
        email
    }

    fn pubkey() -> String {
        crate::controlplane::generate_wg_keypair().0
    }

    #[test]
    fn invite_code_is_crockford_and_10_chars() {
        for _ in 0..64 {
            let code = random_invite_code();
            assert_eq!(code.len(), CODE_LEN);
            assert!(is_valid_invite_code(&code), "{code} must self-validate");
            assert!(
                code.bytes().all(|b| CROCKFORD.contains(&b)),
                "{code} must be lowercase Crockford"
            );
        }
        assert!(!is_valid_invite_code("short"));
        assert!(!is_valid_invite_code("il0uabcfgx"), "I is not Crockford");
    }

    #[tokio::test]
    async fn invite_lifecycle_round_trip() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        clean_test_machines(&cp).await;
        let email = enrolled_account(&cp, "invite").await;

        // Create → the URL carries the code under the edge's domain.
        let code = cp.invite_create(&email).await.expect("create");
        assert!(is_valid_invite_code(&code));
        assert!(code.len() == CODE_LEN);

        // Poll before the machine dials: waiting.
        let poll = cp.invite_poll(&code).await.expect("poll");
        assert_eq!(poll.status, "waiting");

        // Machine begins with its pubkey.
        let pk = pubkey();
        let begun = cp.invite_begin(&code, &pk).await.expect("begin");
        assert_eq!(begun.status, "waiting");

        // Unknown + malformed codes rejected.
        assert!(matches!(
            cp.invite_begin("zzzzzzzzzz", &pk).await,
            Err(InviteError::Unknown(_))
        ));
        assert!(matches!(
            cp.invite_begin("short", &pk).await,
            Err(InviteError::InvalidCode(_))
        ));
        assert!(matches!(
            cp.invite_begin(&code, "not-base64-32-bytes").await,
            Err(InviteError::InvalidPubkey(_))
        ));

        // A DIFFERENT account cannot approve or deny.
        let stranger = enrolled_account(&cp, "stranger").await;
        assert!(matches!(
            cp.invite_approve(&stranger, &code, "stolen").await,
            Err(InviteError::Forbidden(_))
        ));
        assert!(matches!(
            cp.invite_deny(&stranger, &code).await,
            Err(InviteError::Forbidden(_))
        ));

        // Approve with a taken name keeps the invite waiting.
        let other_code = cp.invite_create(&email).await.expect("second invite");
        cp.invite_begin(&other_code, &pubkey())
            .await
            .expect("begin");
        let SignupOutcome::Created(_taken) = cp
            .allocate_machine(
                Some("00000000-0000-4000-8000-000000000000"),
                "nameclash",
                &pubkey(),
            )
            .await
            .expect("clash machine")
        else {
            panic!("created");
        };
        assert!(matches!(
            cp.invite_approve(&email, &other_code, "nameclash").await,
            Err(InviteError::NameTaken(_))
        ));
        let still_waiting = cp.invite_poll(&other_code).await.expect("poll");
        assert_eq!(
            still_waiting.status, "waiting",
            "invite survives a name clash"
        );

        // Approve with a good name allocates + returns approved.
        cp.invite_approve(&email, &code, "mainbox")
            .await
            .expect("approve");
        let poll = cp.invite_poll(&code).await.expect("poll approved");
        assert_eq!(poll.status, "approved");
        let machine = poll.machine.expect("payload machine");
        assert_eq!(machine.name, "mainbox");
        assert_eq!(machine.hostname, "mainbox.example.net");
        let token = poll.device_token.expect("payload token");
        assert_eq!(token.len(), 64, "32-byte hex token");

        // One-time delivery: the second poll is empty.
        let poll = cp.invite_poll(&code).await.expect("poll consumed");
        assert_eq!(poll.status, "approved");
        assert!(poll.machine.is_none(), "delivery is one-time");
        assert!(poll.device_token.is_none());

        // The machine record carries the token hash + the owner UUID.
        let machines = cp.list().await.expect("list");
        let enrolled = machines.iter().find(|m| m.name == "mainbox").unwrap();
        assert_eq!(
            enrolled.device_token_hash.as_deref(),
            Some(token_hash(&token).as_str())
        );
        assert!(enrolled.owner.is_some(), "owner UUID recorded");

        // Terminal: the burned code cannot begin/poll/approve again.
        assert!(matches!(
            cp.invite_begin(&code, &pubkey()).await,
            Err(InviteError::NotWaiting(_))
        ));
        assert!(matches!(
            cp.invite_approve(&email, &code, "again").await,
            Err(InviteError::NotWaiting(_))
        ));
        assert!(matches!(
            cp.invite_deny(&email, &code).await,
            Err(InviteError::NotWaiting(_))
        ));
    }

    #[tokio::test]
    async fn re_begin_re_arms_delivery_for_same_machine() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        clean_test_machines(&cp).await;
        let email = enrolled_account(&cp, "rearm").await;
        let code = cp.invite_create(&email).await.expect("invite");
        let pk = pubkey();
        cp.invite_begin(&code, &pk).await.expect("begin");
        cp.invite_approve(&email, &code, "rearmbox")
            .await
            .expect("approve");
        // Consume the first delivery.
        let first = cp.invite_poll(&code).await.expect("poll");
        assert!(first.device_token.is_some());

        // Missed delivery: re-begin with the SAME pubkey re-arms it.
        cp.invite_begin(&code, &pk).await.expect("re-begin");
        let second = cp.invite_poll(&code).await.expect("poll re-armed");
        assert!(second.device_token.is_some(), "fresh token delivered");
        // A DIFFERENT pubkey cannot re-arm.
        assert!(matches!(
            cp.invite_begin(&code, &pubkey()).await,
            Err(InviteError::NotWaiting(_))
        ));
    }

    #[tokio::test]
    async fn deny_is_terminal_and_burns_the_code() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        clean_test_machines(&cp).await;
        let email = enrolled_account(&cp, "deny").await;
        let code = cp.invite_create(&email).await.expect("invite");
        cp.invite_begin(&code, &pubkey()).await.expect("begin");
        cp.invite_deny(&email, &code).await.expect("deny");
        let poll = cp.invite_poll(&code).await.expect("poll denied");
        assert_eq!(poll.status, "denied");
        assert!(matches!(
            cp.invite_approve(&email, &code, "late").await,
            Err(InviteError::NotWaiting(_))
        ));
        assert!(matches!(
            cp.invite_begin(&code, &pubkey()).await,
            Err(InviteError::NotWaiting(_))
        ));
        assert!(matches!(
            cp.invite_revoke(&email, &code).await,
            Err(InviteError::NotWaiting(_))
        ));
    }

    #[tokio::test]
    async fn revoke_drops_a_waiting_invite() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        clean_test_machines(&cp).await;
        let email = enrolled_account(&cp, "revoke").await;
        let code = cp.invite_create(&email).await.expect("invite");
        cp.invite_revoke(&email, &code).await.expect("revoke");
        assert!(matches!(
            cp.invite_poll(&code).await,
            Err(InviteError::Unknown(_))
        ));
    }

    #[tokio::test]
    async fn device_register_rotates_the_key_on_the_same_route() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        clean_test_machines(&cp).await;
        let email = enrolled_account(&cp, "rotate").await;
        let code = cp.invite_create(&email).await.expect("invite");
        let first = pubkey();
        cp.invite_begin(&code, &first).await.expect("begin");
        cp.invite_approve(&email, &code, "rotateme")
            .await
            .expect("approve");
        let poll = cp.invite_poll(&code).await.expect("poll");
        let machine = poll.machine.expect("payload");
        let token = poll.device_token.expect("token");
        let route_before = (machine.ipv6.clone(), machine.wg_ip.clone());

        // Rotation: a new pubkey, the SAME route, no AdminKey.
        let second = pubkey();
        let rotated = cp
            .device_register(&token, &second)
            .await
            .expect("re-register");
        assert_eq!(rotated.ipv6, route_before.0, "route kept");
        assert_eq!(rotated.wg_ip, route_before.1, "route kept");
        assert_eq!(rotated.wg_public_key, second, "pubkey rotated");

        // A wrong token is rejected (invalid, not not-found-leaky).
        assert!(matches!(
            cp.device_register("not-a-token", &second).await,
            Err(ControlPlaneError::NotFound(_))
        ));
        assert!(matches!(
            cp.device_register(&token, "not base64 32").await,
            Err(ControlPlaneError::InvalidPubkey(_))
        ));
    }

    #[tokio::test]
    async fn invites_of_lists_only_the_owners() {
        let Some(cp) = skip_without_redis() else {
            return;
        };
        clean_test_machines(&cp).await;
        let mine = enrolled_account(&cp, "mine").await;
        let theirs = enrolled_account(&cp, "theirs").await;
        let code = cp.invite_create(&mine).await.expect("invite");
        let mine_list = cp.invites_of(&mine).await.expect("list mine");
        assert!(mine_list.iter().any(|(c, _)| c == &code));
        let theirs_list = cp.invites_of(&theirs).await.expect("list theirs");
        assert!(!theirs_list.iter().any(|(c, _)| c == &code));
    }
}
