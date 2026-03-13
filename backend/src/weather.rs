use serde::Deserialize;

#[derive(Debug, Clone)]
pub struct WeatherData {
    pub temp_c: f64,
    pub wind_kph: f64,
    pub precip_mm: f64,
    pub code: i64,
}

#[derive(Deserialize)]
struct OpenMeteoResponse {
    hourly: HourlyData,
}

#[derive(Deserialize)]
struct HourlyData {
    time: Vec<String>,
    temperature_2m: Vec<Option<f64>>,
    windspeed_10m: Vec<Option<f64>>,
    precipitation: Vec<Option<f64>>,
    weathercode: Vec<Option<i64>>,
}

/// Fetches historical weather for `(lat, lon)` at the given Unix timestamp.
/// Returns `None` on any error (network, API, no data) so import continues normally.
pub async fn fetch_weather(
    client: &reqwest::Client,
    lat: f64,
    lon: f64,
    unix_ts: i64,
) -> Option<WeatherData> {
    use chrono::{DateTime, Utc};
    let dt = DateTime::<Utc>::from_timestamp(unix_ts, 0)?;
    let date = dt.format("%Y-%m-%d").to_string();
    let target_hour = dt.format("%Y-%m-%dT%H:00").to_string();

    let url = format!(
        "https://archive-api.open-meteo.com/v1/archive\
         ?latitude={lat:.4}&longitude={lon:.4}\
         &start_date={date}&end_date={date}\
         &hourly=temperature_2m,windspeed_10m,precipitation,weathercode\
         &timezone=UTC&wind_speed_unit=kmh"
    );

    let resp = client
        .get(&url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .ok()?;

    let body: OpenMeteoResponse = resp.json().await.ok()?;
    let h = &body.hourly;

    // Find the index of the hour closest to the run start
    let idx = h.time.iter().position(|t| t == &target_hour)?;

    Some(WeatherData {
        temp_c: h.temperature_2m[idx]?,
        wind_kph: h.windspeed_10m[idx]?,
        precip_mm: h.precipitation[idx]?,
        code: h.weathercode[idx]?,
    })
}

/// Maps WMO weather interpretation code to a short description.
#[must_use]
pub const fn wmo_description(code: i64) -> &'static str {
    match code {
        0 => "Clear sky",
        1 => "Mainly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 | 48 => "Fog",
        51 | 53 | 55 => "Drizzle",
        56 | 57 => "Freezing drizzle",
        61 | 63 | 65 => "Rain",
        66 | 67 => "Freezing rain",
        71 | 73 | 75 => "Snow",
        77 => "Snow grains",
        80..=82 => "Rain showers",
        85..=86 => "Snow showers",
        95 => "Thunderstorm",
        96 | 99 => "Thunderstorm w/ hail",
        _ => "Unknown",
    }
}
