param([Parameter(Mandatory=$true)][string]$Project)
$ErrorActionPreference = "Stop"

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$What) {
    $nl = [string][char]10
    $crlf = [string][char]13 + $nl
    $Text = $Text.Replace($crlf, $nl)
    $Old = $Old.Replace($crlf, $nl)
    $New = $New.Replace($crlf, $nl)
    $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($count -ne 1) { throw "Expected exactly one '$What' block; found $count" }
    return $Text.Replace($Old, $New)
}
function Save-Source([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)

# Move the verified arena presets into the Config Library's Textures tab and add No Hands cache removal.
$arenaHeader = 'egui::CollapsingHeader::new("RIVALS ARENA TEXTURES · 3 verified config examples")'
$arenaAt = $gui.IndexOf($arenaHeader)
if ($arenaAt -lt 0) { throw "Arena texture cards not found" }
$arenaStart = $gui.LastIndexOf('        ui.add_space(10.0);', $arenaAt)
$arenaEndMatch = [regex]::Match($gui.Substring($arenaAt), '(?m)^        \}\);')
if (!$arenaEndMatch.Success) { throw "Could not isolate Arena texture cards" }
$arenaEnd = $arenaAt + $arenaEndMatch.Index + $arenaEndMatch.Length
if ($arenaStart -lt 0 -or $arenaEnd -le $arenaStart) { throw "Could not isolate Arena texture cards" }
$arenaCard = $gui.Substring($arenaStart, $arenaEnd - $arenaStart)
$gui = $gui.Substring(0, $arenaStart) + $gui.Substring($arenaEnd)

$textureSuffix = @'
            if self.library_tab == LibraryTab::Textures {
                card(ui, 1.0, |ui| {
                    ui.label(egui::RichText::new("NO HANDS · CACHE REMOVAL").strong().color(theme::accent()));
                    ui.label(egui::RichText::new("Paste exact arm asset IDs from your current RIVALS build. This creates a local-cache removal profile; IDs are never guessed.").color(theme::MUTED).small());
                    ui.add(egui::TextEdit::multiline(&mut self.studio_target_input)
                        .desired_rows(2).desired_width(f32::INFINITY)
                        .hint_text("Exact arm asset IDs, separated by spaces, commas or new lines"));
                    if bubbly_small_button(ui, "Build & apply No Hands profile").clicked() {
                        match build_no_hands_cache_profile(&self.studio_target_input) {
                            Ok(profile) => actions.push(Action::ApplyGeneratedProfile(profile)),
                            Err(error) => self.studio_status = format!("Could not prepare No Hands profile: {error:#}"),
                        }
                    }
                });
                ui.add_space(10.0);
            }
'@

$libraryStartAt = $gui.IndexOf('    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {')
$libraryEndAt = $gui.IndexOf('    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {', $libraryStartAt)
if ($libraryStartAt -lt 0 -or $libraryEndAt -le $libraryStartAt) { throw "Could not isolate Config Library page" }
$librarySource = $gui.Substring($libraryStartAt, $libraryEndAt - $libraryStartAt)
$librarySource = Replace-Once $librarySource @'
        let query = self.rivals_catalog_search.trim().to_lowercase();
        let assets = rivals_asset_catalog();
'@ @'
'@ "move catalog query and assets before texture presets"
$libraryAnchor = '    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {'
$textureBlock = @'
        let query = self.rivals_catalog_search.trim().to_lowercase();
        let assets = rivals_asset_catalog();
        if self.library_tab == LibraryTab::Textures {
'@
$textureBlock += $arenaCard
$textureBlock += $textureSuffix
$textureBlock += [Environment]::NewLine
$librarySource = Replace-Once $librarySource $libraryAnchor ($libraryAnchor + [Environment]::NewLine + $textureBlock) "Textures tab presets and No Hands card"
$gui = $gui.Substring(0, $libraryStartAt) + $librarySource + $gui.Substring($libraryEndAt)
# Keep the collection navigation visible at the top, and render the Skies gallery independently from Textures.
$gui = Replace-Once $gui @'
            });
            if self.library_tab == LibraryTab::Skies {
'@ @'
            });
        }
        if self.library_tab == LibraryTab::Skies {
'@ "separate Skies gallery from Textures-only presets"

$libraryMethodStart = $gui.IndexOf('    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {')
$libraryMethodEnd = $gui.IndexOf('    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {', $libraryMethodStart)
$lf = [string][char]10
$navStartMarker = '        ui.horizontal(|ui| {' + $lf + '            ui.label(egui::RichText::new("CONFIG LIBRARY").strong());'
$navStart = $gui.IndexOf($navStartMarker, $libraryMethodStart)
$navEndMarker = '        ui.label(egui::RichText::new(tab_description).color(theme::MUTED).small());'
$navEndAt = $gui.IndexOf($navEndMarker, $navStart)
if ($libraryMethodStart -lt 0 -or $libraryMethodEnd -le $libraryMethodStart -or $navStart -lt 0 -or $navEndAt -lt $navStart) {
    throw "Could not relocate Config Library navigation to the top of the page"
}
$navEnd = $navEndAt + $navEndMarker.Length
$libraryNav = $gui.Substring($navStart, $navEnd - $navStart)
$gui = $gui.Remove($navStart, $navEnd - $navStart)
$assetAnchor = '        let assets = rivals_asset_catalog();'
$gui = Replace-Once $gui $assetAnchor ($assetAnchor + $lf + $libraryNav) "place Skies and Textures tabs above content"

$oldTextureFilter = @'
                    let visible = match self.library_tab {
                        LibraryTab::All => category != Some("Community skybox"),
                        LibraryTab::Skies => false,
                        LibraryTab::Textures => category == Some("Weapon icon") || category == Some("RIVALS map sky texture"),
                    };
'@
$newTextureFilter = @'
                    let visible = match self.library_tab {
                        LibraryTab::All => category != Some("Community skybox"),
                        LibraryTab::Skies => false,
                        // Blue, Station and Space front-face refs are already represented by the Skies collection.
                        LibraryTab::Textures => category == Some("Weapon icon") || (
                            category == Some("RIVALS map sky texture")
                                && !matches!(
                                    asset.get("id").and_then(serde_json::Value::as_str),
                                    Some("14147882761" | "2108482231" | "10196550367")
                                )
                        ),
                    };
'@
$gui = Replace-Once $gui $oldTextureFilter $newTextureFilter "remove three duplicate sky targets from Textures"

# Remove the Sounds tab (sounds remain discoverable through All).
$gui = Replace-Once $gui 'enum LibraryTab { All, Skies, Textures, Sounds }' 'enum LibraryTab { All, Skies, Textures }' "remove Sounds tab state"
$gui = Replace-Once $gui '            ui.selectable_value(&mut self.library_tab, LibraryTab::Sounds, "Sounds");' '' "remove Sounds selector"
$gui = Replace-Once $gui '            LibraryTab::Sounds => "Community sound assets.",' '' "remove Sounds description"
$gui = Replace-Once $gui '                LibraryTab::Sounds => category == Some("Community sound"),' '' "remove Sounds category filter"
$gui = $gui.Replace("ASSET LIBRARY", "CONFIG LIBRARY").Replace("Asset Library", "Config Library")

# Hide the three legacy destinations and their remaining library shortcuts.
$gui = Replace-Once $gui '            (Tab::Rivals, "RIVALS Workspace", "Game-specific profiles"),' '' "remove RIVALS Workspace nav"
$gui = Replace-Once $gui '            (Tab::Studio, "Config Builder", "Create and edit replacement rules"),' '' "remove Config Builder nav"
$gui = Replace-Once $gui '            (Tab::AssetIds, "Asset ID Editor", "RIVALS asset IDs"),' '' "remove Asset ID Editor nav"
$gui = $gui.Replace("RIVALS CONFIG BUILDER", "CONFIG MANAGER").Replace("Asset ID Editor", "cache asset tools")
# Remove the obsolete per-row shortcut if the restored source still contains it.
$legacyShortcut = @'
                        if ui.small_button(if category == "RIVALS map sky texture" { "Use as target" } else { "Use as replacement" }).clicked() {
                            if category == "RIVALS map sky texture" {
                                self.studio_target_input = id.to_owned();
                            } else {
                                self.studio_replacement_input = id.to_owned();
                            }
                            self.show_tab(Tab::Studio, ui.ctx());
                        }
'@
if ($gui.Contains($legacyShortcut)) {
    $gui = Replace-Once $gui $legacyShortcut '' "remove hidden Builder asset shortcut"
} else {
    Write-Host "Legacy per-row Builder shortcut is already absent; no change needed."
}

# Cinematic intro with aurora trails and a faceted, pulsing prism mark.
$gui = Replace-Once $gui '            let duration = 4.0_f32;' '            let duration = 5.2_f32;' "intro duration"
$gui = Replace-Once $gui @'
                        let panel_width = (surface.width() * 0.72).clamp(460.0, 760.0);
'@ @'
                        for band in 0..9 {
                            let drift = elapsed * (18.0 + band as f32 * 2.4);
                            let y = surface.top() + surface.height() * 0.18 + band as f32 * 22.0;
                            let x = surface.left() + (band as f32 * 71.0 + drift) % surface.width().max(1.0);
                            painter.line_segment(
                                [egui::pos2(x, y), egui::pos2((x + 230.0).min(surface.right()), y - 36.0)],
                                Stroke::new(1.0_f32, alpha(theme::accent(), 0.055 * opacity)),
                            );
                        }
                        for spark in 0..18 {
                            let angle = elapsed * 0.34 + spark as f32 * std::f32::consts::TAU / 18.0;
                            let radius = 150.0 + 90.0 * ((elapsed * 0.42 + spark as f32).sin() * 0.5 + 0.5);
                            let from = center + Vec2::new(angle.cos(), angle.sin()) * radius;
                            let to = center + Vec2::new(angle.cos(), angle.sin()) * (radius + 20.0 + 16.0 * (elapsed + spark as f32).sin().abs());
                            painter.line_segment([from, to], Stroke::new(1.5_f32, alpha(theme::accent(), 0.24 * opacity)));
                        }
                        let panel_width = (surface.width() * 0.72).clamp(460.0, 760.0);
'@ "intro aurora trails"
$oldMark = @'
                        let mark_center = center + Vec2::new(0.0, -86.0 + lift);
                        painter.circle_filled(mark_center, 43.0, alpha(theme::accent(), 0.16 * opacity));
                        painter.circle_stroke(mark_center, 42.0,
                            Stroke::new(1.5_f32, alpha(theme::accent(), 0.72 * opacity)));
                        painter.text(mark_center, egui::Align2::CENTER_CENTER, "P",
                            egui::FontId::new(48.0, theme::wordmark_font()),
                            alpha(theme::SPLASH_INK, opacity));

                        let title_at = center + Vec2::new(0.0, -14.0 + lift);
'@
$newMark = @'
                        let mark_center = center + Vec2::new(0.0, -86.0 + lift);
                        let pulse = 1.0 + 0.045 * (elapsed * 2.2).sin();
                        let sx = pulse;
                        let sy = pulse * (1.0 + 0.025 * (elapsed * 1.4).cos());
                        let top = egui::pos2(mark_center.x, mark_center.y - 55.0 * sy);
                        let right = egui::pos2(mark_center.x + 52.0 * sx, mark_center.y - 2.0);
                        let lower = egui::pos2(mark_center.x + 15.0 * sx, mark_center.y + 49.0 * sy);
                        let left = egui::pos2(mark_center.x - 44.0 * sx, mark_center.y + 28.0 * sy);
                        let shoulder = egui::pos2(mark_center.x - 50.0 * sx, mark_center.y - 19.0);
                        painter.circle_filled(mark_center, 84.0 * pulse, alpha(theme::accent(), 0.075 * opacity));
                        painter.add(egui::Shape::convex_polygon(
                            vec![top, right, lower, left, shoulder],
                            alpha(theme::accent(), 0.82 * opacity),
                            Stroke::new(1.8_f32, alpha(Color32::WHITE, 0.48 * opacity)),
                        ));
                        painter.add(egui::Shape::convex_polygon(
                            vec![
                                egui::pos2(mark_center.x - 14.0, mark_center.y - 31.0 * sy),
                                egui::pos2(mark_center.x + 30.0 * sx, mark_center.y - 3.0),
                                egui::pos2(mark_center.x + 5.0, mark_center.y + 29.0 * sy),
                                egui::pos2(mark_center.x - 22.0, mark_center.y + 3.0),
                            ],
                            alpha(theme::SPLASH_INK, 0.22 * opacity),
                            Stroke::new(1.0_f32, alpha(Color32::WHITE, 0.40 * opacity)),
                        ));
                        painter.line_segment(
                            [egui::pos2(mark_center.x - 34.0, mark_center.y + 15.0), egui::pos2(mark_center.x + 5.0, mark_center.y - 32.0)],
                            Stroke::new(3.0_f32, alpha(Color32::WHITE, 0.82 * opacity)),
                        );
                        painter.line_segment(
                            [egui::pos2(mark_center.x + 5.0, mark_center.y - 32.0), egui::pos2(mark_center.x + 32.0, mark_center.y + 4.0)],
                            Stroke::new(2.0_f32, alpha(theme::SPLASH_INK, 0.75 * opacity)),
                        );
                        painter.circle_filled(egui::pos2(mark_center.x + 53.0, mark_center.y - 40.0), 4.0, alpha(Color32::WHITE, 0.9 * opacity));

                        let title_at = center + Vec2::new(0.0, -14.0 + lift);
'@
$gui = Replace-Once $gui $oldMark $newMark "replace circle P mark with prism"
$gui = Replace-Once $gui 'egui::FontId::new(30.0, theme::wordmark_font()),' 'egui::FontId::new(34.0, theme::wordmark_font()),' "intro wordmark size"
$gui = Replace-Once $gui '"YOUR ROBLOX ASSET WORKSPACE",' '"CREATIVE CONTROL CENTER  ·  BUILT FOR RIVALS",' "intro tagline"
$gui = Replace-Once $gui 'let chip_labels = ["SKY LIBRARY", "CONFIG BUILDER", "CACHE CONTROL"];' 'let chip_labels = ["CONFIG LIBRARY", "SKINCHANGER", "NO HANDS"];' "intro feature chips"

# Attach the corresponding front.png preview URL to every sky JSON profile.
$skyDirectory = Join-Path $Project "sky_profiles"
foreach ($skyFile in Get-ChildItem -LiteralPath $skyDirectory -File -Filter "*.json") {
    $document = Get-Content -LiteralPath $skyFile.FullName -Raw | ConvertFrom-Json
    $skyName = [string]$document.sky_library.name
    if ($skyName -eq "Purple goo sky") {
        $previewUrl = "https://raw.githubusercontent.com/Prlngzz/Prlngzz-Textures/main/PurpleFlowFront.png"
    } else {
        $slug = $skyName.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
        $slug = $slug.Trim('-')
        $previewUrl = "https://media.githubusercontent.com/media/Prlngzz/Prlngzz-Editor/sky-library-cdn-assets/.github/assets/sky-faces/$slug/front.png"
    }
    $document.sky_library | Add-Member -NotePropertyName preview_url -NotePropertyValue $previewUrl -Force
    [IO.File]::WriteAllText($skyFile.FullName, ($document | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

$gui = Replace-Once $gui @'
    available_faces: usize,
    json: &'static str,
'@ @'
    available_faces: usize,
    preview_url: String,
    json: &'static str,
'@ "sky preview URL field"
$gui = Replace-Once $gui @'
            let available_faces = metadata.get("available_faces").and_then(serde_json::Value::as_u64).unwrap_or(0) as usize;
            let faces = value.get("faces").and_then(serde_json::Value::as_object)
'@ @'
            let available_faces = metadata.get("available_faces").and_then(serde_json::Value::as_u64).unwrap_or(0) as usize;
            let preview_url = metadata.get("preview_url").and_then(serde_json::Value::as_str).unwrap_or("").to_owned();
            let faces = value.get("faces").and_then(serde_json::Value::as_object)
'@ "read sky preview URL"
$gui = Replace-Once $gui 'SkyLibraryEntry { name, archive, status, available_faces, json, faces }' 'SkyLibraryEntry { name, archive, status, available_faces, preview_url, json, faces }' "construct sky preview entry"
$gui = Replace-Once $gui @'
                                ui.label(egui::RichText::new("RIVALS · SIX-FACE SKYBOX")
                                    .color(theme::MUTED).small());
                                ui.add_space(6.0);
'@ @'
                                ui.label(egui::RichText::new("RIVALS · SIX-FACE SKYBOX")
                                    .color(theme::MUTED).small());
                                if !entry.preview_url.is_empty() {
                                    ui.hyperlink_to("Preview front.png", entry.preview_url.as_str());
                                }
                                ui.add_space(6.0);
'@ "front.png preview link"

# Match old profiles by target asset IDs and create a No Hands cache-removal config.
$helpers = @'
fn profile_rule_target_asset_ids(rule: &serde_json::Value) -> HashSet<u64> {
    let mut ids = HashSet::new();
    for field in ["replace_ids", "target_ids", "asset_ids", "targets"] {
        if let Some(values) = rule.get(field).and_then(serde_json::Value::as_array) {
            for value in values {
                let id = value.as_u64().or_else(|| value.as_str().and_then(|s| s.trim().parse::<u64>().ok()));
                if let Some(id) = id { if id > 0 { ids.insert(id); } }
            }
        }
    }
    ids
}
fn profile_target_asset_ids(document: &serde_json::Value) -> HashSet<u64> {
    let rules = document.get("replacement_rules").or_else(|| document.get("rules"))
        .and_then(serde_json::Value::as_array);
    let mut ids = HashSet::new();
    if let Some(rules) = rules { for rule in rules { ids.extend(profile_rule_target_asset_ids(rule)); } }
    ids
}
fn build_no_hands_cache_profile(raw: &str) -> anyhow::Result<crate::studio::ProfileDocument> {
    let mut ids = crate::studio::extract_asset_ids(raw);
    ids.sort_unstable();
    ids.dedup();
    anyhow::ensure!(!ids.is_empty(), "Paste exact arm asset IDs first");
    let mut profile = crate::studio::ProfileDocument::new("No Hands Cache Profile", "RIVALS");
    for id in ids { profile.add_named_remove_rule(&format!("No Hands · {id}"), id)?; }
    let validation = profile.validation();
    anyhow::ensure!(validation.errors.is_empty(), "No Hands profile validation failed: {}", validation.errors.join("; "));
    anyhow::ensure!(validation.enabled_rules > 0, "No Hands profile has no enabled rules");
    Ok(profile)
}

'@
$gui = Replace-Once $gui 'impl Tab {' ($helpers + 'impl Tab {') "target matching and No Hands helper"

# Only force-enable the newly selected preset, not every saved profile.
$gui = Replace-Once $gui '    force_enable_pending_configs: bool,' '    force_enable_pending_configs: Option<PathBuf>,' "selected preset path field"
$gui = Replace-Once $gui '            force_enable_pending_configs: false,' '            force_enable_pending_configs: None,' "selected preset path initialization"
$gui = $gui.Replace('self.force_enable_pending_configs = false;', 'self.force_enable_pending_configs = None;')
$gui = Replace-Once $gui '        let force_enable = std::mem::take(&mut self.force_enable_pending_configs);' '        let force_enable_path = self.force_enable_pending_configs.take();' "take selected preset path"
$gui = Replace-Once $gui @'
                if force_enable {
                    config.off.clear();
                    config.enabled = true;
                } else {
                    config.enabled = loaded.enabled;
                }
'@ @'
                if force_enable_path.as_ref().is_some_and(|path| config::same_file(path, &config.path)) {
                    config.off.clear();
                    config.enabled = true;
                } else {
                    config.enabled = loaded.enabled;
                }
'@ "enable only selected preset"

# Disable every previously active profile which overlaps the new preset's target IDs.
$methodStart = $gui.IndexOf('    fn apply_generated_profile(&mut self, ctx: &egui::Context, profile: crate::studio::ProfileDocument) -> Result<String> {')
$methodEnd = $gui.IndexOf('    fn check_configs(&mut self, ctx: &egui::Context, paths: Vec<PathBuf>) -> Result<String> {', $methodStart)
if ($methodStart -lt 0 -or $methodEnd -le $methodStart) { throw "Could not isolate apply_generated_profile" }
$newApply = @'
    fn apply_generated_profile(&mut self, ctx: &egui::Context, profile: crate::studio::ProfileDocument) -> Result<String> {
        anyhow::ensure!(
            self.config_job.is_none() && self.apply_job.is_none() && self.pending_configs.is_none() && !self.confirm_configs,
            "Finish the current config operation before applying another library preset"
        );
        let validation = profile.validation();
        anyhow::ensure!(validation.errors.is_empty(), "The preset is invalid: {}", validation.errors.join("; "));
        anyhow::ensure!(validation.enabled_rules > 0, "The preset has no enabled replacement rules");
        let profile_name = profile.name().to_owned();
        let text = profile.to_fleasion_json()?;
        let document: serde_json::Value = serde_json::from_str(&text)?;
        let new_targets = profile_target_asset_ids(&document);
        anyhow::ensure!(!new_targets.is_empty(), "The preset has no asset-ID targets");

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

        let mut disabled = 0usize;
        for existing in &mut self.configs {
            if !existing.enabled || config::same_file(&existing.path, &path) { continue; }
            let Ok(raw) = std::fs::read_to_string(&existing.path) else { continue };
            let Ok(old_document) = serde_json::from_str::<serde_json::Value>(&raw) else { continue };
            let old_targets = profile_target_asset_ids(&old_document);
            if old_targets.iter().any(|id| new_targets.contains(id)) {
                existing.enabled = false;
                disabled += 1;
            }
        }
        if disabled > 0 { self.settings.save(); }

        let mut paths: Vec<PathBuf> = self.configs.iter().map(|config| config.path.clone()).collect();
        if !paths.iter().any(|old| config::same_file(old, &path)) { paths.push(path.clone()); }
        self.auto_accept_configs = true;
        self.force_enable_pending_configs = Some(path.clone());
        if let Err(error) = self.check_configs(ctx, paths) {
            self.auto_accept_configs = false;
            self.force_enable_pending_configs = None;
            return Err(error);
        }
        Ok(format!("Preparing {profile_name}. Switched off {disabled} previously active conflicting profile(s); the cache apply result will also be notified."))
    }

'@
$gui = $gui.Substring(0, $methodStart) + $newApply + $gui.Substring($methodEnd)

# Regression tests for profile target matching, No Hands and sky preview metadata.
$gui = Replace-Once $gui @'
    #[test]
    fn all_individual_sky_json_profiles_use_six_multi_id_cdn_rules() {
'@ @'
    #[test]
    fn profile_target_extraction_handles_numeric_and_string_ids() {
        let document: serde_json::Value = serde_json::from_str(
            r#"{"replacement_rules":[{"replace_ids":[123,"456"]}]}"#
        ).unwrap();
        let targets = profile_target_asset_ids(&document);
        assert_eq!(targets.len(), 2);
        assert!(targets.contains(&123) && targets.contains(&456));
    }

    #[test]
    fn no_hands_cache_profile_builds_remove_rules_for_unique_ids() {
        let profile = build_no_hands_cache_profile("123 456, 123").unwrap();
        let validation = profile.validation();
        assert!(validation.errors.is_empty());
        assert_eq!(validation.enabled_rules, 2);
    }

    #[test]
    fn all_individual_sky_json_profiles_use_six_multi_id_cdn_rules() {
'@ "profile and No Hands regression tests"
$gui = Replace-Once $gui @'
            if sky.status == "ready" {
                applyable += 1;
'@ @'
            assert!(sky.preview_url.ends_with("/front.png") || sky.preview_url.ends_with("PurpleFlowFront.png"),
                "{} must have its front preview URL", sky.name);
            if sky.status == "ready" {
                applyable += 1;
'@ "front preview assertion"

# Add seven accent palettes and four one-tap customization presets.
$themePath = Join-Path $Project "src/theme.rs"
$theme = [IO.File]::ReadAllText($themePath)
$theme = Replace-Once $theme @'
        "amber" => 0xE8B65D,
        "mint" => 0x65D6A6,
        "orange" => 0xFF965C,
        "indigo" => 0x8394FF,
        _ => 0xA970FF,
'@ @'
        "amber" => 0xE8B65D,
        "mint" => 0x65D6A6,
        "orange" => 0xFF965C,
        "indigo" => 0x8394FF,
        "crimson" => 0xFF5F7E,
        "teal" => 0x4ED0C0,
        "gold" => 0xEAC15E,
        "ice" => 0x70C9FF,
        "lime" => 0xA4DF70,
        "fuchsia" => 0xE47CFF,
        "slate" => 0x8DA4C4,
        _ => 0xA970FF,
'@ "new accent palette"
Save-Source $themePath $theme
$extraLabels = @'
                    "crimson" => "Crimson red",
                    "teal" => "Lagoon teal",
                    "gold" => "Champagne gold",
                    "ice" => "Ice blue",
                    "lime" => "Electric lime",
                    "fuchsia" => "Fuchsia",
                    "slate" => "Slate blue",
'@
$gui = Replace-Once $gui '                    "indigo" => "Indigo",' ('                    "indigo" => "Indigo",' + [Environment]::NewLine + $extraLabels.TrimEnd()) "palette labels"
$extraChoices = @'
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "crimson".into(), "Crimson red").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "teal".into(), "Lagoon teal").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "gold".into(), "Champagne gold").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "ice".into(), "Ice blue").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "lime".into(), "Electric lime").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "fuchsia".into(), "Fuchsia").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "slate".into(), "Slate blue").changed();
'@
$gui = Replace-Once $gui '                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "indigo".into(), "Indigo").changed();' ('                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "indigo".into(), "Indigo").changed();' + [Environment]::NewLine + $extraChoices.TrimEnd()) "palette choices"
$customAnchor = @'
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("Live preview").color(theme::MUTED));
'@
$presets = @'
            ui.label(egui::RichText::new("ONE-TAP LOOKS").strong().color(theme::MUTED).small());
            ui.horizontal_wrapped(|ui| {
                if bubbly_small_button(ui, "Aurora").clicked() {
                    self.settings.accent = "teal".into(); self.settings.compact_layout = false;
                    self.settings.animations = true; self.settings.animated_glow = true;
                    accent_changed = true; density_changed = true; preferences_changed = true;
                }
                if bubbly_small_button(ui, "Royal").clicked() {
                    self.settings.accent = "violet".into(); self.settings.compact_layout = false;
                    self.settings.animations = true; self.settings.animated_glow = true;
                    accent_changed = true; density_changed = true; preferences_changed = true;
                }
                if bubbly_small_button(ui, "Ember").clicked() {
                    self.settings.accent = "crimson".into(); self.settings.compact_layout = false;
                    self.settings.animations = true; self.settings.animated_glow = false;
                    accent_changed = true; density_changed = true; preferences_changed = true;
                }
                if bubbly_small_button(ui, "Minimal").clicked() {
                    self.settings.accent = "slate".into(); self.settings.compact_layout = true;
                    self.settings.animations = false; self.settings.animated_glow = false;
                    accent_changed = true; density_changed = true; preferences_changed = true;
                }
            });
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("Live preview").color(theme::MUTED));
'@
$gui = Replace-Once $gui $customAnchor $presets "one-tap appearance presets"
Save-Source $guiPath $gui
Write-Host "Applied v0.3.34 Config Library overhaul, sky previews, profile hand-off, No Hands cache removal and customization."
