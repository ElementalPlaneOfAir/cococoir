use cococoir::dashboard::dashboard_entry;

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    dashboard_entry().await
}
