//! mkgmap style files embedded at compile time (`map_styles/` in the crate
//! root). Styles must live on the real filesystem for mkgmap, so
//! [`extract_style`] materialises one into a job's temp directory.

use std::fs;
use std::path::{Path, PathBuf};

use rust_embed::Embed;

#[derive(Embed)]
#[folder = "map_styles/"]
struct MapStyles;

/// Materialise the named style (`CheetahTopo`) under `dest`, returning the
/// path to `<dest>/<name>`. Returns `None` when no embedded files match.
///
/// # Errors
/// Filesystem writes fail.
pub fn extract_style(name: &str, dest: &Path) -> anyhow::Result<Option<PathBuf>> {
    let prefix = format!("{name}/");
    let files: Vec<_> = MapStyles::iter()
        .filter(|p| p.starts_with(&prefix))
        .collect();
    if files.is_empty() {
        return Ok(None);
    }
    for path in files {
        let Some(embedded) = MapStyles::get(&path) else {
            continue;
        };
        let out = dest.join(path.as_ref());
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&out, embedded.data)?;
    }
    Ok(Some(dest.join(name)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cheetah_topo_style_is_embedded_with_options() {
        let names: Vec<_> = MapStyles::iter().collect();
        assert!(
            names.iter().any(|p| p == "CheetahTopo/options"),
            "CheetahTopo/options missing from embedded styles: {names:?}"
        );
        assert!(
            names.iter().any(|p| p == "CheetahTopo/inc/contour_lines"),
            "CheetahTopo includes missing from embedded styles"
        );
    }

    #[test]
    fn extract_style_materialises_files_and_unknown_style_is_none() {
        let dest = tempfile::tempdir().expect("tempdir");
        let extracted = extract_style("CheetahTopo", dest.path())
            .expect("extract")
            .expect("CheetahTopo should exist");
        assert!(extracted.join("info").is_file());
        assert!(extracted.join("options").is_file());

        let missing = extract_style("Nope", dest.path()).expect("extract");
        assert!(missing.is_none());
    }
}
