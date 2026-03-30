use serde::Deserialize;

const fn default_limit() -> i64 {
    50
}

const MAX_LIMIT: i64 = 500;

#[derive(Deserialize)]
#[serde(from = "RawPagination")]
pub struct Pagination {
    pub limit: i64,
    pub offset: i64,
}

#[derive(Deserialize)]
struct RawPagination {
    #[serde(default = "default_limit")]
    limit: i64,
    #[serde(default)]
    offset: i64,
}

impl From<RawPagination> for Pagination {
    fn from(raw: RawPagination) -> Self {
        Self {
            limit: raw.limit.clamp(0, MAX_LIMIT),
            offset: raw.offset.max(0),
        }
    }
}
