use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqliteSynchronous};
use std::path::PathBuf;

pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// # Errors
/// Will return `Err` if the database path is not writable or a connection can't be made.
pub async fn make_pool(database_path: String) -> anyhow::Result<SqlitePool> {
    let db_path = PathBuf::from(&database_path);

    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Run migrations with FK disabled to allow table recreation
    let migration_opts = SqliteConnectOptions::new()
        .filename(&db_path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .foreign_keys(false);

    let migration_pool = SqlitePool::connect_with(migration_opts).await?;
    MIGRATOR.run(&migration_pool).await?;
    migration_pool.close().await;

    // Create the actual pool with FK enabled (sqlx default)
    let opts = SqliteConnectOptions::new()
        .filename(&db_path)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal);

    let pool = SqlitePool::connect_with(opts).await?;
    Ok(pool)
}
