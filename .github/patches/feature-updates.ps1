param([Parameter(Mandatory=$true)][string]$Project)
$ErrorActionPreference = "Stop"
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$What) {
    $Text = $Text.Replace(([string][char]13 + [char]10), [string][char]10)
    $Old = $Old.Replace(([string][char]13 + [char]10), [string][char]10)
    $New = $New.Replace(([string][char]13 + [char]10), [string][char]10)
    $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($count -ne 1) { throw "Expected exactly one '$What' block; found $count" }
    return $Text.Replace($Old, $New)
}
function Replace-RegexOnce([string]$Text, [string]$Pattern, [string]$New, [string]$What) {
    $count = [regex]::Matches($Text, $Pattern).Count
    if ($count -ne 1) { throw "Expected exactly one '$What' source match; found $count" }
    return [regex]::Replace($Text, $Pattern, $New)
}
function Save-Source([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# Version identity and Windows file properties.
$cargoPath = Join-Path $Project "Cargo.toml"
$cargo = [IO.File]::ReadAllText($cargoPath)
$cargo = Replace-RegexOnce $cargo '(?sm)(\[package\]\s*.*?^version = ")\d+\.\d+\.\d+(")' '${1}0.3.35${2}' "package version"
Save-Source $cargoPath $cargo

$lockPath = Join-Path $Project "Cargo.lock"
$lock = [IO.File]::ReadAllText($lockPath)
$lock = Replace-RegexOnce $lock '(?sm)(\[\[package\]\]\s*name = "prlngzz-editor"\s*version = ")\d+\.\d+\.\d+(")' '${1}0.3.35${2}' "Cargo.lock package version"
Save-Source $lockPath $lock

$changelogPath = Join-Path $Project "changelog.json"
$changelog = [IO.File]::ReadAllText($changelogPath)
$changelog = Replace-RegexOnce $changelog '"version": "\d+\.\d+\.\d+"' '"version": "0.3.35"' "changelog version"
$changelog = $changelog.Replace('"Retains the Rust local cache browser, previews, replacement engine, original backups and cache monitoring from the supplied rbxcache foundation."', '"Adds top-level Skies and Textures navigation, inline image thumbnails and a full-screen P-centered intro with orbiting texture swatches."')
$changelog = $changelog.Replace('"Adds optional HTTPS-only community catalog, release and changelog endpoint configuration."', '"Automatically disables conflicting presets with notifications, adds No Hands cache-removal profiles and expands theme customization."')
Save-Source $changelogPath $changelog

$buildScript = @'
#[cfg(windows)]
use std::path::PathBuf;

#[cfg(windows)]
fn locate_resource_compiler() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();

    if let Some(explicit) = std::env::var_os("RC") {
        candidates.push(PathBuf::from(explicit));
    }

    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|dir| dir.join("rc.exe")));
    }

    if let Ok(output) = std::process::Command::new("where.exe").arg("rc.exe").output() {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            candidates.extend(stdout.lines().map(str::trim).filter(|line| !line.is_empty()).map(PathBuf::from));
        }
    }

    let mut sdk_roots = Vec::new();
    for key in ["WindowsSdkDir", "WindowsSDKDir"] {
        if let Some(value) = std::env::var_os(key) {
            sdk_roots.push(PathBuf::from(value));
        }
    }
    if let Some(value) = std::env::var_os("WindowsSdkVerBinPath") {
        let path = PathBuf::from(value);
        candidates.push(path.join("x64").join("rc.exe"));
        candidates.push(path.join("x86").join("rc.exe"));
    }
    if let Some(program_files) = std::env::var_os("ProgramFiles(x86)") {
        sdk_roots.push(PathBuf::from(program_files).join("Windows Kits").join("10"));
    }
    if let Some(program_files) = std::env::var_os("ProgramFiles") {
        sdk_roots.push(PathBuf::from(program_files).join("Windows Kits").join("10"));
    }

    for root in sdk_roots {
        let bin = if root.file_name().is_some_and(|name| name.eq_ignore_ascii_case("bin")) {
            root.clone()
        } else {
            root.join("bin")
        };
        if let Ok(entries) = std::fs::read_dir(&bin) {
            let mut versions: Vec<PathBuf> = entries.filter_map(Result::ok)
                .map(|entry| entry.path()).filter(|path| path.is_dir()).collect();
            versions.sort_by_key(|path| std::cmp::Reverse(path.file_name().map(|name| name.to_os_string()).unwrap_or_default()));
            for version in versions {
                candidates.push(version.join("x64").join("rc.exe"));
                candidates.push(version.join("x86").join("rc.exe"));
            }
        }
        candidates.push(bin.join("x64").join("rc.exe"));
        candidates.push(bin.join("x86").join("rc.exe"));
        candidates.push(root.join("rc.exe"));
    }

    candidates.into_iter().find(|path| path.is_file())
        .ok_or_else(|| format!(
            "Could not locate rc.exe. Checked RC, PATH, WindowsSdkDir/WindowsSdkVerBinPath and Windows Kits SDK folders. PATH={}",
            std::env::var("PATH").unwrap_or_default()
        ))
}

fn main() {
    println!("cargo:rerun-if-env-changed=CARGO_PKG_VERSION");
    #[cfg(windows)]
    {
        let version = std::env::var("CARGO_PKG_VERSION").expect("Cargo package version is missing");
        let numbers: Vec<u32> = version.split(['.', '-', '+']).take(4)
            .map(|part| part.parse::<u32>().unwrap_or(0)).collect();
        let component = |index: usize| numbers.get(index).copied().unwrap_or(0);
        let file_version = format!("{},{},{},{}", component(0), component(1), component(2), component(3));
        let output = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR is missing"));
        let rc_path = output.join("prlngzz-version.rc");
        let res_path = output.join("prlngzz-version.res");
        let resource = format!(r#"
1 VERSIONINFO
 FILEVERSION {file_version}
 PRODUCTVERSION {file_version}
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0x0L
 FILEOS 0x40004L
 FILETYPE 0x1L
 FILESUBTYPE 0x0L
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "Prlngzz\0"
      VALUE "FileDescription", "Prlngzz Editor\0"
      VALUE "FileVersion", "{version}\0"
      VALUE "InternalName", "prlngzz-editor\0"
      VALUE "OriginalFilename", "Prlngzz-Editor-v{version}-Windows-x64.exe\0"
      VALUE "ProductName", "Prlngzz Editor\0"
      VALUE "ProductVersion", "{version}\0"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0409, 1200
  END
END
"#);
        std::fs::write(&rc_path, resource).expect("could not write Windows version resource");
        let rc = locate_resource_compiler().unwrap_or_else(|error| panic!("{error}"));
        let status = std::process::Command::new(&rc).arg("/nologo").arg("/fo").arg(&res_path).arg(&rc_path).status()
            .unwrap_or_else(|error| panic!("Could not start Windows resource compiler {}: {error}", rc.display()));
        assert!(status.success(), "Windows version resource compilation failed using {}", rc.display());
        println!("cargo:rustc-link-arg-bins={}", res_path.display());
    }
}
'@
Save-Source (Join-Path $Project "build.rs") $buildScript

$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui @'
    eframe::run_native(
        "Prlngzz Editor",
'@ @'
    let window_title = format!("Prlngzz Editor v{}", update::CURRENT);
    eframe::run_native(
        &window_title,
'@ "versioned window title"

$gui = Replace-Once $gui @'
enum Action {
    Reload,
'@ @'
enum Action {
    LaunchRoblox,
    PreviewCatalog(u64),
    Reload,
'@ "launch and preview actions"
$gui = Replace-Once $gui @'
    rivals_catalog_search: String,
    focus: Option<Id>,
'@ @'
    rivals_catalog_search: String,
    catalog_preview_id: Option<u64>,
    library_tab: LibraryTab,
    focus: Option<Id>,
'@ "catalogue preview state"
$gui = Replace-Once $gui @'
    sync_wanted: bool,
    /// True while the work going on was started by a switch on the Configs page, which should not take over the window.
'@ @'
    sync_wanted: bool,
    launch_after_apply: bool,
    /// True while the work going on was started by a switch on the Configs page, which should not take over the window.
'@ "launch-after-apply state"
$gui = Replace-Once $gui @'
            rivals_catalog_search: String::new(),
            focus: None,
'@ @'
            rivals_catalog_search: String::new(),
            catalog_preview_id: None,
            library_tab: LibraryTab::Skies,
            focus: None,
'@ "catalogue preview initialization"
$gui = Replace-Once $gui @'
            sync_wanted: false,
            reapply_targets: HashSet::new(),
'@ @'
            sync_wanted: false,
            launch_after_apply: false,
            reapply_targets: HashSet::new(),
'@ "launch state initialization"

# Replace the former flat catalogue with a grouped sky list and a preview-enabled replacement asset list.
$libraryMethod = @'
    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {
        ui.horizontal(|ui| {
            ui.label(egui::RichText::new("ASSET LIBRARY").strong());
            ui.add_space(8.0);
            ui.add(egui::TextEdit::singleline(&mut self.rivals_catalog_search)
                .desired_width(260.0).hint_text("Search this collection…"));
        });
        ui.horizontal_wrapped(|ui| {
            ui.selectable_value(&mut self.library_tab, LibraryTab::All, "All");
            ui.selectable_value(&mut self.library_tab, LibraryTab::Skies, "Skies");
            ui.selectable_value(&mut self.library_tab, LibraryTab::Textures, "Textures");
            ui.selectable_value(&mut self.library_tab, LibraryTab::Sounds, "Sounds");
        });
        let tab_description = match self.library_tab {
            LibraryTab::All => "Browse every collection in one place.",
            LibraryTab::Skies => "66 individual six-face sky configurations.",
            LibraryTab::Textures => "Community weapon textures and icons.",
            LibraryTab::Sounds => "Community sound assets.",
        };
        ui.label(egui::RichText::new(tab_description).color(theme::MUTED).small());

        let query = self.rivals_catalog_search.trim().to_lowercase();
        let assets = rivals_asset_catalog();
        if let Some(id) = self.catalog_preview_id {
            ui.add_space(6.0);
            ui.group(|ui| {
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(format!("ASSET PREVIEW · {id}")).strong());
                    if ui.small_button("Clear").clicked() { self.catalog_preview_id = None; }
                });
                if let Some(texture) = self.lookup_pictures.get(&id) {
                    let size = texture.size_vec2();
                    let scale = (420.0 / size.x.max(1.0)).min(300.0 / size.y.max(1.0)).min(1.0);
                    ui.image((texture.id(), size * scale));
                    ui.label(egui::RichText::new("Public replacement asset preview").color(theme::MUTED).small());
                } else if self.lookup_job.is_some() {
                    ui.label(egui::RichText::new("Fetching public asset preview from Roblox…").color(theme::MUTED));
                } else {
                    ui.label(egui::RichText::new("No image preview was returned. Restricted assets may not be anonymously downloadable.").color(theme::MUTED));
                }
            });
        }

        let mut skies: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new();
        for asset in assets.iter().filter(|asset| asset.get("category").and_then(serde_json::Value::as_str) == Some("Community skybox")) {
            let name = asset.get("name").and_then(serde_json::Value::as_str).unwrap_or("Unnamed sky").to_owned();
            let face = asset.get("variant").and_then(serde_json::Value::as_str).unwrap_or("").to_ascii_uppercase();
            if let Some(id) = asset.get("id").and_then(serde_json::Value::as_str).and_then(|id| id.parse::<u64>().ok()) {
                skies.entry(name).or_default().insert(face, id);
            }
        }
        let sky_count = skies.len();
        let matching_skies = skies.iter().filter(|(name, faces)| query.is_empty() || name.to_lowercase().contains(&query) || faces.values().any(|id| id.to_string().contains(&query))).count();
        egui::CollapsingHeader::new(format!("COMMUNITY SKYBOXES · {sky_count} grouped six-face sets ({matching_skies} match)"))
            .default_open(!query.is_empty())
            .show(ui, |ui| {
                ui.label(egui::RichText::new("Faces are grouped by name in the order FT, BK, RT, LF, UP, DN. Every ID here is a replacement ID. Put the corresponding six target IDs in Config Builder; its one-to-one pairing creates one six-rule config.")
                    .color(theme::MUTED).small());
                egui::ScrollArea::vertical().max_height(330.0).show(ui, |ui| {
                    for (name, faces) in &skies {
                        if !query.is_empty() && !name.to_lowercase().contains(&query) && !faces.values().any(|id| id.to_string().contains(&query)) { continue; }
                        let order = ["FT", "BK", "RT", "LF", "UP", "DN"];
                        let replacement_ids: Vec<String> = order.iter().filter_map(|face| faces.get(*face).map(u64::to_string)).collect();
                        let complete = order.iter().all(|face| faces.contains_key(*face));
                        egui::Frame::group(ui.style()).show(ui, |ui| {
                            ui.horizontal_wrapped(|ui| {
                                ui.label(egui::RichText::new(name).strong());
                                theme::pill(ui, &format!("{}/6 faces", faces.len()), if complete { theme::OK } else { theme::WARN });
                                if complete && ui.small_button("Use 6 replacement IDs").clicked() {
                                    self.studio_replacement_input = replacement_ids.join("\n");
                                    self.show_tab(Tab::Studio, ui.ctx());
                                }
                            });
                            ui.horizontal_wrapped(|ui| {
                                for face in order {
                                    if let Some(id) = faces.get(face) {
                                        if ui.small_button(format!("Preview {face}")).clicked() {
                                            actions.push(Action::PreviewCatalog(*id));
                                        }
                                    }
                                }
                            });
                        });
                    }
                });
            });

        let map_targets: Vec<String> = assets.iter()
            .filter(|asset| asset.get("category").and_then(serde_json::Value::as_str) == Some("RIVALS map sky texture"))
            .filter_map(|asset| asset.get("id").and_then(serde_json::Value::as_str).map(str::to_owned)).collect();
        ui.horizontal_wrapped(|ui| {
            ui.label(egui::RichText::new(format!("{} known map-sky target references", map_targets.len())).color(theme::MUTED).small());
            if !map_targets.is_empty() && ui.small_button("Load as target IDs").on_hover_text("These IDs are targets being replaced, not replacement assets").clicked() {
                self.studio_target_input = map_targets.join("\n");
                self.show_tab(Tab::Studio, ui.ctx());
            }
        });

        let matches: Vec<usize> = assets.iter().enumerate().filter_map(|(index, asset)| {
            let category = asset.get("category").and_then(serde_json::Value::as_str);
            let visible = match self.library_tab {
                LibraryTab::All => category != Some("Community skybox"),
                LibraryTab::Skies => false,
                LibraryTab::Textures => category == Some("Weapon icon") || category == Some("RIVALS map sky texture"),
                LibraryTab::Sounds => category == Some("Community sound"),
            };
            if !visible { return None; }
            let search = rivals_catalog_search_text().get(index).map(String::as_str).unwrap_or("");
            (query.is_empty() || search.contains(&query)).then_some(index)
        }).collect();
        ui.add_space(8.0);
        ui.label(egui::RichText::new(format!("{} assets shown", matches.len())).color(theme::MUTED).small());
        egui::ScrollArea::vertical().auto_shrink([false, false]).show_rows(ui, 38.0, matches.len(), |ui, visible| {
            for row in visible {
                let asset = &assets[matches[row]];
                let id = asset.get("id").and_then(serde_json::Value::as_str).unwrap_or("");
                let number = id.parse::<u64>().ok();
                let name = asset.get("name").and_then(serde_json::Value::as_str).unwrap_or("RIVALS asset");
                let category = asset.get("category").and_then(serde_json::Value::as_str).unwrap_or("RIVALS");
                let variant = asset.get("variant").and_then(serde_json::Value::as_str).unwrap_or("");
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(category).color(theme::MUTED).small());
                    ui.label(name);
                    if !variant.is_empty() {
                        let label = if variant == "High Res" { "High Res · recommended" } else if variant == "Low Res" { "Low Res · lower detail" } else { variant };
                        ui.label(egui::RichText::new(label).color(if variant == "High Res" { theme::OK } else { theme::MUTED }).small());
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if let Some(id) = number {
                            if ui.small_button("Preview").clicked() { actions.push(Action::PreviewCatalog(id)); }
                        }
                        if ui.small_button(if category == "RIVALS map sky texture" { "Use as target" } else { "Use as replacement" }).clicked() {
                            if category == "RIVALS map sky texture" {
                                self.studio_target_input = id.to_owned();
                            } else {
                                self.studio_replacement_input = id.to_owned();
                            }
                            self.show_tab(Tab::Studio, ui.ctx());
                        }
                        ui.monospace(id);
                    });
                });
                ui.separator();
            }
        });
    }

