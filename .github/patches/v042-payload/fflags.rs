//! Conservative local Roblox Fast Flag configuration support.
//!
//! Only keys present in Roblox's published local-client allowlist are exposed.
//! Roblox may change that list; settings not currently recognized by the client
//! can be ignored. This module never edits a running process or game memory.

use anyhow::{bail, ensure, Context, Result};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Profile {
    Performance,
    Balanced,
    Quality,
}

#[derive(Clone, Copy, Debug)]
pub struct FlagInfo {
    pub key: &'static str,
    pub group: &'static str,
    pub description: &'static str,
}

/// Initial locally configurable allowlist published by Roblox (29 Sep 2025).
/// The platform can add/remove entries at any time; do not assume permanence.
pub const ALLOWLIST: &[FlagInfo] = &[
    FlagInfo { key: "DFIntCSGLevelOfDetailSwitchingDistance", group: "Mesh LOD", description: "Distance for switching CSG mesh detail" },
    FlagInfo { key: "DFIntCSGLevelOfDetailSwitchingDistanceL12", group: "Mesh LOD", description: "Mesh LOD transition 1 → 2" },
    FlagInfo { key: "DFIntCSGLevelOfDetailSwitchingDistanceL23", group: "Mesh LOD", description: "Mesh LOD transition 2 → 3" },
    FlagInfo { key: "DFIntCSGLevelOfDetailSwitchingDistanceL34", group: "Mesh LOD", description: "Mesh LOD transition 3 → 4" },
    FlagInfo { key: "DFFlagTextureQualityOverrideEnabled", group: "Graphics", description: "Enable the local texture quality override" },
    FlagInfo { key: "DFIntTextureQualityOverride", group: "Graphics", description: "Texture quality override (0–3)" },
    FlagInfo { key: "FIntDebugForceMSAASamples", group: "Graphics", description: "MSAA sample override (0, 2, 4 or 8)" },
    FlagInfo { key: "DFFlagDisableDPIScale", group: "Graphics", description: "Disable automatic DPI scaling" },
    FlagInfo { key: "FFlagDebugGraphicsPreferD3D11", group: "Graphics API", description: "Prefer Direct3D 11 (Windows)" },
    FlagInfo { key: "FFlagDebugGraphicsPreferVulkan", group: "Graphics API", description: "Prefer Vulkan where supported" },
    FlagInfo { key: "FFlagDebugGraphicsPreferOpenGL", group: "Graphics API", description: "Prefer OpenGL where supported" },
    FlagInfo { key: "FFlagHandleAltEnterFullscreenManually", group: "Input / UI", description: "Manual Alt+Enter fullscreen handling" },
    FlagInfo { key: "FFlagDebugSkyGray", group: "Rendering debug", description: "Debug sky colour override" },
    FlagInfo { key: "DFFlagDebugPauseVoxelizer", group: "Rendering debug", description: "Pause the voxelizer (debug only)" },
    FlagInfo { key: "FIntFRMMaxGrassDistance", group: "Rendering", description: "Maximum grass rendering distance" },
    FlagInfo { key: "FIntFRMMinGrassDistance", group: "Rendering", description: "Minimum grass rendering distance" },
    FlagInfo { key: "FIntGrassMovementReducedMotionFactor", group: "UI motion", description: "Reduce grass movement / motion effects" },
];

pub fn is_allowlisted(key: &str) -> bool {
    ALLOWLIST.iter().any(|flag| flag.key == key)
}

pub fn default_client_settings_path() -> Option<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from)?;
    let versions = local.join("Roblox").join("Versions");
    let mut folders: Vec<PathBuf> = std::fs::read_dir(versions).ok()?.filter_map(|entry| entry.ok().map(|e| e.path())).filter(|p| p.is_dir()).collect();
    folders.sort_by_key(|path| std::cmp::Reverse(path.file_name().map(|name| name.to_os_string()).unwrap_or_default()));
    folders.into_iter().map(|folder| folder.join("ClientAppSettings.json")).next()
}

pub fn backup_path(path: &Path) -> PathBuf {
    let mut backup = path.as_os_str().to_os_string();
    backup.push(".prlngzz-backup.json");
    PathBuf::from(backup)
}

pub fn read(path: &Path) -> Result<Map<String, Value>> {
    if !path.exists() {
        return Ok(Map::new());
    }
    let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let value: Value = serde_json::from_slice(&bytes).context("ClientAppSettings.json is not valid JSON")?;
    value.as_object().cloned().context("ClientAppSettings.json must contain a JSON object")
}

