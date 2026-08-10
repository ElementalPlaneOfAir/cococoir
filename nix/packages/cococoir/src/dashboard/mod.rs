pub mod components;
mod db;
mod nix_config_parser;

use crate::dashboard::db::{Db, DbError};
use momenta::prelude::*;
use poem::{
    get, handler,
    http::StatusCode,
    listener::TcpListener,
    post,
    web::{Data, Html, Path},
    Endpoint, EndpointExt, IntoResponse, Response, Route, Server,
};
use std::{sync::Arc, time::Duration};
use tokio::time::sleep;

use crate::dashboard::components::{HtmxTest, HtmxTestProps, IndexPage, IndexProps};

const PAGE_LOAD_KEY: &str = "page_loads";

async fn next_page_load(db: &Db) -> usize {
    let current = db
        .kv_get(PAGE_LOAD_KEY)
        .await
        .ok()
        .flatten()
        .and_then(|raw| raw.parse::<usize>().ok())
        .unwrap_or(1);
    let next = current + 1;
    if let Err(error) = db.kv_set(PAGE_LOAD_KEY, &next.to_string()).await {
        tracing::warn!(error = %error, "failed to persist page load counter; page still renders");
    }
    current
}

#[handler]
async fn hello(Data(db): Data<&Arc<Db>>, Path(name): Path<String>) -> impl IntoResponse {
    let times_loaded = next_page_load(db).await;
    let props = IndexProps {
        name,
        count: times_loaded,
    };
    Html(component::<IndexPage>(props).to_html()).with_status(StatusCode::OK)
}

#[handler]
async fn update_count(Data(db): Data<&Arc<Db>>) -> Response {
    let times_loaded = next_page_load(db).await;
    sleep(Duration::from_millis(500)).await;
    let props = HtmxTestProps {
        count: times_loaded,
    };
    Html(component::<HtmxTest>(props).to_html())
        .with_status(StatusCode::OK)
        .into_response()
}

#[handler]
async fn create_session(Data(db): Data<&Arc<Db>>) -> Response {
    match db.create_session("demo-user").await {
        Ok(token) => Html(format!("<p>session created: {token}</p>"))
            .with_header("X-Session-Token", token)
            .with_status(StatusCode::CREATED)
            .into_response(),
        Err(error) => {
            tracing::error!(error = %error, "create session failed");
            Html("<p>session creation failed</p>".to_string())
                .with_status(StatusCode::INTERNAL_SERVER_ERROR)
                .into_response()
        }
    }
}

#[handler]
async fn show_session(Data(db): Data<&Arc<Db>>, Path(token): Path<String>) -> Response {
    match db.get_session(&token).await {
        Ok(session) => Html(format!(
            "<p>session for {user} created {created} valid until {expires}</p>",
            user = session.user_id,
            created = session.created_at.to_rfc3339(),
            expires = session.expires_at.to_rfc3339(),
        ))
        .into_response(),
        Err(DbError::SessionNotFound(_)) => StatusCode::NOT_FOUND.into(),
        Err(DbError::SessionExpired(_)) => StatusCode::GONE.into(),
        Err(error) => {
            tracing::error!(error = %error, token = %token, "get session failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[handler]
async fn end_session(Data(db): Data<&Arc<Db>>, Path(token): Path<String>) -> Response {
    match db.delete_session(&token).await {
        Ok(true) => StatusCode::NO_CONTENT.into(),
        Ok(false) => StatusCode::NOT_FOUND.into(),
        Err(error) => {
            tracing::error!(error = %error, token = %token, "delete session failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

fn app(db: Arc<Db>) -> impl Endpoint {
    Route::new()
        .at("/hello/:name", get(hello))
        .at("/update", post(update_count))
        .at("/session", post(create_session))
        .at("/session/:token", get(show_session).delete(end_session))
        .data(db)
}

pub async fn dashboard_entry() -> Result<(), std::io::Error> {
    let db = Db::open().await.map_err(|error| {
        tracing::error!(error = %error, "dashboard database failed to open");
        std::io::Error::other("dashboard database failed to open")
    })?;
    Server::new(TcpListener::bind("0.0.0.0:3000"))
        .run(app(db))
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use poem::test::TestClient;

    #[tokio::test]
    async fn hello_renders_and_counter_persists() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db));
        let first = client.get("/hello/alice").send().await;
        first.assert_status(StatusCode::OK);
        let first_body = first.0.into_body().into_string().await.expect("utf8 body");
        assert!(first_body.contains("alice"));
        assert!(first_body.contains(" 1 times."));
        let second = client.get("/hello/alice").send().await;
        let second_body = second.0.into_body().into_string().await.expect("utf8 body");
        assert!(second_body.contains(" 2 times."));
    }

    #[tokio::test]
    async fn session_endpoints_round_trip() {
        let db = Db::open_in_memory().await.expect("in-memory db opens");
        let client = TestClient::new(app(db));
        let created = client.post("/session").send().await;
        created.assert_status(StatusCode::CREATED);
        let token = created
            .0
            .headers()
            .get("X-Session-Token")
            .expect("token header present")
            .to_str()
            .expect("token header is utf8")
            .to_owned();
        let shown = client.get(format!("/session/{token}")).send().await;
        shown.assert_status(StatusCode::OK);
        let shown_body = shown.0.into_body().into_string().await.expect("utf8 body");
        assert!(shown_body.contains("demo-user"));
        let ended = client.delete(format!("/session/{token}")).send().await;
        ended.assert_status(StatusCode::NO_CONTENT);
        let gone = client.get(format!("/session/{token}")).send().await;
        gone.assert_status(StatusCode::NOT_FOUND);
    }
}