'@
$gui = Replace-Once $gui '    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {' ($libraryMethod + '    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {') "grouped sky and asset preview method"
$assetLibraryRoute = @'
        if self.tab == Tab::All { self.asset_library_page(ui, actions); return; }
        let mut clicked: Option<usize> = None;
'@
$gui = Replace-RegexOnce $gui '(?s)        if self\.tab == Tab::All \{.*?            return;\r?\n        \}\r?\n        let mut clicked: Option<usize> = None;' $assetLibraryRoute "Asset Library page switch"

# Preview image assets on demand; audio assets open the existing player/lookup page.
$gui = Replace-Once $gui @'
        let result = match action {
            Action::Reload => {
'@ @'
        let result = match action {
            Action::PreviewCatalog(id) => {
                let is_sound = rivals_asset_catalog().iter().any(|asset|
                    asset.get("category").and_then(serde_json::Value::as_str) == Some("Community sound")
                    && asset.get("id").and_then(serde_json::Value::as_str).is_some_and(|value| value == id.to_string())
                );
                if is_sound {
                    self.lookup_input = id.to_string();
                    self.show_tab(Tab::Lookup, ctx);
                } else {
                    self.catalog_preview_id = Some(id);
                }
                self.start_lookup(ctx, vec![id]);
                Ok(format!("Fetching preview for asset {id}"))
            }
            Action::LaunchRoblox => self.reload_configs_then_launch(ctx),
            Action::Reload => {
'@ "asset preview and launch action handlers"

# Reload saved configs automatically before launch and preserve their enabled/off switches.
$gui = Replace-Once $gui @'
                self.pending_configs = Some(pending);
                self.confirm_configs = true;
                self.preview = None;
'@ @'
                self.pending_configs = Some(pending);
                self.preview = None;
                if self.launch_after_apply {
                    self.confirm_configs = false;
                    self.accept_configs();
                } else {
                    self.confirm_configs = true;
                }
'@ "automatic config reload for launch"
$gui = Replace-Once $gui @'
            Some(Err(e)) => {
                self.config_job = None;
                self.notify(ctx, e, true);
            }
'@ @'
            Some(Err(e)) => {
                self.config_job = None;
                self.launch_after_apply = false;
                self.notify(ctx, e, true);
            }
'@ "config reload failure handling"
$gui = Replace-Once $gui @'
            if let Some(loaded) = self.configs.iter().find(|c| config::same_file(&c.path, &config.path)) {
                config.off = loaded.off.clone();
            }
'@ @'
            if let Some(loaded) = self.configs.iter().find(|c| config::same_file(&c.path, &config.path)) {
                config.off = loaded.off.clone();
                config.enabled = loaded.enabled;
            }
'@ "preserve enabled state on reload"

$launchMethod = @'
    fn reload_configs_then_launch(&mut self, ctx: &egui::Context) -> Result<String> {
        let paths: Vec<PathBuf> = self.configs.iter().map(|config| config.path.clone()).collect();
        if paths.is_empty() { return launch_roblox_client(); }
        anyhow::ensure!(self.config_job.is_none() && self.apply_job.is_none(), "Wait for the current config operation to finish before launching Roblox");
        self.launch_after_apply = true;
        match self.check_configs(ctx, paths) {
            Ok(_) => Ok("Reloading saved config files before launching Roblox…".into()),
            Err(error) => { self.launch_after_apply = false; Err(error) }
        }
    }

'@
$gui = Replace-Once $gui '    /// Takes the configs that were checked and confirmed into the list. One' ($launchMethod + '    /// Takes the configs that were checked and confirmed into the list. One') "reload before launch method"

$gui = Replace-Once $gui @'
        self.apply_job = None;
        match result {
            Ok(synced) => {
'@ @'
        self.apply_job = None;
        let launch_after_apply = self.launch_after_apply;
        let mut apply_succeeded = false;
        match result {
            Ok(synced) => {
                apply_succeeded = true;
'@ "launch after config sync"
$gui = Replace-Once $gui @'
            Err(e) => self.notify(ctx, e, true),
        }
        if self.settings.watch {
'@ @'
            Err(e) => self.notify(ctx, e, true),
        }
        if launch_after_apply {
            self.launch_after_apply = false;
            if apply_succeeded {
                match launch_roblox_client() {
                    Ok(message) => self.notify(ctx, message, false),
                    Err(error) => self.notify(ctx, format!("Configs were reloaded, but Roblox could not be launched: {error:#}"), true),
                }
            }
        }
        if self.settings.watch {
'@ "launch only after successful cache sync"

# Sidebar launcher button.
$gui = Replace-Once $gui @'
        ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
'@ @'
        if ui.add_sized(Vec2::new(ui.available_width(), 36.0), primary_button("Launch Roblox")).clicked() {
            actions.push(Action::LaunchRoblox);
        }
        ui.add_space(8.0);
        ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
'@ "sidebar Roblox launch button"

# Pair target and replacement lists one-to-one; a single replacement still works for multiple targets.
$methodStart = $gui.IndexOf('    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {')
$methodEnd = $gui.IndexOf('    fn customization_page', $methodStart)
if ($methodStart -lt 0 -or $methodEnd -le $methodStart) { throw "Could not isolate the Config Studio replacement helper" }
$newMethod = @'
    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {
        let targets = crate::studio::extract_asset_ids(&self.studio_target_input);
        let replacements = crate::studio::extract_asset_ids(&self.studio_replacement_input);
        anyhow::ensure!(!targets.is_empty(), "Enter at least one target asset ID or Roblox asset URL");
        anyhow::ensure!(!replacements.is_empty(), "Enter one or more replacement asset IDs");
        anyhow::ensure!(replacements.len() == 1 || replacements.len() == targets.len(),
            "Enter one replacement ID for every target, or the same number of IDs for one-to-one pairing");
        for (index, target) in targets.iter().enumerate() {
            let replacement = replacements[if replacements.len() == 1 { 0 } else { index }];
            self.studio_doc.add_rule(*target, replacement)?;
        }
        self.studio_target_input.clear();
        self.studio_replacement_input.clear();
        Ok(targets.len())
    }

'@
$gui = $gui.Substring(0, $methodStart) + $newMethod + $gui.Substring($methodEnd)
$labelOld = 'ui.label(egui::RichText::new("Replacement asset ID").color(theme::MUTED).small());'
$gui = $gui.Replace($labelOld, 'ui.label(egui::RichText::new("Replacement asset ID(s) · one per target, or one for all").color(theme::MUTED).small());')
$gui = $gui.Replace('ui.label(egui::RichText::new("Replacement asset ID").color(theme::MUTED).small());', 'ui.label(egui::RichText::new("Replacement asset ID(s) · one per target, or one for all").color(theme::MUTED).small());')
$gui = $gui.Replace('ui.text_edit_singleline(&mut self.studio_replacement_input);', 'ui.add(egui::TextEdit::multiline(&mut self.studio_replacement_input).desired_rows(3).desired_width(260.0).hint_text("Replacement IDs, one per line"));')
if (!$gui.Contains('egui::TextEdit::multiline(&mut self.studio_replacement_input)')) { throw "Replacement ID list fields were not updated" }

# Higher-detail texture decode / display settings.
$gui = $gui.Replace('picture.thumbnail(256, 256)', 'picture.thumbnail(512, 512)')
$gui = $gui.Replace('shrink(image, 2048)', 'shrink(image, 4096)')
$gui = $gui.Replace('viewers::decode_ktx2(body, 2048)', 'viewers::decode_ktx2(body, 4096)')
Save-Source $guiPath $gui

# Extra palette choices and an independently switchable ambient accent effect.
$settingsPath = Join-Path $Project "src/settings.rs"
$settings = [IO.File]::ReadAllText($settingsPath)
$settings = Replace-Once $settings @'
    pub animations: bool,
    /// Accent palette selected in the Customization page.
'@ @'
    pub animations: bool,
    /// Soft breathing glow behind the selected navigation item.
    pub animated_glow: bool,
    /// Accent palette selected by the user.
'@ "animated glow setting"
$settings = Replace-Once $settings @'
            animations: true,
            accent: "violet".into(),
'@ @'
            animations: true,
            animated_glow: true,
            accent: "violet".into(),
'@ "animated glow default"
Save-Source $settingsPath $settings

$themePath = Join-Path $Project "src/theme.rs"
$theme = [IO.File]::ReadAllText($themePath)
$theme = Replace-Once $theme @'
        "amber" => 0xE8B65D,
        _ => 0xA970FF,
'@ @'
        "amber" => 0xE8B65D,
        "mint" => 0x65D6A6,
        "orange" => 0xFF965C,
        "indigo" => 0x8394FF,
        _ => 0xA970FF,
'@ "additional accent colors"
Save-Source $themePath $theme

$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui @'
                    "amber" => "Warm amber",
                    _ => "Prlngzz violet",
'@ @'
                    "amber" => "Warm amber",
                    "mint" => "Mint green",
                    "orange" => "Soft orange",
                    "indigo" => "Indigo",
                    _ => "Prlngzz violet",
'@ "additional accent labels"
$gui = Replace-Once $gui @'
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "amber".into(), "Warm amber").changed();
'@ @'
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "amber".into(), "Warm amber").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "mint".into(), "Mint green").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "orange".into(), "Soft orange").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "indigo".into(), "Indigo").changed();
'@ "additional accent choices"
$gui = Replace-Once $gui @'
            preferences_changed |= ui.checkbox(&mut self.settings.animations, "Enable animations and transitions").changed();
            ui.label(egui::RichText::new("Controls page transitions, sidebar easing and decorative motion. Disabling this keeps the interface still while preserving progress and status feedback.").color(theme::MUTED).small());
'@ @'
            preferences_changed |= ui.checkbox(&mut self.settings.animations, "Enable animations and transitions").changed();
            preferences_changed |= ui.checkbox(&mut self.settings.animated_glow, "Animate selected-tab accent glow").changed();
            ui.label(egui::RichText::new("Controls page transitions, sidebar easing and the soft selected-tab glow. Turn either effect off for a quieter interface.").color(theme::MUTED).small());
'@ "animated glow option"
$gui = Replace-Once $gui @'
            let active = if self.settings.animations {
'@ @'
            let mut active = if self.settings.animations {
'@ "mutable active tab animation"
$gui = Replace-Once $gui @'
            let hover = if self.settings.animations {
'@ @'
            if selected && self.settings.animations && self.settings.animated_glow {
                let pulse = 0.90 + 0.10 * ((now as f32 * 2.0).sin() * 0.5 + 0.5);
                active *= pulse;
                ui.ctx().request_repaint_after(std::time::Duration::from_millis(50));
            }
            let hover = if self.settings.animations {
'@ "pulsing active-tab accent"
Save-Source $guiPath $gui

# Extend native profile import aliases to mirror the config engine.
$studioPath = Join-Path $Project "src/studio.rs"
$studio = [IO.File]::ReadAllText($studioPath)
$studio = $studio.Replace('object.get("replace_ids").or_else(|| object.get("target_ids")).or_else(|| object.get("targets"))',
    'object.get("replace_ids").or_else(|| object.get("target_ids")).or_else(|| object.get("asset_ids")).or_else(|| object.get("targets"))')
$studio = Replace-Once $studio @'
        "remove" => json!({ "type": "remove" }),
        "local" => match object.get("local_path").and_then(Value::as_str).filter(|p| !p.trim().is_empty()) {
'@ @'
        "remove" | "delete" | "remove_asset" => json!({ "type": "remove" }),
        "local" | "local_file" | "file" => match object.get("local_path").and_then(Value::as_str).filter(|p| !p.trim().is_empty()) {
'@ "studio remove and local aliases"
$studio = Replace-Once $studio @'
        "cdn" => {
'@ @'
        "cdn" | "url" | "https" => {
'@ "studio URL aliases"
$studio = Replace-Once $studio @'
        "id" => match object.get("with_id") {
'@ @'
        "id" | "asset_id" | "replace" => match object.get("with_id").or_else(|| object.get("replacement_id")) {
'@ "studio replacement ID aliases"
Save-Source $studioPath $studio

# Roblox protocol handlers (including third-party launchers) first; standard installation as fallback.
$launcher = @'

#[cfg(windows)]
fn launch_roblox_client() -> anyhow::Result<String> {
    if open::that("roblox-player:").is_ok() {
        return Ok("Launch request sent to the registered Roblox player protocol handler.".into());
    }
    let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("LOCALAPPDATA is not available"))?;
    let versions = local.join("Roblox").join("Versions");
    let mut folders: Vec<PathBuf> = std::fs::read_dir(&versions)
        .with_context(|| format!("Could not open Roblox versions folder at {}", versions.display()))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.is_dir()).collect();
    folders.sort_by_key(|path| std::cmp::Reverse(path.file_name().map(|name| name.to_os_string()).unwrap_or_default()));
    for folder in folders {
        let player = folder.join("RobloxPlayerBeta.exe");
        if player.is_file() {
            std::process::Command::new(&player).spawn()
                .with_context(|| format!("Could not start {}", player.display()))?;
            return Ok("Started the installed Roblox desktop player.".into());
        }
    }
    anyhow::bail!("No registered roblox-player protocol handler or installed RobloxPlayerBeta.exe was found.")
}

#[cfg(not(windows))]
fn launch_roblox_client() -> anyhow::Result<String> {
    open::that("roblox-player:").map(|()| "Launch request sent to the registered Roblox player protocol handler.".into())
        .map_err(Into::into)
}

'@
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui 'impl App {' ($launcher + 'impl App {') "cross-launcher Roblox launch helper"
Save-Source $guiPath $gui

# Focused regression coverage for the exact user-supplied JSON patterns.
$configPath = Join-Path $Project "src/config.rs"
$config = [IO.File]::ReadAllText($configPath)
$config += @'

#[cfg(test)]
mod supplied_config_regressions {
    use super::*;
    use std::path::Path;

    #[test]
    fn no_arms_sample_removes_both_targets() {
        let rules = parse(r#"{"replacement_rules":[{"name":"the no arm","replace_ids":[12307734932,12307583853],"mode":"id","enabled":true}]}"#, Path::new(".")).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].name, "the no arm");
        assert_eq!(rules[0].targets, [Target::Asset(12307734932), Target::Asset(12307583853)]);
        assert_eq!(rules[0].action, Action::Remove);
    }

    #[test]
    fn candycane_sample_keeps_target_and_replacement_ids_separate() {
        let rules = parse(r#"{"replacement_rules":[
            {"name":"body","replace_ids":[18586195844],"mode":"local","enabled":true,"local_path":"C:/Users/santh/Downloads/idekatp.obj"},
            {"name":"remove","replace_ids":[18586195727],"mode":"id","enabled":true},
            {"name":"icon","replace_ids":[18766863586],"mode":"id","enabled":true,"with_id":124021545052910}
        ]}"#, Path::new(".")).unwrap();
        assert_eq!(rules.len(), 3);
        assert_eq!(rules[0].targets, [Target::Asset(18586195844)]);
        assert!(matches!(&rules[0].action, Action::Local(path) if path.file_name().and_then(|name| name.to_str()) == Some("idekatp.obj")));
        assert_eq!(rules[1].targets, [Target::Asset(18586195727)]);
        assert_eq!(rules[1].action, Action::Remove);
        assert_eq!(rules[2].targets, [Target::Asset(18766863586)]);
        assert_eq!(rules[2].action, Action::With(Target::Asset(124021545052910)));
    }
}
'@
Save-Source $configPath $config

Write-Host "Feature updates applied: version, six-face sky groups, previews, multi-ID pairing, launch, config regressions and customization."


# Source-complete replacement workflow, verified arena texture examples, and startup intro.
$studioPath = Join-Path $Project "src/studio.rs"
$studio = [IO.File]::ReadAllText($studioPath)
$cdnMethod = @'
    /// Adds an HTTPS CDN replacement to a Roblox asset target.
    pub fn add_cdn_rule(&mut self, target_id: u64, url: &str) -> Result<()> {
        ensure!(target_id > 0, "Target asset ID must be greater than zero");
        let url = url.trim();
        ensure!(url.starts_with("https://"), "CDN replacements must use HTTPS");
        let rules = self.raw.get_mut("rules").and_then(Value::as_array_mut).context("The profile rules field must be an array")?;
        let mut sequence = count_rules(rules) + 1;
        while rule_id_exists(rules, &format!("rule-{sequence:03}")) { sequence += 1; }
        rules.push(json!({
            "id": format!("rule-{sequence:03}"),
            "name": "CDN texture replacement",
            "enabled": true,
            "targets": [target_id],
            "action": { "type": "https", "url": url },
            "notes": "HTTPS CDN replacement. The URL is fetched anonymously when the local cache rule is applied."
        }));
        Ok(())
    }

'@
$studio = Replace-Once $studio '    pub fn remove_rule(&mut self, index: usize) -> bool {' ($cdnMethod + '    pub fn remove_rule(&mut self, index: usize) -> bool {') "Config Studio HTTPS CDN rule method"
Save-Source $studioPath $studio

$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui @'
    studio_replacement_input: String,
    studio_local_path_input: String,
'@ @'
    studio_replacement_input: String,
    studio_cdn_input: String,
    studio_local_path_input: String,
'@ "Config Studio CDN input state"
$gui = Replace-Once $gui @'
            studio_replacement_input: String::new(),
            studio_local_path_input: String::new(),
'@ @'
            studio_replacement_input: String::new(),
            studio_cdn_input: String::new(),
            studio_local_path_input: String::new(),
'@ "Config Studio CDN input initialization"

$cdnCard = @'
        ui.add_space(10.0);
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("HTTPS CDN REPLACEMENT").strong().size(16.0).color(theme::accent()));
            ui.label(egui::RichText::new("Use an HTTPS image or asset URL. The target is the original RIVALS asset; the URL is the replacement.").color(theme::MUTED).small());
            ui.horizontal(|ui| {
                ui.label("CDN URL");
                ui.add(egui::TextEdit::singleline(&mut self.studio_cdn_input).desired_width(390.0).hint_text("https://example.com/texture.png"));
            });
            if ui.add(primary_button("Add CDN replacement")).clicked() {
                match self.add_studio_cdn_rules() {
                    Ok(count) => self.studio_status = format!("Added {count} HTTPS CDN replacement rule(s)."),
                    Err(error) => self.studio_status = format!("Could not add CDN rule: {error:#}"),
                }
            }
        });
'@
$gui = Replace-Once $gui @'
        ui.add_space(10.0);
        let rows = self.studio_doc.rules().to_vec();
'@ ($cdnCard + @'
        ui.add_space(10.0);
        let rows = self.studio_doc.rules().to_vec();
'@) "Config Studio CDN replacement card"

$cdnHelper = @'
    fn add_studio_cdn_rules(&mut self) -> anyhow::Result<usize> {
        let url = self.studio_cdn_input.trim().to_owned();
        anyhow::ensure!(url.starts_with("https://"), "Enter a valid HTTPS CDN URL");
        let targets = crate::studio::extract_asset_ids(&self.studio_target_input);
        anyhow::ensure!(!targets.is_empty(), "Enter one or more original RIVALS target asset IDs");
        for target in &targets { self.studio_doc.add_cdn_rule(*target, &url)?; }
        self.studio_target_input.clear();
        self.studio_cdn_input.clear();
        Ok(targets.len())
    }

'@
$gui = Replace-Once $gui '    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {' ($cdnHelper + '    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {') "Config Studio CDN rule helper"

# Surface the three actual examples from the user's supplied configs; do not infer a floor/wall/prop label.
$arenaCards = @'
        ui.add_space(12.0);
        card(ui, 1.0, |ui| {
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("ARENA TEXTURE LIBRARY").strong().size(18.0).color(theme::accent()));
                theme::pill(ui, "1 verified target · 3 examples", theme::OK);
            });
            ui.label(egui::RichText::new("These entries come from the supplied RIVALS configs. The target surface has not been identified, so it is deliberately labelled Unclassified rather than guessed as a floor, wall or prop.").color(theme::MUTED).small());
            ui.separator();
            ui.horizontal_wrapped(|ui| {
                ui.vertical(|ui| {
                    ui.label(egui::RichText::new("Tism textures").strong());
                    ui.label("Target: 7658055825");
                    ui.label("Replacement: 6372755229");
                    if ui.small_button("Preview replacement").clicked() { actions.push(Action::PreviewCatalog(6372755229)); }
                    if ui.button("Use this texture").clicked() {
                        match self.studio_doc.add_rule(7658055825, 6372755229) {
                            Ok(()) => { self.studio_status = "Added Tism textures to Config Studio. Save & Apply to activate it.".into(); actions.push(Action::ShowTab(Tab::Studio)); }
                            Err(error) => self.studio_status = format!("Could not add Tism textures: {error:#}"),
                        }
                    }
                });
                ui.separator();
                ui.vertical(|ui| {
                    ui.label(egui::RichText::new("Flow Textures").strong());
                    ui.label("Target: 7658055825");
                    ui.label("Replacement: HTTPS CDN");
                    ui.label(egui::RichText::new("raw.githubusercontent.com · Flow Textures.png").color(theme::MUTED).small());
                    if ui.button("Use Flow Textures").clicked() {
                        match self.studio_doc.add_cdn_rule(7658055825, "https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/FLow%20Textures.png") {
                            Ok(()) => { self.studio_status = "Added Flow Textures to Config Studio. Save & Apply to activate it.".into(); actions.push(Action::ShowTab(Tab::Studio)); }
                            Err(error) => self.studio_status = format!("Could not add Flow Textures: {error:#}"),
                        }
                    }
                });
                ui.separator();
                ui.vertical(|ui| {
                    ui.label(egui::RichText::new("No Textures").strong());
                    ui.label("Target: 7658055825");
                    ui.label("Action: Remove original");
                    if ui.button("Use No Textures").clicked() {
                        match self.studio_doc.add_remove_rule("7658055825") {
                            Ok(()) => { self.studio_status = "Added No Textures to Config Studio. Save & Apply to activate it.".into(); actions.push(Action::ShowTab(Tab::Studio)); }
                            Err(error) => self.studio_status = format!("Could not add No Textures: {error:#}"),
                        }
                    }
                });
            });
            ui.label(egui::RichText::new("More arena surfaces will be listed only when their original target IDs and replacement assets are verified.").color(theme::MUTED).small());
        });
'@
$gui = Replace-Once $gui @'
        ui.add_space(12.0);
        ui.label(egui::RichText::new("RECENT LOCAL ACTIVITY").strong().color(theme::MUTED).small());
'@ ($arenaCards + @'
        ui.add_space(12.0);
        ui.label(egui::RichText::new("RECENT LOCAL ACTIVITY").strong().color(theme::MUTED).small());
'@) "verified RIVALS arena texture presets"

# Make local-file portability explicit in the applied-config rule list.
$gui = Replace-Once $gui @'
                                ui.label(egui::RichText::new(rule_summary(rule)).color(theme::MUTED).small());
'@ @'
                                ui.label(egui::RichText::new(rule_summary(rule)).color(theme::MUTED).small());
                                if let config::Action::Local(path) = &rule.action {
                                    if path.is_file() {
                                        theme::pill(ui, "LOCAL ONLY", theme::WARN);
                                    } else {
                                        theme::pill(ui, "LOCAL ONLY · FILE MISSING", theme::DANGER);
                                    }
                                }
'@ "local-only config portability indicator"

# Four-and-a-half-second animated startup intro. The regular UI continues initializing underneath it.
$gui = Replace-Once $gui @'
    studio_status: String,
}
'@ @'
    studio_status: String,
    startup_intro_started: f64,
    startup_intro_skipped: bool,
}
'@ "startup intro state"
$gui = Replace-Once $gui @'
            studio_status: "Create a profile or import a Fleasion-compatible JSON file.".into(),
        };
'@ @'
            studio_status: "Create a profile or import a Fleasion-compatible JSON file.".into(),
            startup_intro_started: cc.egui_ctx.input(|input| input.time),
            startup_intro_skipped: false,
        };
'@ "startup intro initialization"
$intro = @'
        if self.settings.animations && !self.startup_intro_skipped {
            let elapsed = (now - self.startup_intro_started) as f32;
            let duration = 4.0_f32;
            if elapsed < duration {
                let t = (elapsed / duration).clamp(0.0, 1.0);
                let entrance = theme::ease_out((t / 0.18).clamp(0.0, 1.0));
                let exit = ((1.0 - t) / 0.20).clamp(0.0, 1.0);
                let opacity = entrance * exit;
                let rect = ctx.screen_rect();
                egui::Area::new(egui::Id::new("prlngzz-startup-intro"))
                    .order(egui::Order::Foreground)
                    .fixed_pos(rect.min)
                    .show(ctx, |ui| {
                        ui.set_min_size(rect.size());
                        let (surface, _) = ui.allocate_exact_size(rect.size(), egui::Sense::hover());
                        let painter = ui.painter_at(surface);
                        theme::splash_gradient(&painter, surface, 0.985 * opacity);
                        let center = surface.center();
                        let phase = elapsed * 0.72;
                        for i in 0..34 {
                            let x = ((i * 73 + 19) % 997) as f32 / 997.0;
                            let y = ((i * 151 + 47) % 991) as f32 / 991.0;
                            let twinkle = 0.18 + 0.22 * (((elapsed * 1.4 + i as f32).sin() + 1.0) * 0.5);
                            let point = egui::pos2(
                                surface.left() + x * surface.width(),
                                surface.top() + y * surface.height(),
                            );
                            painter.circle_filled(point, 0.8 + (i % 3) as f32 * 0.35,
                                alpha(theme::SPLASH_INK, twinkle * opacity));
                        }

                        let panel_width = (surface.width() * 0.72).clamp(460.0, 760.0);
                        let panel_height = (surface.height() * 0.62).clamp(330.0, 420.0);
                        let lift = (1.0 - entrance) * 26.0;
                        let panel = Rect::from_center_size(
                            center + Vec2::new(0.0, lift),
                            Vec2::new(panel_width, panel_height),
                        );
                        painter.rect_filled(panel.expand(18.0), CornerRadius::same(34),
                            alpha(theme::CARD, 0.12 * opacity));
                        painter.rect_filled(panel, CornerRadius::same(28),
                            alpha(theme::CARD, 0.96 * opacity));
                        painter.rect_filled(
                            Rect::from_min_size(panel.left_top(), Vec2::new(panel.width(), 2.0)),
                            CornerRadius::same(2), alpha(theme::accent(), 0.9 * opacity));

                        let orbit = 86.0 + 10.0 * (phase * 1.8).sin();
                        painter.circle_stroke(center + Vec2::new(0.0, -86.0 + lift), orbit,
                            Stroke::new(1.0, alpha(theme::accent(), 0.30 * opacity)));
                        painter.circle_stroke(center + Vec2::new(0.0, -86.0 + lift), orbit + 16.0,
                            Stroke::new(1.0, alpha(theme::SPLASH_INK, 0.09 * opacity)));
                        let orbit_angle = phase * std::f32::consts::TAU;
                        let orbit_dot = egui::pos2(
                            center.x + orbit * orbit_angle.cos(),
                            center.y - 86.0 + lift + orbit * orbit_angle.sin(),
                        );
                        painter.circle_filled(orbit_dot, 4.0, alpha(theme::accent(), opacity));

                        let mark_center = center + Vec2::new(0.0, -86.0 + lift);
                        painter.circle_filled(mark_center, 43.0, alpha(theme::accent(), 0.16 * opacity));
                        painter.circle_stroke(mark_center, 42.0,
                            Stroke::new(1.5, alpha(theme::accent(), 0.72 * opacity)));
                        painter.text(mark_center, egui::Align2::CENTER_CENTER, "P",
                            egui::FontId::new(48.0, theme::wordmark_font()),
                            alpha(theme::SPLASH_INK, opacity));

                        let title_at = center + Vec2::new(0.0, -14.0 + lift);
                        painter.text(title_at, egui::Align2::CENTER_CENTER, "PRLNGZZ EDITOR",
                            egui::FontId::new(30.0, theme::wordmark_font()),
                            alpha(theme::SPLASH_INK, opacity));
                        painter.text(title_at + Vec2::new(0.0, 34.0), egui::Align2::CENTER_CENTER,
                            "YOUR ROBLOX ASSET WORKSPACE",
                            egui::FontId::proportional(11.0),
                            alpha(theme::SPLASH_MUTED, opacity));

                        let chip_y = title_at.y + 86.0;
                        let chip_labels = ["SKY LIBRARY", "CONFIG BUILDER", "CACHE CONTROL"];
                        let chip_width = 132.0;
                        let chip_gap = 12.0;
                        let total = chip_width * 3.0 + chip_gap * 2.0;
                        for (index, label) in chip_labels.iter().enumerate() {
                            let x = center.x - total * 0.5 + index as f32 * (chip_width + chip_gap);
                            let chip = Rect::from_min_size(
                                egui::pos2(x, chip_y),
                                Vec2::new(chip_width, 30.0),
                            );
                            painter.rect_filled(chip, CornerRadius::same(15),
                                alpha(theme::RAISED, 0.94 * opacity));
                            painter.text(chip.center(), egui::Align2::CENTER_CENTER, *label,
                                egui::FontId::proportional(9.5),
                                alpha(theme::SPLASH_INK, 0.92 * opacity));
                        }

                        painter.text(
                            egui::pos2(panel.center().x, panel.bottom() - 46.0),
                            egui::Align2::CENTER_CENTER,
                            &format!("VERSION  {}  ·  MADE FOR YOUR WORKFLOW", update::CURRENT),
                            egui::FontId::proportional(9.5),
                            alpha(theme::SPLASH_MUTED, opacity),
                        );
                        let width = (panel.width() * 0.52).clamp(220.0, 390.0);
                        let bar = Rect::from_center_size(
                            egui::pos2(center.x, panel.bottom() - 22.0),
                            Vec2::new(width, 2.5),
                        );
                        painter.rect_filled(bar, CornerRadius::same(2),
                            alpha(theme::BORDER, opacity));
                        painter.rect_filled(
                            Rect::from_min_size(bar.min, Vec2::new(width * t, bar.height())),
                            CornerRadius::same(2),
                            alpha(theme::SPLASH_BAR, opacity),
                        );
                    });
                ctx.request_repaint_after(std::time::Duration::from_millis(16));
            } else {
                self.startup_intro_skipped = true;
            }
        }

'@
# Insert the intro immediately after the existing splash call.
$gui = Replace-Once $gui '        self.show_splash(ctx);' ('        self.show_splash(ctx);' + [char]10 + $intro.TrimEnd())
Save-Source $guiPath $gui

# Clippy fixes for the splash drawing literals and formatting call.
$gui = $gui.Replace('Stroke::new(1.0, alpha(theme::accent(), 0.30 * opacity))', 'Stroke::new(1.0_f32, alpha(theme::accent(), 0.30 * opacity))')
$gui = $gui.Replace('Stroke::new(1.0, alpha(theme::SPLASH_INK, 0.09 * opacity))', 'Stroke::new(1.0_f32, alpha(theme::SPLASH_INK, 0.09 * opacity))')
$gui = $gui.Replace('Stroke::new(1.5, alpha(theme::accent(), 0.72 * opacity))', 'Stroke::new(1.5_f32, alpha(theme::accent(), 0.72 * opacity))')
$gui = $gui.Replace('&format!("VERSION  {}  ·  MADE FOR YOUR WORKFLOW", update::CURRENT)', 'format!("VERSION  {}  ·  MADE FOR YOUR WORKFLOW", update::CURRENT)')
Save-Source $guiPath $gui


# Parser regression for the supplied Flow CDN example and HTTPS-only enforcement.
$configPath = Join-Path $Project "src/config.rs"
$config = [IO.File]::ReadAllText($configPath)
$config += @'

#[cfg(test)]
mod cdn_texture_regressions {
    use super::*;
    use std::path::Path;

    #[test]
    fn supplied_flow_texture_uses_verified_target_and_https_replacement() {
        let rules = parse(r#"{"replacement_rules":[{"name":"Textures","replace_ids":[7658055825],"mode":"cdn","enabled":true,"cdn_url":"https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/FLow%20Textures.png"}]}"#, Path::new(".")).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].targets, [Target::Asset(7658055825)]);
        assert_eq!(rules[0].action, Action::Cdn("https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/FLow%20Textures.png".into()));
    }

    #[test]
    fn rejects_non_https_remote_replacement_urls() {
        let rules = parse(r#"{"replacement_rules":[{"name":"unsafe","replace_ids":[7658055825],"mode":"cdn","cdn_url":"http://example.com/texture.png"}]}"#, Path::new(".")).unwrap();
        assert!(matches!(&rules[0].action, Action::Invalid(_)));
    }
}
'@
Save-Source $configPath $config

Write-Host "Added HTTPS Config Studio rules, the three supplied arena texture presets, LOCAL ONLY portability labels, and a 4.5-second animated startup intro."


# Apply presets as independent, enabled local-cache profiles. This keeps unsaved Config Studio edits untouched.
$studioPath = Join-Path $Project "src/studio.rs"
$studio = [IO.File]::ReadAllText($studioPath)
$namedMethods = @'
    /// Adds an asset-ID replacement with a caller-provided, stable rule name.
    pub fn add_named_rule(&mut self, name: &str, target_id: u64, replacement_id: u64) -> Result<()> {
        ensure!(target_id > 0 && replacement_id > 0, "Asset IDs must be greater than zero");
        let rules = self.raw.get_mut("rules").and_then(Value::as_array_mut).context("The profile rules field must be an array")?;
        let mut sequence = count_rules(rules) + 1;
        while rule_id_exists(rules, &format!("rule-{sequence:03}")) { sequence += 1; }
        rules.push(json!({
            "id": format!("rule-{sequence:03}"),
            "name": name,
            "enabled": true,
            "targets": [target_id],
            "action": { "type": "asset_id", "asset_id": replacement_id },
            "notes": "RIVALS cache replacement: the original game asset is the target; this Roblox asset is the replacement."
        }));
        Ok(())
    }

    /// Adds an HTTPS CDN replacement with a caller-provided rule name.
    pub fn add_named_cdn_rule(&mut self, name: &str, target_id: u64, url: &str) -> Result<()> {
        ensure!(target_id > 0, "Target asset ID must be greater than zero");
        let url = url.trim();
        ensure!(url.starts_with("https://"), "CDN replacements must use HTTPS");
        let rules = self.raw.get_mut("rules").and_then(Value::as_array_mut).context("The profile rules field must be an array")?;
        let mut sequence = count_rules(rules) + 1;
        while rule_id_exists(rules, &format!("rule-{sequence:03}")) { sequence += 1; }
        rules.push(json!({
            "id": format!("rule-{sequence:03}"),
            "name": name,
            "enabled": true,
            "targets": [target_id],
            "action": { "type": "https", "url": url },
            "notes": "HTTPS replacement image fetched by the local cache replacement engine."
        }));
        Ok(())
    }

    /// Adds a named removal rule.
    pub fn add_named_remove_rule(&mut self, name: &str, target_id: u64) -> Result<()> {
        ensure!(target_id > 0, "Target asset ID must be greater than zero");
        let rules = self.raw.get_mut("rules").and_then(Value::as_array_mut).context("The profile rules field must be an array")?;
        let mut sequence = count_rules(rules) + 1;
        while rule_id_exists(rules, &format!("rule-{sequence:03}")) { sequence += 1; }
        rules.push(json!({
            "id": format!("rule-{sequence:03}"),
            "name": name,
            "enabled": true,
            "targets": [target_id],
            "action": { "type": "remove" },
            "notes": "Removes the original image payload from the local Roblox cache. Roblox may download the original again later."
        }));
        Ok(())
    }

'@
$studio = Replace-Once $studio '    pub fn remove_rule(&mut self, index: usize) -> bool {' ($namedMethods + '    pub fn remove_rule(&mut self, index: usize) -> bool {') "named preset rules"
Save-Source $studioPath $studio

$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)

# Verified per-face targets, extracted as data from Martinikaws/RivalsSkinChangerFULLMATCHA/main.lua
# at commit 531cc6f92fa5c7f172309d798e6a72cf47321395. Face order is BK, DN, FT, LF, RT, UP.
$skyTargets = @'
#[cfg(test)]
const RIVALS_SKY_FACE_TARGETS: [(&str, [(&str, u64); 6]); 3] = [
    ("Blue", [
        ("BK", 14147881792), ("DN", 14147882149), ("FT", 14147882761),
        ("LF", 14147883091), ("RT", 14147882405), ("UP", 14147881297),
    ]),
    ("Station", [
        ("BK", 2108482005), ("DN", 2108545280), ("FT", 2108482231),
        ("LF", 2108482395), ("RT", 2108482542), ("UP", 2108482676),
    ]),
    ("Space", [
        ("BK", 10196550937), ("DN", 10196550667), ("FT", 10196550367),
        ("LF", 10196550128), ("RT", 10196549902), ("UP", 10196567794),
    ]),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LibraryTab { All, Skies, Textures, Sounds }

'@
$gui = Replace-Once $gui @'
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Tab {
'@ ($skyTargets + @'
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Tab {
'@) "verified six-face RIVALS sky targets"

# One-click preset profiles are explicit actions and never overwrite the user's in-progress Studio document.
$gui = Replace-Once $gui @'
enum Action {
    LaunchRoblox,
'@ @'
enum Action {
    ApplyGeneratedProfile(crate::studio::ProfileDocument),
    LaunchRoblox,
'@ "generated preset apply action"

$gui = Replace-Once $gui @'
    launch_after_apply: bool,
    /// True while the work going on was started by a switch on the Configs page, which should not take over the window.
'@ @'
    launch_after_apply: bool,
    /// A verified library preset can be accepted once its asset IDs have been checked.
    auto_accept_configs: bool,
    /// Library presets explicitly re-enable their profile and all its rules when re-used.
    force_enable_pending_configs: bool,
    /// True while the work going on was started by a switch on the Configs page, which should not take over the window.
'@ "automatic preset-apply state"

$gui = Replace-Once $gui @'
            launch_after_apply: false,
            reapply_targets: HashSet::new(),
'@ @'
            launch_after_apply: false,
            auto_accept_configs: false,
            force_enable_pending_configs: false,
            reapply_targets: HashSet::new(),
'@ "automatic preset-apply state initialization"

$gui = Replace-Once $gui @'
            Action::LaunchRoblox => self.reload_configs_then_launch(ctx),
'@ @'
            Action::ApplyGeneratedProfile(profile) => self.apply_generated_profile(ctx, profile),
            Action::LaunchRoblox => self.reload_configs_then_launch(ctx),
'@ "generated profile action handler"

# Persist, check, auto-enable, and apply an independent profile. The existing Studio buffer is left intact.
$applyGenerated = @'
    fn apply_generated_profile(&mut self, ctx: &egui::Context, profile: crate::studio::ProfileDocument) -> Result<String> {
        anyhow::ensure!(
            self.config_job.is_none() && self.apply_job.is_none() && self.pending_configs.is_none() && !self.confirm_configs,
            "Finish the current config operation before applying another library preset"
        );
        let validation = profile.validation();
        anyhow::ensure!(validation.errors.is_empty(), "The preset profile is invalid: {}", validation.errors.join("; "));
        anyhow::ensure!(validation.enabled_rules > 0, "The preset has no enabled replacement rules");

        let profile_name = profile.name().to_owned();
        let text = profile.to_fleasion_json()?;
        let folder = crate::protection::data_dir()?.join("profiles");
        std::fs::create_dir_all(&folder)?;
        let safe = profile_name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect::<String>();
        let stem = if safe.trim_matches('-').is_empty() { "rivals-preset" } else { safe.trim_matches('-') };
        let mut path = folder.join(format!("{stem}.json"));
        let mut suffix = 2usize;
        while path.exists() {
            if std::fs::read_to_string(&path).ok().as_deref() == Some(text.as_str()) { break; }
            path = folder.join(format!("{stem}-{suffix}.json"));
            suffix += 1;
        }
        std::fs::write(&path, text).with_context(|| format!("saving the {profile_name} preset"))?;

        self.auto_accept_configs = true;
        self.force_enable_pending_configs = true;
        if let Err(error) = self.check_configs(ctx, vec![path]) {
            self.auto_accept_configs = false;
            self.force_enable_pending_configs = false;
            return Err(error);
        }
        Ok(format!("Checking asset IDs and preparing {profile_name} for local-cache apply…"))
    }

'@
$gui = Replace-Once $gui '    fn check_configs(&mut self, ctx: &egui::Context, paths: Vec<PathBuf>) -> Result<String> {' ($applyGenerated + '    fn check_configs(&mut self, ctx: &egui::Context, paths: Vec<PathBuf>) -> Result<String> {') "generated profile apply helper"

$gui = Replace-Once $gui @'
                self.pending_configs = Some(pending);
                self.preview = None;
                if self.launch_after_apply {
                    self.confirm_configs = false;
                    self.accept_configs();
                } else {
                    self.confirm_configs = true;
                }
'@ @'
                self.pending_configs = Some(pending);
                self.preview = None;
                let auto_accept = std::mem::take(&mut self.auto_accept_configs);
                if self.launch_after_apply || auto_accept {
                    self.confirm_configs = false;
                    self.accept_configs();
                } else {
                    self.confirm_configs = true;
                }
'@ "accept library presets after ID checks"

$gui = Replace-Once $gui @'
                self.config_job = None;
                self.launch_after_apply = false;
                self.notify(ctx, e, true);
'@ @'
                self.config_job = None;
                self.launch_after_apply = false;
                self.auto_accept_configs = false;
                self.force_enable_pending_configs = false;
                self.notify(ctx, e, true);
'@ "clear preset apply flags after config-check failure"

$gui = Replace-Once $gui @'
    fn accept_configs(&mut self) {
        let Some(pending) = self.pending_configs.take() else { return };
        for mut config in pending.configs {
            if let Some(loaded) = self.configs.iter().find(|c| config::same_file(&c.path, &config.path)) {
                config.off = loaded.off.clone();
                config.enabled = loaded.enabled;
            }
'@ @'
    fn accept_configs(&mut self) {
        let Some(pending) = self.pending_configs.take() else { return };
        let force_enable = std::mem::take(&mut self.force_enable_pending_configs);
        for mut config in pending.configs {
            if let Some(loaded) = self.configs.iter().find(|c| config::same_file(&c.path, &config.path)) {
                config.off = loaded.off.clone();
                if force_enable {
                    config.off.clear();
                    config.enabled = true;
                } else {
                    config.enabled = loaded.enabled;
                }
            }
'@ "re-enable preset and its rules on use"

# Change the existing Overview-page texture actions from "open Studio" to genuine, one-click local-cache presets.
$gui = Replace-Once $gui @'
                        match self.studio_doc.add_rule(7658055825, 6372755229) {
                            Ok(()) => { self.studio_status = "Added Tism textures to Config Studio. Save & Apply to activate it.".into(); actions.push(Action::ShowTab(Tab::Studio)); }
                            Err(error) => self.studio_status = format!("Could not add Tism textures: {error:#}"),
                        }
'@ @'
                        let mut profile = crate::studio::ProfileDocument::new("Tism textures", "RIVALS");
                        match profile.add_named_rule("Arena 2.0", 7658055825, 6372755229) {
                            Ok(()) => actions.push(Action::ApplyGeneratedProfile(profile)),
                            Err(error) => self.studio_status = format!("Could not prepare Tism textures: {error:#}"),
                        }
'@ "one-click Tism arena preset"

$gui = Replace-Once $gui @'
                        match self.studio_doc.add_cdn_rule(7658055825, "https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/FLow%20Textures.png") {
                            Ok(()) => { self.studio_status = "Added Flow Textures to Config Studio. Save & Apply to activate it.".into(); actions.push(Action::ShowTab(Tab::Studio)); }
                            Err(error) => self.studio_status = format!("Could not add Flow Textures: {error:#}"),
                        }
'@ @'
                        let mut profile = crate::studio::ProfileDocument::new("Flow Textures", "RIVALS");
                        match profile.add_named_cdn_rule("Flow Textures", 7658055825, "https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/FLow%20Textures.png") {
                            Ok(()) => actions.push(Action::ApplyGeneratedProfile(profile)),
                            Err(error) => self.studio_status = format!("Could not prepare Flow Textures: {error:#}"),
                        }
'@ "one-click Flow CDN preset"

$gui = Replace-Once $gui @'
                        match self.studio_doc.add_remove_rule("7658055825") {
                            Ok(()) => { self.studio_status = "Added No Textures to Config Studio. Save & Apply to activate it.".into(); actions.push(Action::ShowTab(Tab::Studio)); }
                            Err(error) => self.studio_status = format!("Could not add No Textures: {error:#}"),
                        }
'@ @'
                        let mut profile = crate::studio::ProfileDocument::new("No Textures", "RIVALS");
                        match profile.add_named_remove_rule("No Textures", 7658055825) {
                            Ok(()) => actions.push(Action::ApplyGeneratedProfile(profile)),
                            Err(error) => self.studio_status = format!("Could not prepare No Textures: {error:#}"),
                        }
'@ "one-click No Textures preset"

# Add the same verified arena presets inside Asset Library, close to the skybox collection.
$arenaLibraryCard = @'
        ui.add_space(10.0);
        egui::CollapsingHeader::new("RIVALS ARENA TEXTURES · 3 verified config examples")
            .default_open(true)
            .show(ui, |ui| {
                ui.label(egui::RichText::new("All three supplied configs target original RIVALS asset 7658055825. The exact arena surface is not identified by the configs, so it is shown as Unclassified rather than guessed.")
                    .color(theme::MUTED).small());
                ui.horizontal_wrapped(|ui| {
                    ui.vertical(|ui| {
                        ui.label(egui::RichText::new("Tism textures").strong());
                        ui.label("Target 7658055825 → Roblox ID 6372755229");
                        if ui.small_button("Preview replacement").clicked() { actions.push(Action::PreviewCatalog(6372755229)); }
                        if ui.button("Use Tism textures").clicked() {
                            let mut profile = crate::studio::ProfileDocument::new("Tism textures", "RIVALS");
                            match profile.add_named_rule("Arena 2.0", 7658055825, 6372755229) {
                                Ok(()) => actions.push(Action::ApplyGeneratedProfile(profile)),
                                Err(error) => self.studio_status = format!("Could not prepare Tism textures: {error:#}"),
                            }
                        }
                    });
                    ui.separator();
                    ui.vertical(|ui| {
                        ui.label(egui::RichText::new("Flow Textures").strong());
                        ui.label("Target 7658055825 → HTTPS CDN image");
                        if ui.button("Use Flow Textures").clicked() {
                            let mut profile = crate::studio::ProfileDocument::new("Flow Textures", "RIVALS");
                            match profile.add_named_cdn_rule("Flow Textures", 7658055825, "https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/FLow%20Textures.png") {
                                Ok(()) => actions.push(Action::ApplyGeneratedProfile(profile)),
                                Err(error) => self.studio_status = format!("Could not prepare Flow Textures: {error:#}"),
                            }
                        }
                    });
                    ui.separator();
                    ui.vertical(|ui| {
                        ui.label(egui::RichText::new("No Textures").strong());
                        ui.label("Target 7658055825 → Remove original payload");
                        if ui.button("Use No Textures").clicked() {
                            let mut profile = crate::studio::ProfileDocument::new("No Textures", "RIVALS");
                            match profile.add_named_remove_rule("No Textures", 7658055825) {
                                Ok(()) => actions.push(Action::ApplyGeneratedProfile(profile)),
                                Err(error) => self.studio_status = format!("Could not prepare No Textures: {error:#}"),
                            }
                        }
                    });
                });
            });

'@
$gui = Replace-Once $gui @'
        let mut skies: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new();
'@ ($arenaLibraryCard + @'
        let mut skies: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new();
'@) "Arena Texture Library presets in Asset Library"

# Use six community replacement faces against the verified original target-face IDs.
# The source game's Graveyard, Sudden Death and Westown presets reuse IDs across faces.
# Because the cache engine replaces by asset ID, distinct per-face replacements cannot be safely assigned to those repeated IDs.
$gui = Replace-Once $gui @'
                ui.label(egui::RichText::new("Faces are grouped by name in the order FT, BK, RT, LF, UP, DN. Every ID here is a replacement ID. Put the corresponding six target IDs in Config Builder; its one-to-one pairing creates one six-rule config.")
                    .color(theme::MUTED).small());
'@ @'
                ui.label(egui::RichText::new("Each complete group supplies six replacement IDs (FT, BK, RT, LF, UP, DN). Use Sky creates 18 named rules: six correctly paired faces for each supported RIVALS sky map (Blue, Station and Space), then checks and enables the profile automatically.")
                    .color(theme::MUTED).small());
'@ "skybox pairing instructions"

$gui = Replace-Once $gui @'
                                if complete && ui.small_button("Use 6 replacement IDs").clicked() {
                                    self.studio_replacement_input = replacement_ids.join("\n");
                                    self.show_tab(Tab::Studio, ui.ctx());
                                }
'@ @'
                                if complete && ui.small_button("Use Sky · apply to 3 maps").clicked() {
                                    let mut profile = crate::studio::ProfileDocument::new(&format!("{name} Skybox"), "RIVALS");
                                    let mut failure = None;
                                    for (map_name, target_faces) in RIVALS_SKY_FACE_TARGETS {
                                        for (face, target_id) in target_faces {
                                            let Some(replacement_id) = faces.get(face).copied() else {
                                                failure = Some(format!("{name} is missing its {face} face"));
                                                break;
                                            };
                                            let rule_name = format!("{name} · {map_name} · {face}");
                                            if let Err(error) = profile.add_named_rule(&rule_name, target_id, replacement_id) {
                                                failure = Some(format!("{map_name} {face}: {error:#}"));
                                                break;
                                            }
                                        }
                                        if failure.is_some() { break; }
                                    }
                                    if let Some(error) = failure {
                                        self.studio_status = format!("Could not prepare skybox: {error}");
                                    } else {
                                        actions.push(Action::ApplyGeneratedProfile(profile));
                                    }
                                }
'@ "one-click six-face sky apply"

# Replace the old misleading 'load six front-face IDs' control with the supported-map limitation.
$oldTargets = @'
        let map_targets: Vec<String> = assets.iter()
            .filter(|asset| asset.get("category").and_then(serde_json::Value::as_str) == Some("RIVALS map sky texture"))
            .filter_map(|asset| asset.get("id").and_then(serde_json::Value::as_str).map(str::to_owned)).collect();
        ui.horizontal_wrapped(|ui| {
            ui.label(egui::RichText::new(format!("{} known map-sky target references", map_targets.len())).color(theme::MUTED).small());
            if !map_targets.is_empty() && ui.small_button("Load as target IDs").on_hover_text("These IDs are targets being replaced, not replacement assets").clicked() {
                self.studio_target_input = map_targets.join("\n");
                self.show_tab(Tab::Studio, ui.ctx());
            }
        });
'@
$newTargets = @'
        ui.label(egui::RichText::new("Supported original sky targets: Blue, Station and Space. Graveyard, Sudden Death and Westown reuse some original image IDs across different face directions; the cache can only assign one replacement per shared ID, so those three are deliberately excluded to prevent incorrect repeated faces.")
            .color(theme::WARN).small());
'@
$gui = Replace-Once $gui $oldTargets $newTargets "safe sky target explanation"

# Regression: every target face in each advertised map must be distinct.
$gui = Replace-Once $gui @'
    #[test]
    fn a_shared_target_goes_to_one_config() {
'@ @'
    #[test]
    fn advertised_sky_maps_have_six_distinct_target_ids() {
        for (name, faces) in RIVALS_SKY_FACE_TARGETS {
            let ids: HashSet<u64> = faces.iter().map(|(_, id)| *id).collect();
            assert_eq!(ids.len(), 6, "{name} must expose six distinct target IDs");
            assert_eq!(faces.iter().map(|(face, _)| *face).collect::<Vec<_>>(), ["BK", "DN", "FT", "LF", "RT", "UP"]);
        }
    }

    #[test]
    fn a_shared_target_goes_to_one_config() {
'@ "unique sky face target regression"

Save-Source $guiPath $gui
Write-Host "Fixed preset application: arena examples now build and enable standalone cache profiles; complete community skyboxes map to verified Blue, Station and Space target faces only."


# The six replacement values are now read directly from the face map when the one-click profile is built.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui '                        let replacement_ids: Vec<String> = order.iter().filter_map(|face| faces.get(*face).map(u64::to_string)).collect();' '' "remove obsolete skybox ID textbox staging"
Save-Source $guiPath $gui


# Build skybox replacement profiles in one tested helper. Target ids are the RIVALS map's original face IDs;
# replacement ids come from the selected community skybox. The mapping order is explicit, not positional guessing.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$skyProfileHelper = @'
#[cfg(test)]
fn build_skybox_profile(name: &str, faces: &BTreeMap<String, u64>) -> anyhow::Result<crate::studio::ProfileDocument> {
    const REQUIRED: [&str; 6] = ["BK", "DN", "FT", "LF", "RT", "UP"];
    for face in REQUIRED {
        anyhow::ensure!(faces.contains_key(face), "The {name} skybox is missing its {face} replacement face");
    }
    let mut profile = crate::studio::ProfileDocument::new(&format!("{name} Skybox"), "RIVALS");
    let mut count = 0usize;
    for (map_name, target_faces) in RIVALS_SKY_FACE_TARGETS {
        for (face, target_id) in target_faces {
            let replacement_id = *faces.get(face).expect("all six faces were checked above");
            let rule_name = format!("{name} · {map_name} · {face}");
            profile.add_named_rule(&rule_name, target_id, replacement_id)?;
            count += 1;
        }
    }
    anyhow::ensure!(count == 18, "A supported skybox must create exactly 18 cache replacement rules");
    let validation = profile.validation();
    anyhow::ensure!(validation.errors.is_empty(), "The generated skybox profile is invalid: {}", validation.errors.join("; "));
    Ok(profile)
}

'@
$gui = Replace-Once $gui 'impl Tab {' ($skyProfileHelper + 'impl Tab {') "testable six-face skybox profile builder"

$oldSkyApply = @'
                                if complete && ui.small_button("Use Sky · apply to 3 maps").clicked() {
                                    let mut profile = crate::studio::ProfileDocument::new(&format!("{name} Skybox"), "RIVALS");
                                    let mut failure = None;
                                    for (map_name, target_faces) in RIVALS_SKY_FACE_TARGETS {
                                        for (face, target_id) in target_faces {
                                            let Some(replacement_id) = faces.get(face).copied() else {
                                                failure = Some(format!("{name} is missing its {face} face"));
                                                break;
                                            };
                                            let rule_name = format!("{name} · {map_name} · {face}");
                                            if let Err(error) = profile.add_named_rule(&rule_name, target_id, replacement_id) {
                                                failure = Some(format!("{map_name} {face}: {error:#}"));
                                                break;
                                            }
                                        }
                                        if failure.is_some() { break; }
                                    }
                                    if let Some(error) = failure {
                                        self.studio_status = format!("Could not prepare skybox: {error}");
                                    } else {
                                        actions.push(Action::ApplyGeneratedProfile(profile));
                                    }
                                }
'@
$newSkyApply = @'
                                if complete && ui.small_button("Use Sky · apply to 3 maps").clicked() {
                                    match build_skybox_profile(name, faces) {
                                        Ok(profile) => actions.push(Action::ApplyGeneratedProfile(profile)),
                                        Err(error) => self.studio_status = format!("Could not prepare skybox: {error:#}"),
                                    }
                                }
'@
$gui = Replace-Once $gui $oldSkyApply $newSkyApply "one-click skybox uses tested face mapping"

# Tests prove that all six replacement faces are paired with the intended original RIVALS target face,
# survive native -> Fleasion conversion, and are still understood by the live cache replacement parser.
$gui = Replace-Once $gui @'
    #[test]
    fn advertised_sky_maps_have_six_distinct_target_ids() {
'@ @'
    #[test]
    fn sky_front_face_targets_match_the_curated_rivals_map_references() {
        let catalog: serde_json::Value = serde_json::from_str(include_str!("../rivals_asset_catalog.json")).unwrap();
        let assets = catalog["assets"].as_array().unwrap();
        for (map_name, faces) in RIVALS_SKY_FACE_TARGETS {
            let front = faces.iter().find(|(face, _)| *face == "FT").unwrap().1;
            let reference = assets.iter().find(|asset| {
                asset["category"].as_str() == Some("RIVALS map sky texture")
                    && asset["name"].as_str().is_some_and(|name| name.eq_ignore_ascii_case(map_name))
            }).unwrap_or_else(|| panic!("Missing curated RIVALS {map_name} front-face reference"));
            assert_eq!(reference["id"].as_str().unwrap().parse::<u64>().unwrap(), front, "{map_name} FT target");
        }
    }

    #[test]
    fn complete_community_sky_creates_18_correctly_directed_cache_rules() {
        let replacements = BTreeMap::from([
            ("BK".to_string(), 9001), ("DN".to_string(), 9002), ("FT".to_string(), 9003),
            ("LF".to_string(), 9004), ("RT".to_string(), 9005), ("UP".to_string(), 9006),
        ]);
        let profile = build_skybox_profile("Regression sky", &replacements).unwrap();
        assert_eq!(profile.validation().enabled_rules, 18);
        let exported = profile.to_fleasion_json().unwrap();
        let rules = crate::config::parse(&exported, std::path::Path::new(".")).unwrap();
        assert_eq!(rules.len(), 18);
        for (map_name, target_faces) in RIVALS_SKY_FACE_TARGETS {
            for (face, target_id) in target_faces {
                let expected_name = format!("Regression sky · {map_name} · {face}");
                let rule = rules.iter().find(|rule| rule.name == expected_name).unwrap();
                assert_eq!(rule.targets, [crate::config::Target::Asset(target_id)]);
                assert_eq!(
                    rule.action,
                    crate::config::Action::With(crate::config::Target::Asset(replacements[face]))
                );
            }
        }
    }

    #[test]
    fn advertised_sky_maps_have_six_distinct_target_ids() {
'@ "sky target and generated profile regressions"
Save-Source $guiPath $gui

$configPath = Join-Path $Project "src/config.rs"
$config = [IO.File]::ReadAllText($configPath)
$config += @'

#[cfg(test)]
mod arena_texture_preset_regressions {
    use super::*;
    use std::path::Path;

    #[test]
    fn supplied_tism_preset_replaces_the_original_rivals_texture_id() {
        let rules = parse(r#"{"replacement_rules":[{"name":"arena2.0","replace_ids":[7658055825],"mode":"id","enabled":true,"with_id":6372755229}]}"#, Path::new(".")).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].targets, [Target::Asset(7658055825)]);
        assert_eq!(rules[0].action, Action::With(Target::Asset(6372755229)));
    }

    #[test]
    fn supplied_no_textures_preset_removes_the_original_rivals_texture_id() {
        let rules = parse(r#"{"replacement_rules":[{"name":"No Textures","replace_ids":[7658055825],"mode":"id","enabled":true}]}"#, Path::new(".")).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].targets, [Target::Asset(7658055825)]);
        assert_eq!(rules[0].action, Action::Remove);
    }
}
'@
Save-Source $configPath $config
Write-Host "Added exact target/replacement round-trip tests for arena presets and six-face sky profiles."


# Polished interaction pass: shared glossy, dimensional buttons across the app.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$oldPrimary = @'
/// A card-shaped placeholder with a band of light passing over it, shown while a list loads.
fn primary_button(text: &str) -> egui::Button<'_> {
    egui::Button::new(egui::RichText::new(text).color(Color32::WHITE)).fill(alpha(theme::accent(), 0.75))
}
'@
$newPrimary = @'
/// A custom 3D button with a soft drop edge, glossy top highlight and a responsive press.
struct BubblyButton<'a> {
    text: &'a str,
    primary: bool,
    compact: bool,
}

impl egui::Widget for BubblyButton<'_> {
    fn ui(self, ui: &mut egui::Ui) -> egui::Response {
        let text_color = if self.primary { Color32::WHITE } else { theme::TEXT };
        let font = egui::FontId::proportional(if self.compact { 12.5 } else if self.primary { 15.5 } else { 14.0 });
        let galley = ui.painter().layout_no_wrap(self.text.to_owned(), font, text_color);
        let horizontal_padding = if self.compact { 14.0 } else if self.primary { 24.0 } else { 18.0 };
        let height: f32 = if self.compact { 36.0 } else if self.primary { 52.0 } else { 40.0 };
        let minimum_width: f32 = if self.primary { 184.0 } else if self.compact { 56.0 } else { 76.0 };
        let size = Vec2::new((galley.size().x + horizontal_padding * 2.0).max(minimum_width), height);
        let (rect, response) = ui.allocate_exact_size(size, egui::Sense::click());
        let response = response.on_hover_cursor(egui::CursorIcon::PointingHand);
        let hover = ui.ctx().animate_bool_with_time(response.id, response.hovered(), 0.14);
        let pressed = response.is_pointer_button_down_on();
        let rounding = CornerRadius::same(if self.compact { 14 } else { 18 });
        let lift = if pressed { 0.0 } else { hover * 1.5 };
        let button_rect = rect.translate(Vec2::new(0.0, -lift));
        let shadow_depth = if pressed { 1.0 } else { 4.0 - hover * 1.1 };
        let painter = ui.painter();
        painter.rect_filled(
            button_rect.translate(Vec2::new(0.0, shadow_depth)),
            rounding,
            alpha(Color32::BLACK, if self.primary { 0.52 } else { 0.38 }),
        );

        let base = if self.primary { theme::accent() } else { theme::RAISED };
        let hover_fill = if self.primary {
            base.lerp_to_gamma(Color32::WHITE, 0.18)
        } else {
            base.lerp_to_gamma(Color32::WHITE, 0.10)
        };
        let mut fill = base.lerp_to_gamma(hover_fill, hover);
        if pressed { fill = fill.gamma_multiply(0.86); }
        let border = if self.primary { alpha(Color32::WHITE, 0.38) } else { alpha(theme::accent(), 0.38 + hover * 0.30) };
        painter.rect_filled(button_rect, rounding, fill);
        let shine = Rect::from_min_max(
            button_rect.min + Vec2::new(1.5, 1.0),
            egui::pos2(button_rect.right() - 1.5, button_rect.center().y),
        );
        painter.rect_filled(shine, rounding, alpha(Color32::WHITE, if self.primary { 0.13 } else { 0.065 }));
        painter.rect_stroke(button_rect, rounding, Stroke::new(1.0_f32, border), egui::StrokeKind::Inside);
        painter.line_segment(
            [
                egui::pos2(button_rect.left() + 20.0, button_rect.bottom() - 1.5),
                egui::pos2(button_rect.right() - 20.0, button_rect.bottom() - 1.5),
            ],
            Stroke::new(1.0_f32, alpha(Color32::BLACK, 0.22)),
        );
        painter.galley(button_rect.center() - galley.size() * 0.5, galley, text_color);
        response
    }
}

fn primary_button(text: &str) -> BubblyButton<'_> {
    BubblyButton { text, primary: true, compact: false }
}

fn bubbly_button(ui: &mut egui::Ui, text: impl AsRef<str>) -> egui::Response {
    ui.add(BubblyButton { text: text.as_ref(), primary: false, compact: false })
}

fn bubbly_small_button(ui: &mut egui::Ui, text: impl AsRef<str>) -> egui::Response {
    ui.add(BubblyButton { text: text.as_ref(), primary: false, compact: true })
}
'@
$gui = Replace-Once $gui $oldPrimary $newPrimary "shared 3D button widget"

$regularButtonMatches = [regex]::Matches($gui, '\bui\.button\(([^()\r\n]*)\)').Count
if ($regularButtonMatches -ne 48) { throw "Expected 48 simple buttons to convert to bubbly controls; found $regularButtonMatches" }
$gui = [regex]::Replace($gui, '\bui\.button\(([^()\r\n]*)\)', 'bubbly_button(ui, $1)')

$smallButtonMatches = [regex]::Matches($gui, '\bui\.small_button\(([^()\r\n]*)\)').Count
if ($smallButtonMatches -ne 10) { throw "Expected 10 simple small buttons to convert; found $smallButtonMatches" }
$gui = [regex]::Replace($gui, '\bui\.small_button\(([^()\r\n]*)\)', 'bubbly_small_button(ui, $1)')
$gui = Replace-Once $gui 'ui.small_button(format!("Preview {face}"))' 'bubbly_small_button(ui, format!("Preview {face}"))' "dynamic sky preview button"

$gui = Replace-Once $gui 'Vec2::new(ui.available_width(), 36.0), primary_button("Launch Roblox")' 'Vec2::new(ui.available_width(), 48.0), primary_button("Launch Roblox")' "larger sidebar launch button"

$homeAnchor = @'
        ui.add_space(18.0);
        ui.label(egui::RichText::new("QUICK ACCESS").strong().color(theme::MUTED).small());
'@
$homeHero = @'
        ui.add_space(18.0);
        card(ui, 1.0, |ui| {
            ui.horizontal(|ui| {
                ui.vertical(|ui| {
                    theme::pill(ui, "READY WHEN YOU ARE", theme::OK);
                    ui.add_space(4.0);
                    ui.label(egui::RichText::new("Jump back into Roblox").size(21.0).strong());
                    ui.label(egui::RichText::new("Refreshes your saved configs before opening the desktop player.").color(theme::MUTED).small());
                    ui.add_space(4.0);
                    ui.label(egui::RichText::new(if self.roblox_running { "Roblox is already running" } else { "Roblox desktop player will be checked when you launch" }).color(theme::MUTED).small());
                });
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.add_sized(Vec2::new(212.0, 54.0), primary_button("LAUNCH ROBLOX")).clicked() {
                        actions.push(Action::LaunchRoblox);
                    }
                });
            });
        });
        ui.add_space(14.0);
        ui.label(egui::RichText::new("QUICK ACCESS").strong().color(theme::MUTED).small());
'@
$gui = Replace-Once $gui $homeAnchor $homeHero "home page launch hero"

# The new intro stays intentionally minimal: a soft fade, restrained mark and slim progress line.

Save-Source $guiPath $gui

# Reinforce the rounded, raised, springy feel on native egui controls and status pills.
$themePath = Join-Path $Project "src/theme.rs"
$theme = [IO.File]::ReadAllText($themePath)
$theme = Replace-Once $theme 'let radius = CornerRadius::same(10);' 'let radius = CornerRadius::same(16);' "larger global control radius"
$theme = Replace-Once $theme 'w.inactive.bg_stroke = Stroke::NONE;' 'w.inactive.bg_stroke = Stroke::new(1.0_f32, alpha(Color32::WHITE, 0.13));' "raised native button border"
$theme = Replace-Once $theme 'w.hovered.bg_fill = Color32::from_rgb(56, 42, 82);' 'w.hovered.bg_fill = Color32::from_rgb(68, 49, 101);' "lifted native hover surface"
$theme = Replace-Once $theme 'w.hovered.weak_bg_fill = Color32::from_rgb(56, 42, 82);' 'w.hovered.weak_bg_fill = Color32::from_rgb(68, 49, 101);' "lifted native weak hover surface"
$theme = Replace-Once $theme 'w.active.bg_fill = alpha(accent, 0.55);' 'w.active.bg_fill = accent.gamma_multiply(0.78);' "pressed native button face"
$theme = Replace-Once $theme 'w.active.weak_bg_fill = alpha(accent, 0.55);' 'w.active.weak_bg_fill = accent.gamma_multiply(0.78);' "pressed native weak button face"
$oldExpansionLoop = @'
    for visuals in [&mut w.noninteractive, &mut w.inactive, &mut w.hovered, &mut w.active, &mut w.open] {
        visuals.corner_radius = radius;
        visuals.expansion = 0.0;
    }
'@
$newExpansionLoop = @'
    for visuals in [&mut w.noninteractive, &mut w.inactive, &mut w.hovered, &mut w.active, &mut w.open] {
        visuals.corner_radius = radius;
        visuals.expansion = 0.0;
    }
    w.inactive.expansion = 0.8;
    w.hovered.expansion = 1.4;
    w.open.expansion = 0.8;
'@
$theme = Replace-Once $theme $oldExpansionLoop $newExpansionLoop "native button elevation states"
$theme = Replace-Once $theme 'CornerRadius::same(6)).inner_margin(Margin::symmetric(7, 1))' 'CornerRadius::same(9)).inner_margin(Margin::symmetric(8, 2))' "bubbly status pills"
Save-Source $themePath $theme

Write-Host "Applied the glossy button system, all button wrappers, home launch hero and cinematic intro."


# Copy and embed every per-sky JSON. The selected JSON is parsed as a native profile and automatically enabled.
$skySource = Join-Path $PSScriptRoot "..\assets\skies"
$skyDestination = Join-Path $Project "sky_profiles"
$skyFiles = @(Get-ChildItem -LiteralPath $skySource -File -Filter "*.json" | Sort-Object Name)
if ($skyFiles.Count -ne 66) { throw "Expected exactly 66 individual sky JSON profiles in $skySource; found $($skyFiles.Count)" }
if (Test-Path $skyDestination) { Remove-Item -LiteralPath $skyDestination -Recurse -Force }
New-Item -ItemType Directory -Force -Path $skyDestination | Out-Null
foreach ($skyFile in $skyFiles) { Copy-Item -LiteralPath $skyFile.FullName -Destination $skyDestination }

$textureSource = Join-Path $PSScriptRoot "..\assets\textures"
$textureFiles = @(Get-ChildItem -LiteralPath $textureSource -File -Filter "*.json" | Sort-Object Name)
if ($textureFiles.Count -ne 5) { throw "Expected exactly 5 texture profile JSON files in $textureSource; found $($textureFiles.Count)" }
$textureDestination = Join-Path $Project "texture_profiles"
if (Test-Path $textureDestination) { Remove-Item -LiteralPath $textureDestination -Recurse -Force }
New-Item -ItemType Directory -Force -Path $textureDestination | Out-Null
foreach ($textureFile in $textureFiles) { Copy-Item -LiteralPath $textureFile.FullName -Destination $textureDestination }

$textureIncludes = ($textureFiles | ForEach-Object { '    include_str!("../texture_profiles/' + $_.Name + '"),' }) -join [Environment]::NewLine
$textureHelpers = @'
const TEXTURE_LIBRARY_JSON: &[&str] = &[
__TEXTURE_JSON_INCLUDES__
];

struct TextureLibraryEntry {
    name: String,
    preview_url: String,
    json: &'static str,
}

fn texture_library_entries() -> &'static [TextureLibraryEntry] {
    static ENTRIES: std::sync::OnceLock<Vec<TextureLibraryEntry>> = std::sync::OnceLock::new();
    ENTRIES.get_or_init(|| {
        TEXTURE_LIBRARY_JSON.iter().map(|raw| {
            let json = *raw;
            let value: serde_json::Value = serde_json::from_str(json)
                .expect("embedded texture library JSON must be valid");
            let metadata = value.get("texture_library")
                .expect("texture JSON must contain texture_library metadata");
            let name = metadata.get("name").and_then(serde_json::Value::as_str)
                .unwrap_or("Unnamed texture").to_owned();
            let preview_url = metadata.get("preview_url").and_then(serde_json::Value::as_str)
                .unwrap_or("").to_owned();
            TextureLibraryEntry { name, preview_url, json }
        }).collect()
    }).as_slice()
}

'@
$textureHelpers = $textureHelpers.Replace("__TEXTURE_JSON_INCLUDES__", $textureIncludes)

$skyIncludes = ($skyFiles | ForEach-Object { '    include_str!("../sky_profiles/' + $_.Name + '"),' }) -join [Environment]::NewLine
$skyHelpers = @'
const SKY_LIBRARY_JSON: &[&str] = &[
__SKY_JSON_INCLUDES__
];

struct SkyLibraryEntry {
    name: String,
    archive: String,
    status: String,
    available_faces: usize,
    json: &'static str,
    faces: BTreeMap<String, u64>,
}

fn sky_library_entries() -> &'static [SkyLibraryEntry] {
    static ENTRIES: std::sync::OnceLock<Vec<SkyLibraryEntry>> = std::sync::OnceLock::new();
    ENTRIES.get_or_init(|| {
        SKY_LIBRARY_JSON.iter().map(|raw| {
            let json = *raw;
            let value: serde_json::Value = serde_json::from_str(json)
                .expect("embedded sky library JSON must be valid");
            let metadata = value.get("sky_library").expect("sky JSON must contain sky_library metadata");
            let name = metadata.get("name").and_then(serde_json::Value::as_str)
                .unwrap_or("Unnamed sky").to_owned();
            let archive = metadata.get("archive").and_then(serde_json::Value::as_str)
                .unwrap_or("").to_owned();
            let status = metadata.get("status").and_then(serde_json::Value::as_str)
                .unwrap_or("needs_face_assets").to_owned();
            let available_faces = metadata.get("available_faces").and_then(serde_json::Value::as_u64).unwrap_or(0) as usize;
            let faces = value.get("faces").and_then(serde_json::Value::as_object)
                .map(|object| object.iter().filter_map(|(face, id)| {
                    id.as_u64().map(|value| (face.clone(), value))
                }).collect())
                .unwrap_or_default();
            SkyLibraryEntry { name, archive, status, available_faces, json, faces }
        }).collect()
    }).as_slice()
}

'@
$skyHelpers = $skyHelpers.Replace("__SKY_JSON_INCLUDES__", $skyIncludes)
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui 'impl Tab {' ($skyHelpers + $textureHelpers + 'impl Tab {') "individual JSON sky library loader"

$skyUi = @'
        if self.library_tab == LibraryTab::Skies {
            let skies = sky_library_entries();
            let visible_skies: Vec<&SkyLibraryEntry> = skies.iter().filter(|entry| {
                query.is_empty() || entry.name.to_lowercase().contains(&query)
                    || entry.faces.values().any(|id| id.to_string().contains(&query))
            }).collect();
            let ready_count = skies.iter().filter(|entry| entry.status == "ready" && entry.available_faces == 6).count();
            ui.horizontal_wrapped(|ui| {
                ui.label(egui::RichText::new("COMMUNITY SKYBOXES").strong());
                theme::pill(ui, &format!("{ready_count} ready"), theme::OK);
                theme::pill(ui, &format!("{} in library", skies.len()), theme::MUTED);
            });
            ui.label(egui::RichText::new("Choose a six-face look. Apply imports the same Fleasion-style replacement_rules JSON, then enables the saved config automatically.")
                .color(theme::MUTED).small());
            ui.add_space(8.0);
            ui.label(egui::RichText::new(format!("{} matching sky profiles", visible_skies.len()))
                .color(theme::MUTED).small());
            egui::ScrollArea::vertical().id_salt("sky-library-gallery").max_height(ui.available_height().clamp(240.0, 520.0)).auto_shrink([false, false]).show(ui, |ui| {
                ui.columns(3, |columns| {
                    for (index, entry) in visible_skies.iter().enumerate() {
                        let column = &mut columns[index % 3];
                        column.push_id(("sky-library-card", &entry.name), |ui| {
                            card(ui, 1.0, |ui| {
                                ui.horizontal_wrapped(|ui| {
                                    ui.label(egui::RichText::new(&entry.name).strong().size(15.0));
                                    if entry.status == "ready" && entry.available_faces == 6 {
                                        theme::pill(ui, "READY", theme::OK);
                                    } else {
                                        theme::pill(ui, &format!("{}/6 CDN", entry.available_faces), theme::WARN);
                                    }
                                });
                                ui.label(egui::RichText::new("RIVALS · SIX-FACE SKYBOX")
                                    .color(theme::MUTED).small());
                                ui.add_space(6.0);
                                ui.horizontal_wrapped(|ui| {
                                    for face in ["BK", "DN", "FT", "LF", "RT", "UP"] {
                                        if let Some(id) = entry.faces.get(face) {
                                            if bubbly_small_button(ui, face).on_hover_text(format!("Preview replacement asset {id}")).clicked() {
                                                actions.push(Action::PreviewCatalog(*id));
                                            }
                                        }
                                    }
                                });
                                ui.add_space(5.0);
                                if entry.status == "ready" && entry.available_faces == 6 {
                                    if bubbly_small_button(ui, "Apply sky").clicked() {
                                        match crate::studio::ProfileDocument::import_fleasion(entry.json) {
                                            Ok(profile) => {
                                                let validation = profile.validation();
                                                if validation.errors.is_empty() && validation.enabled_rules == 6 {
                                                    actions.push(Action::ApplyGeneratedProfile(profile));
                                                } else {
                                                    self.studio_status = format!("{} JSON failed validation: {}", entry.name, validation.errors.join("; "));
                                                }
                                            }
                                            Err(error) => self.studio_status = format!("Could not load {} JSON: {error:#}", entry.name),
                                        }
                                    }
                                } else {
                                    let missing = 6usize.saturating_sub(entry.available_faces);
                                    ui.label(egui::RichText::new(format!("{missing} face image{} still need hosting", if missing == 1 { "" } else { "s" }))
                                        .color(theme::WARN).small());
                                }
                                ui.label(egui::RichText::new(&entry.archive).color(theme::MUTED).small());
                            });
                        });
                    }
                });
            });
            let map_targets: Vec<String> = assets.iter()
                .filter(|asset| asset.get("category").and_then(serde_json::Value::as_str) == Some("RIVALS map sky texture"))
                .filter_map(|asset| asset.get("id").and_then(serde_json::Value::as_str).map(str::to_owned)).collect();
            ui.horizontal_wrapped(|ui| {
                ui.label(egui::RichText::new(format!("{} map-sky target IDs", map_targets.len())).color(theme::MUTED).small());
                if !map_targets.is_empty() && ui.small_button("Load as target IDs").clicked() {
                    self.studio_target_input = map_targets.join("\n");
                    self.show_tab(Tab::Studio, ui.ctx());
                }
            });
        }

        if self.library_tab == LibraryTab::Textures {
            let textures = texture_library_entries();
            let visible_textures: Vec<&TextureLibraryEntry> = textures.iter()
                .filter(|entry| query.is_empty() || entry.name.to_lowercase().contains(&query))
                .collect();
            ui.horizontal_wrapped(|ui| {
                ui.label(egui::RichText::new("COMMUNITY TEXTURE PROFILES").strong());
                theme::pill(ui, &format!("{} profiles", textures.len()), theme::MUTED);
            });
            ui.label(egui::RichText::new("One-click RIVALS presets using the same Arena 2.0 target as Tism and Flow textures. Open Preview to inspect the exact source image.")
                .color(theme::MUTED).small());
            ui.label(egui::RichText::new(format!("{} matching texture profiles", visible_textures.len()))
                .color(theme::MUTED).small());
            egui::ScrollArea::vertical().id_salt("texture-library-gallery")
                .max_height(ui.available_height().clamp(240.0, 520.0))
                .auto_shrink([false, false]).show(ui, |ui| {
                    ui.columns(3, |columns| {
                        for (index, entry) in visible_textures.iter().enumerate() {
                            let column = &mut columns[index % 3];
                            column.push_id(("texture-library-card", &entry.name), |ui| {
                                card(ui, 1.0, |ui| {
                                    ui.horizontal_wrapped(|ui| {
                                        ui.label(egui::RichText::new(&entry.name).strong().size(15.0));
                                        theme::pill(ui, "READY", theme::OK);
                                    });
                                    ui.label(egui::RichText::new("RIVALS · ARENA 2.0 TEXTURE").color(theme::MUTED).small());
                                    ui.label("Target asset: 7658055825");
                                    ui.add_space(6.0);
                                    ui.hyperlink_to("Open image preview", entry.preview_url.as_str());
                                    ui.add_space(6.0);
                                    if bubbly_small_button(ui, "Apply texture").clicked() {
                                        match crate::studio::ProfileDocument::import_fleasion(entry.json) {
                                            Ok(profile) => {
                                                let validation = profile.validation();
                                                if validation.errors.is_empty() && validation.enabled_rules == 1 {
                                                    actions.push(Action::ApplyGeneratedProfile(profile));
                                                } else {
                                                    self.studio_status = format!("{} profile failed validation: {}", entry.name, validation.errors.join("; "));
                                                }
                                            }
                                            Err(error) => self.studio_status = format!("Could not load {} profile: {error:#}", entry.name),
                                        }
                                    }
                                });
                            });
                        }
                    });
                });
        }
        let matches: Vec<usize> = assets
'@
$libraryStartAt = $gui.IndexOf('    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {')
$libraryEndAt = $gui.IndexOf('    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {', $libraryStartAt)
if ($libraryStartAt -lt 0 -or $libraryEndAt -le $libraryStartAt) { throw "Could not isolate asset_library_page for sky gallery replacement" }
$librarySource = $gui.Substring($libraryStartAt, $libraryEndAt - $libraryStartAt)
$librarySource = Replace-RegexOnce $librarySource '        let mut skies: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new\(\);[\s\S]*?        let matches: Vec<usize> = assets' $skyUi "replace grouped catalogue skies inside asset_library_page"
if ($librarySource -notmatch 'if self\.library_tab == LibraryTab::Textures') { throw "Texture gallery was not inserted inside asset_library_page" }
Write-Host "Sky gallery inserted inside asset_library_page (not test code)."
$gui = $gui.Substring(0, $libraryStartAt) + $librarySource + $gui.Substring($libraryEndAt)

$gui = Replace-Once $gui @'
    #[test]
    fn sky_front_face_targets_match_the_curated_rivals_map_references() {
'@ @'
    #[test]
    fn all_individual_sky_json_profiles_are_embedded_and_validated() {
        let skies = sky_library_entries();
        assert_eq!(skies.len(), 66, "one JSON must exist for every indexed sky");
        let mut applyable = 0usize;
        for sky in skies {
            let order = ["BK", "DN", "FT", "LF", "RT", "UP"];
            if sky.status == "ready" {
                applyable += 1;
                assert_eq!(sky.faces.len(), 6, "{} must have six face IDs", sky.name);
                assert!(order.iter().all(|face| sky.faces.contains_key(*face)), "{} has an incomplete face map", sky.name);
                let profile = crate::studio::ProfileDocument::parse_native(sky.json).unwrap();
                let validation = profile.validation();
                assert!(validation.errors.is_empty(), "{} profile errors: {:?}", sky.name, validation.errors);
                assert_eq!(validation.enabled_rules, 18, "{} must enable 18 map-face rules", sky.name);
            } else {
                assert!(sky.faces.len() < 6, "{} is marked incomplete but has all faces", sky.name);
            }
        }
        assert_eq!(applyable, 63, "all catalog-complete skies should be one-click applyable");
    }

    #[test]
    fn sky_front_face_targets_match_the_curated_rivals_map_references() {
'@ "65 individual JSON profile regression test"
[IO.File]::WriteAllText($guiPath,$gui,[Text.UTF8Encoding]::new($false))
Write-Host "Embedded all individual sky JSON profiles."


# Fleasion-compatible six-face CDN JSONs.
# All six rules use the exact default RIVALS target IDs; each side is replaced by one HTTPS CDN image.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = $gui.Replace('crate::studio::ProfileDocument::parse_native(entry.json)', 'crate::studio::ProfileDocument::import_fleasion(entry.json)')
$gui = $gui.Replace('crate::studio::ProfileDocument::parse_native(sky.json)', 'crate::studio::ProfileDocument::import_fleasion(sky.json)')
Save-Source $guiPath $gui

# Rewrite the 66 repository JSON files into the Fleasion replacement_rules schema.
$skySource = Join-Path $PSScriptRoot "..\assets\skies"
$textureRoot = "https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/"
$faceSpecs = @(
    [ordered]@{ name = "SkBack"; side = "Back"; face = "BK"; ids = [long[]]@(2108482005, 14147881792, 135908632589654, 84214501374682, 10196550937, 12261809766) },
    [ordered]@{ name = "SkDown"; side = "Down"; face = "DN"; ids = [long[]]@(2108545280, 10196550667, 14147882149, 103020541883227, 89972436184102, 12261813110) },
    [ordered]@{ name = "SkFront"; side = "Front"; face = "FT"; ids = [long[]]@(14147882761, 12261809766, 135908632589654, 84214501374682, 10196550367, 2108482231) },
    [ordered]@{ name = "SkLeft"; side = "Left"; face = "LF"; ids = [long[]]@(14147883091, 135908632589654, 84214501374682, 2108482395, 12261809766, 10196550128) },
    [ordered]@{ name = "SkRight"; side = "Right"; face = "RT"; ids = [long[]]@(14147882405, 135908632589654, 84214501374682, 2108482542, 12261809766, 10196549902) },
    [ordered]@{ name = "SkUp"; side = "Up"; face = "UP"; ids = [long[]]@(14147881297, 72960281658487, 92138082970751, 2108482676, 10196567794, 12261813678) }
)

# Load face URLs extracted from the original nested sky archives. These override legacy filename guesses.
$archiveFaceMapPath = Join-Path $env:GITHUB_WORKSPACE ".github/assets/sky-face-map.json"
$archiveFaceMap = @{}
if (Test-Path $archiveFaceMapPath) {
    $archiveFaceMapJson = Get-Content -LiteralPath $archiveFaceMapPath -Raw | ConvertFrom-Json
    $archiveFaceMap = @{}
    foreach ($property in $archiveFaceMapJson.PSObject.Properties) {
        # Convert nested JSON objects to real hashtables; PSCustomObject string indexing
        # can otherwise return no face URLs in Windows PowerShell.
        $faceUrls = @{}
        foreach ($faceProperty in $property.Value.PSObject.Properties) {
            $faceUrls[$faceProperty.Name] = [string]$faceProperty.Value
        }
        $archiveFaceMap[$property.Name] = $faceUrls
    }
}
$archiveReadyCount = @($archiveFaceMap.Values | Where-Object { $_.Count -eq 6 }).Count
if ($archiveReadyCount -ne 62) {
    throw "Expected 62 complete archive sky face maps; found $archiveReadyCount. Check sky-face-map.json."
}

# Purple Goo is the only explicit non-archive source; all other skies use faces extracted from the collection archive.
$hostedSkyFiles = @{
    "Purple goo sky" = @{ Back = "PurpleFlowback.png"; Down = "PurpleFlowDown.png"; Front = "PurpleFlowFront.png"; Left = "PurpleFlowLeft.png"; Right = "PurpleFlowRight.png"; Up = "PurpleFlowUp.png" }
}

$skyFiles = @(Get-ChildItem -LiteralPath $skySource -File -Filter "*.json" | Sort-Object Name)
if ($skyFiles.Count -ne 66) { throw "Expected 66 sky JSON files before conversion; found $($skyFiles.Count)" }
$applyReady = 0
foreach ($skyFile in $skyFiles) {
    $old = [IO.File]::ReadAllText($skyFile.FullName) | ConvertFrom-Json
    $name = [string]$old.sky_library.name
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Sky JSON has no sky_library.name: $($skyFile.Name)" }
    $existingFaces = $old.faces
    $replacementRules = @()
    $missingCdnFaces = @()
    $foundCdnFaces = 0

    foreach ($spec in $faceSpecs) {
        $fileName = $null
        $cdnUrl = $null
        $archiveFaces = $archiveFaceMap[$name]
        if ($null -ne $archiveFaces -and -not [string]::IsNullOrWhiteSpace([string]$archiveFaces[$spec.side])) {
            $cdnUrl = [string]$archiveFaces[$spec.side]
        }
        if ([string]::IsNullOrWhiteSpace($cdnUrl) -and $hostedSkyFiles.ContainsKey($name) -and $hostedSkyFiles[$name].ContainsKey($spec.side)) {
            $fileName = [string]$hostedSkyFiles[$name][$spec.side]
            $encodedFileName = [uri]::EscapeDataString($fileName)
            $cdnUrl = $textureRoot + $encodedFileName
        }
        if ([string]::IsNullOrWhiteSpace($cdnUrl)) {
            $missingCdnFaces += $spec.side
            continue
        }
        $replacementRules += [ordered]@{
            name = $spec.name
            replace_ids = $spec.ids
            mode = "cdn"
            enabled = $true
            cdn_url = $cdnUrl
        }
        $foundCdnFaces++
    }

    $status = if ($foundCdnFaces -eq 6) { "ready" } else { "needs_face_assets" }
    if ($status -eq "ready") { $applyReady++ }
    $meta = [ordered]@{
        id = [string]$old.sky_library.id
        name = $name
        archive = [string]$old.sky_library.archive
        archive_type = [string]$old.sky_library.archive_type
        catalog_name = $old.sky_library.catalog_name
        status = $status
        available_faces = $foundCdnFaces
        required_faces = 6
        cdn_files_found = $foundCdnFaces
        cdn_files_missing = @($missingCdnFaces)
        replacement_rule_count = $replacementRules.Count
    }
    $newDocument = [ordered]@{
        name = "$name Skybox"
        game = "RIVALS"
        description = "Fleasion-compatible six-face RIVALS skybox. Each enabled Sk* rule targets the six original IDs for that face and uses the corresponding hosted image."
        replacement_rules = @($replacementRules)
        sky_library = $meta
        faces = $existingFaces
    }
    $json = $newDocument | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($skyFile.FullName, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
if ($applyReady -ne 63) { throw "Expected 63 applyable skies (62 complete archive sets plus Purple goo sky); found $applyReady. Check archive face map and Purple Goo CDN URLs." }

# Re-copy the converted Fleasion JSONs so include_str! embeds the final, exact files.
$skyDestination = Join-Path $Project "sky_profiles"
if (Test-Path $skyDestination) { Remove-Item -LiteralPath $skyDestination -Recurse -Force }
New-Item -ItemType Directory -Force -Path $skyDestination | Out-Null
foreach ($skyFile in $skyFiles) { Copy-Item -LiteralPath $skyFile.FullName -Destination $skyDestination }

# Replace the earlier native-profile regression with exact Fleasion CDN schema checks.
$gui = [IO.File]::ReadAllText($guiPath)
$oldTest = @'
    #[test]
    fn all_individual_sky_json_profiles_are_embedded_and_validated() {
        let skies = sky_library_entries();
        assert_eq!(skies.len(), 66, "one JSON must exist for every indexed sky");
        let mut applyable = 0usize;
        for sky in skies {
            let order = ["BK", "DN", "FT", "LF", "RT", "UP"];
            if sky.status == "ready" {
                applyable += 1;
                assert_eq!(sky.faces.len(), 6, "{} must have six face IDs", sky.name);
                assert!(order.iter().all(|face| sky.faces.contains_key(*face)), "{} has an incomplete face map", sky.name);
                let profile = crate::studio::ProfileDocument::import_fleasion(sky.json).unwrap();
                let validation = profile.validation();
                assert!(validation.errors.is_empty(), "{} profile errors: {:?}", sky.name, validation.errors);
                assert_eq!(validation.enabled_rules, 18, "{} must enable 18 map-face rules", sky.name);
            } else {
                assert!(sky.faces.len() < 6, "{} is marked incomplete but has all faces", sky.name);
            }
        }
        assert_eq!(applyable, 63, "all catalog-complete skies should be one-click applyable");
    }
'@
$newTest = @'
    #[test]
    fn all_individual_sky_json_profiles_use_six_multi_id_cdn_rules() {
        const NAMES: [&str; 6] = ["SkBack", "SkDown", "SkFront", "SkLeft", "SkRight", "SkUp"];
        const TARGETS: [[u64; 6]; 6] = [
            [2108482005, 14147881792, 135908632589654, 84214501374682, 10196550937, 12261809766],
            [2108545280, 10196550667, 14147882149, 103020541883227, 89972436184102, 12261813110],
            [14147882761, 12261809766, 135908632589654, 84214501374682, 10196550367, 2108482231],
            [14147883091, 135908632589654, 84214501374682, 2108482395, 12261809766, 10196550128],
            [14147882405, 135908632589654, 84214501374682, 2108482542, 12261809766, 10196549902],
            [14147881297, 72960281658487, 92138082970751, 2108482676, 10196567794, 12261813678],
        ];
        let skies = sky_library_entries();
        assert_eq!(skies.len(), 66, "one JSON must exist for every indexed sky");
        let mut applyable = 0usize;
        for sky in skies {
            let raw: serde_json::Value = serde_json::from_str(sky.json).unwrap();
            let source_rules = raw.get("replacement_rules").and_then(serde_json::Value::as_array).unwrap();
            assert_eq!(source_rules.len(), sky.available_faces, "{} CDN face count", sky.name);
            let profile = crate::studio::ProfileDocument::import_fleasion(sky.json).unwrap();
            let validation = profile.validation();
            assert!(validation.errors.is_empty(), "{} profile errors: {:?}", sky.name, validation.errors);
            assert_eq!(validation.enabled_rules, sky.available_faces, "{} enabled replacement rules", sky.name);
            let parsed = crate::config::parse(sky.json, std::path::Path::new(".")).unwrap();
            assert_eq!(parsed.len(), sky.available_faces, "{} parsed rules", sky.name);

            let mut checked_faces = std::collections::BTreeSet::new();
            for (source_rule, parsed_rule) in source_rules.iter().zip(parsed.iter()) {
                let rule_name = source_rule["name"].as_str().unwrap_or("");
                let index = NAMES.iter().position(|name| *name == rule_name)
                    .unwrap_or_else(|| panic!("{} has unknown CDN face rule {rule_name}", sky.name));
                assert!(checked_faces.insert(index), "{} has duplicate CDN face rule {rule_name}", sky.name);
                assert_eq!(source_rule["mode"].as_str(), Some("cdn"));
                assert_eq!(source_rule["enabled"].as_bool(), Some(true));
                let ids = source_rule["replace_ids"].as_array().unwrap().iter()
                    .map(|id| id.as_u64().unwrap()).collect::<Vec<_>>();
                assert_eq!(ids, TARGETS[index].to_vec(), "{} {} target IDs", sky.name, rule_name);
                let cdn_url = source_rule["cdn_url"].as_str().unwrap();
                if sky.name == "Purple goo sky" {
                    assert!(cdn_url.starts_with("https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/PurpleFlow"),
                        "Purple goo sky must use its supplied PurpleFlow face URLs: {cdn_url}");
                } else {
                    assert!(cdn_url.starts_with("https://media.githubusercontent.com/media/Prlngzz/Prlngzz-Editor/sky-library-cdn-assets/.github/assets/sky-faces/"),
                        "{} {} must use the separate archive-asset CDN branch: {cdn_url}", sky.name, rule_name);
                }
                let expected_targets = TARGETS[index].iter().copied()
                    .map(crate::config::Target::Asset).collect::<Vec<_>>();
                assert_eq!(parsed_rule.targets, expected_targets, "{} {} parsed target IDs", sky.name, rule_name);
                assert!(matches!(&parsed_rule.action, crate::config::Action::Cdn(_)));
            }
            assert_eq!(checked_faces.len(), sky.available_faces, "{} must have one rule per available face", sky.name);
            if sky.status == "ready" {
                applyable += 1;
                assert_eq!(sky.available_faces, 6, "{} must have all six hosted face images", sky.name);
                assert_eq!(source_rules.len(), 6);
            } else {
                assert!(sky.available_faces < 6, "{} is incorrectly marked unavailable", sky.name);
                assert!(source_rules.len() < 6, "{} should not advertise a broken six-face profile", sky.name);
            }
        }
        assert_eq!(applyable, 63, "62 complete archive skies plus Purple goo sky must be applyable");
    }
'@
$gui = Replace-Once $gui $oldTest $newTest "six-rule Fleasion sky JSON regression"
$gui = Replace-Once $gui @'
    #[test]
    fn sky_front_face_targets_match_the_curated_rivals_map_references() {
'@ @'
    #[test]
    fn all_five_texture_library_profiles_are_embedded_and_validated() {
        const EXPECTED: [&str; 5] = [
            "Minecraft textures", "Gray textures", "Louis Vuitton textures",
            "Spiked textures", "Brick textures",
        ];
        let textures = texture_library_entries();
        assert_eq!(textures.len(), EXPECTED.len());
        for (texture, expected_name) in textures.iter().zip(EXPECTED) {
            assert_eq!(texture.name, expected_name);
            assert!(texture.preview_url.starts_with("https://"));
            let raw: serde_json::Value = serde_json::from_str(texture.json).unwrap();
            assert_eq!(raw["replacement_rules"][0]["name"].as_str(), Some("Arena 2.0"));
            assert_eq!(raw["replacement_rules"][0]["mode"].as_str(), Some("cdn"));
            assert_eq!(raw["replacement_rules"][0]["replace_ids"][0].as_u64(), Some(7658055825));
            assert_eq!(raw["replacement_rules"][0]["cdn_url"].as_str(), Some(texture.preview_url.as_str()));
            let profile = crate::studio::ProfileDocument::import_fleasion(texture.json).unwrap();
            let validation = profile.validation();
            assert!(validation.errors.is_empty(), "{} errors: {:?}", texture.name, validation.errors);
            assert_eq!(validation.enabled_rules, 1, "{} should have one Arena 2.0 rule", texture.name);
        }
    }

    #[test]
    fn sky_front_face_targets_match_the_curated_rivals_map_references() {
'@ "five texture profile regression tests"
Save-Source $guiPath $gui

Write-Host "Converted 66 sky JSONs to Fleasion CDN schema; 63 complete six-face profiles are applyable (62 archive skies plus Purple goo sky)."


# Navigation tabs are text-only; remove the icon drawing path and its preference toggle.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-RegexOnce $gui '(?s)\s+let glyph = match tab \{.*?ui\.painter\(\)\.text\(\s*egui::pos2\(x, rect\.center\(\)\.y - 6\.0\),' @'
            let x = rect.left() + 23.0;
            ui.painter().text(
                egui::pos2(x, rect.center().y - 6.0),
'@ "text-only sidebar navigation"
$gui = $gui.Replace('            preferences_changed |= ui.checkbox(&mut self.settings.show_nav_icons, "Show sidebar icons").changed();', '')
Save-Source $guiPath $gui
