use std::{env, path::PathBuf, str::FromStr, sync::Arc, time::Duration};

use chrono::{DateTime, Utc};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};
use sqlx::FromRow;
use thiserror::Error;
use uuid::Uuid;

/// Sessions expire 24h after creation.
const SESSION_TTL: Duration = Duration::from_secs(24 * 60 * 60);
/// Prefix isolating template kv keys from future bookkeeping keys.
const KV_PREFIX: &str = "misc:";

#[derive(Debug, Error)]
pub enum DbError {
    #[error("database error: {0}")]
    Sqlx(#[from] sqlx::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("session token not found: {0}")]
    SessionNotFound(String),
    #[error("session token expired: {0}")]
    SessionExpired(String),
    #[error("corrupt row in {table}: {detail}")]
    Corrupt { table: &'static str, detail: String },
}

#[derive(Debug)]
pub struct Session {
    pub token: String,
    pub user_id: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct SessionRow {
    token: String,
    user_id: String,
    created_at: String,
    expires_at: String,
}

#[derive(Debug, FromRow)]
struct KvRow {
    value: String,
}

/// Shared handle to the dashboard database. sqlx pools connections
/// internally, so every async handler can query concurrently.
pub struct Db {
    pool: SqlitePool,
}

impl Db {
    /// Open the local database file and ensure the schema exists.
    /// File lives at `$XDG_DATA_HOME/cococoir/dashboard.db`
    /// (fallback: `$HOME/.local/share/cococoir/dashboard.db`).
    pub async fn open() -> Result<Arc<Self>, DbError> {
        let path = local_db_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let options = SqliteConnectOptions::from_str(&path.to_string_lossy())
            .expect("db path parses as sqlite url")
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new().connect_with(options).await?;
        let db = Db { pool };
        db.migrate().await?;
        Ok(Arc::new(db))
    }

    /// In-memory database for tests. A single connection so all
    /// queries hit the same in-memory database.
    #[cfg(test)]
    pub async fn open_in_memory() -> Result<Arc<Self>, DbError> {
        let options = SqliteConnectOptions::from_str("sqlite::memory:")
            .expect("memory url parses")
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        let db = Db { pool };
        db.migrate().await?;
        Ok(Arc::new(db))
    }

    /// Create a session for `user_id`, returning its opaque token.
    pub async fn create_session(&self, user_id: &str) -> Result<String, DbError> {
        assert!(!user_id.is_empty(), "user_id must be non-empty");
        let token = Uuid::new_v4().to_string();
        let now = Utc::now();
        let ttl = chrono::Duration::from_std(SESSION_TTL).expect("SESSION_TTL is a valid duration");
        let expires_at = now + ttl;
        let inserted = sqlx::query(
            "INSERT INTO sessions (token, user_id, created_at, expires_at)
             VALUES (?, ?, ?, ?)",
        )
        .bind(&token)
        .bind(user_id)
        .bind(now.to_rfc3339())
        .bind(expires_at.to_rfc3339())
        .execute(&self.pool)
        .await?;
        assert_eq!(
            inserted.rows_affected(),
            1,
            "session insert must affect exactly one row"
        );
        Ok(token)
    }

    /// Read a session; errors if missing or expired.
    pub async fn get_session(&self, token: &str) -> Result<Session, DbError> {
        assert!(!token.is_empty(), "session token must be non-empty");
        let raw = sqlx::query_as::<_, SessionRow>(
            "SELECT token, user_id, created_at, expires_at FROM sessions WHERE token = ?",
        )
        .bind(token)
        .fetch_optional(&self.pool)
        .await?;
        let Some(raw) = raw else {
            return Err(DbError::SessionNotFound(token.to_string()));
        };
        let session = Session {
            token: raw.token,
            user_id: raw.user_id,
            created_at: parse_timestamp(&raw.created_at, "sessions")?,
            expires_at: parse_timestamp(&raw.expires_at, "sessions")?,
        };
        if session.expires_at <= Utc::now() {
            return Err(DbError::SessionExpired(token.to_string()));
        }
        Ok(session)
    }

    /// Delete a session; returns whether a row was actually deleted.
    pub async fn delete_session(&self, token: &str) -> Result<bool, DbError> {
        assert!(!token.is_empty(), "session token must be non-empty");
        let deleted = sqlx::query("DELETE FROM sessions WHERE token = ?")
            .bind(token)
            .execute(&self.pool)
            .await?;
        assert!(
            deleted.rows_affected() <= 1,
            "token is primary key; at most one row matches"
        );
        Ok(deleted.rows_affected() > 0)
    }

    /// Read a template-scoped kv value; `None` when the key is absent.
    pub async fn kv_get(&self, key: &str) -> Result<Option<String>, DbError> {
        assert!(!key.is_empty(), "kv key must be non-empty");
        let row = sqlx::query_as::<_, KvRow>("SELECT value FROM kv WHERE key = ?")
            .bind(format!("{KV_PREFIX}{key}"))
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|row| row.value))
    }

    /// Upsert a template-scoped kv value.
    pub async fn kv_set(&self, key: &str, value: &str) -> Result<(), DbError> {
        assert!(!key.is_empty(), "kv key must be non-empty");
        sqlx::query(
            "INSERT INTO kv (key, value, updated_at) VALUES (?, ?, ?)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        )
        .bind(format!("{KV_PREFIX}{key}"))
        .bind(value)
        .bind(Utc::now().to_rfc3339())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn migrate(&self) -> Result<(), DbError> {
        sqlx::query(
            "CREATE TABLE IF NOT EXISTS sessions (
                token      TEXT PRIMARY KEY,
                user_id    TEXT NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL
            )",
        )
        .execute(&self.pool)
        .await?;
        sqlx::query(
            "CREATE TABLE IF NOT EXISTS kv (
                key        TEXT PRIMARY KEY,
                value      TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )",
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

fn local_db_path() -> PathBuf {
    let data_home = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("HOME").map(|home| PathBuf::from(home).join(".local").join("share"))
        })
        .unwrap_or_else(|| PathBuf::from("."));
    data_home.join("cococoir").join("dashboard.db")
}

fn parse_timestamp(raw: &str, table: &'static str) -> Result<DateTime<Utc>, DbError> {
    DateTime::parse_from_rfc3339(raw)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|error| DbError::Corrupt {
            table,
            detail: format!("{raw}: {error}"),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn session_round_trip() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let token = db.create_session("alice").await.expect("create");
        let session = db.get_session(&token).await.expect("read back");
        assert_eq!(session.user_id, "alice");
        assert!(session.created_at <= session.expires_at);
        assert!(session.expires_at > Utc::now());
    }

    #[tokio::test]
    async fn missing_session_is_not_found() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let err = db.get_session("00000000-0000-0000-0000-000000000000").await;
        assert!(matches!(err, Err(DbError::SessionNotFound(_))));
    }

    #[tokio::test]
    async fn expired_session_is_rejected() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let token = db.create_session("bob").await.expect("create");
        let stale = Utc::now() - chrono::Duration::seconds(1);
        sqlx::query("UPDATE sessions SET expires_at = ? WHERE token = ?")
            .bind(stale.to_rfc3339())
            .bind(&token)
            .execute(&db.pool)
            .await
            .expect("backdate expiry");
        assert!(matches!(
            db.get_session(&token).await,
            Err(DbError::SessionExpired(_))
        ));
    }

    #[tokio::test]
    async fn delete_is_idempotent() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let token = db.create_session("carol").await.expect("create");
        assert!(db.delete_session(&token).await.expect("first delete"));
        assert!(!db.delete_session(&token).await.expect("second delete"));
    }

    #[tokio::test]
    async fn kv_round_trip_upserts() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        assert_eq!(db.kv_get("visits").await.expect("absent"), None);
        db.kv_set("visits", "1").await.expect("first set");
        db.kv_set("visits", "2").await.expect("second set");
        assert_eq!(
            db.kv_get("visits").await.expect("read"),
            Some("2".to_owned())
        );
    }
}