/// Creates a one-time backup and replaces the file with validated allowlisted values.
pub fn write(path: &Path, values: &Map<String, Value>) -> Result<PathBuf> {
    ensure!(path.file_name().is_some(), "Choose a valid ClientAppSettings.json path");
    let mut clean = Map::new();
    for (key, value) in values {
        ensure!(is_allowlisted(key), "'{key}' is not on Roblox's published local-client allowlist");
        validate_value(key, value)?;
        clean.insert(key.clone(), value.clone());
    }
    let backup = backup_path(path);
    if !backup.exists() {
        if path.exists() {
            std::fs::copy(path, &backup).with_context(|| format!("creating backup at {}", backup.display()))?;
        } else {
            std::fs::write(&backup, b"{}\n").with_context(|| format!("creating empty settings backup at {}", backup.display()))?;
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec_pretty(&Value::Object(clean))?;
    let mut temp = path.as_os_str().to_os_string();
    temp.push(".prlngzz-tmp");
    let temp = PathBuf::from(temp);
    std::fs::write(&temp, bytes)?;
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    std::fs::rename(&temp, path).with_context(|| format!("writing {}", path.display()))?;
    Ok(backup)
}

pub fn restore_backup(path: &Path) -> Result<()> {
    let backup = backup_path(path);
    ensure!(backup.is_file(), "No Prlngzz backup exists for this ClientAppSettings.json");
    std::fs::copy(&backup, path).with_context(|| format!("restoring {}", path.display()))?;
    Ok(())
}

pub fn custom_values(mesh_level: u8, texture_quality: u8, msaa: u8) -> Result<Map<String, Value>> {
    ensure!(mesh_level <= 3, "mesh LOD level must be between 0 and 3");
    ensure!(texture_quality <= 3, "texture quality must be between 0 and 3");
    ensure!([0, 2, 4, 8].contains(&msaa), "MSAA must be 0, 2, 4, or 8");
    let distances = [[25, 50, 100, 200], [50, 100, 200, 400], [75, 150, 300, 600], [150, 300, 600, 1200]][mesh_level as usize];
    let mut flags = Map::new();
    flags.insert("DFFlagTextureQualityOverrideEnabled".into(), Value::Bool(true));
    flags.insert("DFIntTextureQualityOverride".into(), Value::from(texture_quality));
    flags.insert("FIntDebugForceMSAASamples".into(), Value::from(msaa));
    for (key, value) in [
        ("DFIntCSGLevelOfDetailSwitchingDistance", distances[0]),
        ("DFIntCSGLevelOfDetailSwitchingDistanceL12", distances[1]),
        ("DFIntCSGLevelOfDetailSwitchingDistanceL23", distances[2]),
        ("DFIntCSGLevelOfDetailSwitchingDistanceL34", distances[3]),
    ] {
        flags.insert(key.into(), Value::from(value));
    }
    Ok(flags)
}

pub fn preset_values(profile: Profile) -> Map<String, Value> {
    let (texture, msaa, grass_min, grass_max, lod) = match profile {
        Profile::Performance => (0, 0, 0, 0, [40, 80, 160, 320]),
        Profile::Balanced => (2, 0, 25, 100, [75, 150, 300, 600]),
        Profile::Quality => (3, 4, 80, 300, [150, 300, 600, 1200]),
    };
    let mut flags = Map::new();
    flags.insert("DFFlagTextureQualityOverrideEnabled".into(), Value::Bool(true));
    flags.insert("DFIntTextureQualityOverride".into(), Value::from(texture));
    flags.insert("FIntDebugForceMSAASamples".into(), Value::from(msaa));
    flags.insert("FIntFRMMinGrassDistance".into(), Value::from(grass_min));
    flags.insert("FIntFRMMaxGrassDistance".into(), Value::from(grass_max));
    for (key, value) in [
        ("DFIntCSGLevelOfDetailSwitchingDistance", lod[0]),
        ("DFIntCSGLevelOfDetailSwitchingDistanceL12", lod[1]),
        ("DFIntCSGLevelOfDetailSwitchingDistanceL23", lod[2]),
        ("DFIntCSGLevelOfDetailSwitchingDistanceL34", lod[3]),
    ] {
        flags.insert(key.into(), Value::from(value));
    }
    flags
}

fn validate_value(key: &str, value: &Value) -> Result<()> {
    if key.starts_with("FInt") || key.starts_with("DFInt") {
        let number = value.as_i64().context("this flag requires an integer value")?;
        ensure!((0..=100_000).contains(&number), "integer value is outside the safe editor range");
        if key == "DFIntTextureQualityOverride" {
            ensure!((0..=3).contains(&number), "texture quality must be between 0 and 3");
        }
        if key == "FIntDebugForceMSAASamples" {
            ensure!([0, 2, 4, 8].contains(&number), "MSAA must be 0, 2, 4, or 8");
        }
        return Ok(());
    }
    if key.starts_with('F') || key.starts_with('D') {
        ensure!(value.is_boolean(), "this flag requires a boolean value");
        return Ok(());
    }
    bail!("unsupported flag type")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn published_allowlist_is_enforced() {
        assert!(is_allowlisted("DFIntTextureQualityOverride"));
        assert!(!is_allowlisted("DFIntTaskSchedulerTargetFps"));
    }

    #[test]
    fn custom_values_contain_only_allowlisted_keys() {
        let flags = custom_values(2, 1, 0).unwrap();
        assert!(flags.keys().all(|key| is_allowlisted(key)));
        assert!(custom_values(4, 1, 0).is_err());
    }

    #[test]
    fn performance_presets_contain_only_allowlisted_keys() {
        for profile in [Profile::Performance, Profile::Balanced, Profile::Quality] {
            assert!(preset_values(profile).keys().all(|key| is_allowlisted(key)));
        }
    }

    #[test]
    fn texture_quality_and_msaa_values_are_bounded() {
        assert!(validate_value("DFIntTextureQualityOverride", &Value::from(4)).is_err());
        assert!(validate_value("FIntDebugForceMSAASamples", &Value::from(3)).is_err());
    }
}
