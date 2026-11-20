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
$cargo = Replace-Once $cargo 'version = "0.1.0"' 'version = "0.2.0"' "package version"
Save-Source $cargoPath $cargo

$changelogPath = Join-Path $Project "changelog.json"
$changelog = [IO.File]::ReadAllText($changelogPath)
$changelog = Replace-Once $changelog '"version": "0.1.0"' '"version": "0.2.0"' "changelog version"
$changelog = $changelog.Replace('"Retains the Rust local cache browser, previews, replacement engine, original backups and cache monitoring from the supplied rbxcache foundation."', '"Groups six-face community skies, adds on-demand asset previews and improves texture preview resolution."')
$changelog = $changelog.Replace('"Adds optional HTTPS-only community catalog, release and changelog endpoint configuration."', '"Adds multi-ID replacement pairing, reload-before-launch, extra accent choices and embedded Windows version metadata."')
Save-Source $changelogPath $changelog

$buildScript = @'
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=CARGO_PKG_VERSION");
    #[cfg(windows)]
    {
        use std::process::Command;
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
      VALUE "OriginalFilename", "Prlngzz-Editor-Windows-x64.exe\0"
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
        let status = Command::new("rc.exe").arg("/nologo").arg("/fo").arg(&res_path).arg(&rc_path).status()
            .expect("Windows resource compiler rc.exe was not found");
        assert!(status.success(), "Windows version resource compilation failed");
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
            ui.label(egui::RichText::new("RIVALS ASSET LIBRARY").strong());
            ui.add_space(8.0);
            ui.add(egui::TextEdit::singleline(&mut self.rivals_catalog_search)
                .desired_width(280.0).hint_text("Search skins, skies, sounds or ID…"));
        });
        ui.label(egui::RichText::new("Community skybox, weapon icon and sound IDs below are replacement assets. The separately labelled map-sky references are target IDs being replaced.")
            .color(theme::MUTED).small());

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
                                theme::pill(ui, format!("{}/6 faces", faces.len()), if complete { theme::OK } else { theme::WARN });
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
            if asset.get("category").and_then(serde_json::Value::as_str) == Some("Community skybox") { return None; }
            let search = rivals_catalog_search_text().get(index).map(String::as_str).unwrap_or("");
            (query.is_empty() || search.contains(&query)).then_some(index)
        }).collect();
        ui.add_space(8.0);
        ui.label(egui::RichText::new(format!("{} other curated assets · {} shown", assets.len().saturating_sub(546), matches.len())).color(theme::MUTED).small());
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
$gui = Replace-RegexOnce $gui '(?s)        if self\.tab == Tab::All \{.*?            return;\r?\n        \}\r?\n        let mut clicked: Option<usize>' '        if self.tab == Tab::All { self.asset_library_page(ui, actions); return; }' "Asset Library page switch"

# Preview image assets on demand; audio assets open the existing player/lookup page.
$gui = Replace-Once $gui @'
        let result = match action {
            Action::Reload => {
'@ @'
        let result = match action {
            Action::PreviewCatalog(id) => {
                let is_sound = rivals_asset_catalog().iter().any(|asset|
                    asset.get("category").and_then(serde_json::Value::as_str) == Some("Community sound")
                    && asset.get("id").and_then(serde_json::Value::as_str) == Some(&id.to_string())
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
$gui = Replace-Once $gui @'
    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {
        let targets = crate::studio::extract_asset_ids(&self.studio_target_input);
        anyhow::ensure!(!targets.is_empty(), "Enter at least one positive numeric asset ID or Roblox asset URL");
        let replacement = self
            .studio_replacement_input
            .trim()
            .parse::<u64>()
            .ok()
            .filter(|id| *id > 0)
            .context("Enter a valid replacement asset ID greater than zero")?;
        for target in &targets {
            self.studio_doc.add_rule(*target, replacement)?;
        }
        self.studio_target_input.clear();
        Ok(targets.len())
    }
'@ @'
    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {
        let targets = crate::studio::extract_asset_ids(&self.studio_target_input);
        let replacements = crate::studio::extract_asset_ids(&self.studio_replacement_input);
        anyhow::ensure!(!targets.is_empty(), "Enter at least one target asset ID or Roblox asset URL");
        anyhow::ensure!(!replacements.is_empty(), "Enter one or more replacement asset IDs");
        anyhow::ensure!(replacements.len() == 1 || replacements.len() == targets.len(),
            "Enter either one replacement ID for every target, or the same number of replacement IDs and targets for one-to-one pairing");
        for (index, target) in targets.iter().enumerate() {
            let replacement = replacements[if replacements.len() == 1 { 0 } else { index }];
            self.studio_doc.add_rule(*target, replacement)?;
        }
        self.studio_target_input.clear();
        self.studio_replacement_input.clear();
        Ok(targets.len())
    }
'@ "multi replacement ID pairing"
$gui = Replace-Once $gui 'ui.label(egui::RichText::new("Replacement asset ID").color(theme::MUTED).small());' 'ui.label(egui::RichText::new("Replacement asset ID(s) · one per target, or one for all").color(theme::MUTED).small());' "replacement list label"
$gui = Replace-Once $gui 'ui.text_edit_singleline(&mut self.studio_replacement_input);' 'ui.add(egui::TextEdit::multiline(&mut self.studio_replacement_input).desired_rows(3).desired_width(260.0).hint_text("Replacement IDs, one per line"));' "multiline replacement input"

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
    /// Accent palette selected by the user.
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
        assert!(matches!(&rules[0].action, Action::Local(path) if path.to_string_lossy() == "C:/Users/santh/Downloads/idekatp.obj"));
        assert_eq!(rules[1].targets, [Target::Asset(18586195727)]);
        assert_eq!(rules[1].action, Action::Remove);
        assert_eq!(rules[2].targets, [Target::Asset(18766863586)]);
        assert_eq!(rules[2].action, Action::With(Target::Asset(124021545052910)));
    }
}
'@
Save-Source $configPath $config

Write-Host "Feature updates applied: version, six-face sky groups, previews, multi-ID pairing, launch, config regressions and customization."
