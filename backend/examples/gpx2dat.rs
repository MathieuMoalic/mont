//! Dev tool: encode a GPX file into the watch's binary route format.
//!
//! Usage: cargo run --example gpx2dat -- <input.gpx> <output.dat> <unix-ts> <name>
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let (Some(gpx_path), Some(dat_path)) = (args.get(1), args.get(2)) else {
        eprintln!("usage: gpx2dat <input.gpx> <output.dat> <unix-ts> <name>");
        return ExitCode::FAILURE;
    };
    let ts: i64 = args
        .get(3)
        .and_then(|t| t.parse().ok())
        .unwrap_or_else(|| chrono::Utc::now().timestamp());
    let name = args.get(4).cloned().unwrap_or_else(|| "route".into());
    let Ok(gpx) = std::fs::read(gpx_path) else {
        eprintln!("cannot read {gpx_path}");
        return ExitCode::FAILURE;
    };
    let Ok(route) = mont::ble::gpx_route::parse_gpx_route(&gpx) else {
        eprintln!("cannot parse GPX");
        return ExitCode::FAILURE;
    };
    let dat = mont::ble::gpx_route::encode_route_dat(&route, ts, &name);
    if std::fs::write(dat_path, &dat).is_err() {
        eprintln!("cannot write {dat_path}");
        return ExitCode::FAILURE;
    }
    println!("{} -> {} ({} bytes)", gpx_path, dat_path, dat.len());
    ExitCode::SUCCESS
}
