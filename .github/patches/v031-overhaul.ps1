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
$textureBlock += @'
        }
'@
$librarySource = Replace-Once $librarySource $libraryAnchor ($libraryAnchor + [Environment]::NewLine + $textureBlock) "Textures tab presets and No Hands card"
$gui = $gui.Substring(0, $libraryStartAt) + $librarySource + $gui.Substring($libraryEndAt)
# Move the collection tabs/search above the gallery and keep Skies outside Textures.
$libraryMethodStart = $gui.IndexOf('    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {')
$libraryMethodEnd = $gui.IndexOf('    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {', $libraryMethodStart)
$navLabelMarker = 'ui.label(egui::RichText::new("ASSET LIBRARY").strong());'
$navLabelAt = $gui.IndexOf($navLabelMarker, $libraryMethodStart)
$navStartAt = $gui.LastIndexOf('        ui.horizontal(|ui| {', $navLabelAt)
$navEndMarker = '        ui.label(egui::RichText::new(tab_description).color(theme::MUTED).small());'
$navEndAt = $gui.IndexOf($navEndMarker, $navStartAt)
if ($libraryMethodStart -lt 0 -or $libraryMethodEnd -le $libraryMethodStart -or $navLabelAt -lt 0 -or $navStartAt -lt $libraryMethodStart -or $navEndAt -lt $navStartAt) {
    throw "Could not locate Config Library navigation block"
}
$navEnd = $navEndAt + $navEndMarker.Length
$libraryNav = $gui.Substring($navStartAt, $navEnd - $navStartAt)
$gui = $gui.Remove($navStartAt, $navEnd - $navStartAt)
$assetAnchor = '        let assets = rivals_asset_catalog();'
$assetAt = $gui.IndexOf($assetAnchor, $libraryMethodStart)
if ($assetAt -lt 0 -or $assetAt -ge $libraryMethodEnd) { throw "Could not locate Config Library catalogue declaration" }
$gui = $gui.Insert($assetAt + $assetAnchor.Length, [string][char]10 + $libraryNav)
$gui = Replace-Once $gui 'LibraryTab::Skies => "66 individual six-face sky configurations."' 'LibraryTab::Skies => "66 sky profiles · 63 ready to apply."' "update sky description"

$oldTextureFilter = @'
            let visible = match self.library_tab {
                LibraryTab::All => category != Some("Community skybox"),
                LibraryTab::Skies => false,
                LibraryTab::Textures => category == Some("Weapon icon") || category == Some("RIVALS map sky texture"),
                LibraryTab::Sounds => category == Some("Community sound"),
            };
'@
$newTextureFilter = @'
            let visible = match self.library_tab {
                LibraryTab::All => category != Some("Community skybox"),
                LibraryTab::Skies => false,
                // Blue, Station and Space are available in Skies, not as duplicate texture rows.
                LibraryTab::Textures => category == Some("Weapon icon") || (
                    category == Some("RIVALS map sky texture")
                        && !matches!(
                            asset.get("id").and_then(serde_json::Value::as_str),
                            Some("14147882761" | "2108482231" | "10196550367")
                        )
                ),
                LibraryTab::Sounds => category == Some("Community sound"),
            };
'@
$gui = Replace-Once $gui $oldTextureFilter $newTextureFilter "remove duplicate sky rows from Textures"

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

# Full-screen app intro: keep the P wordmark and orbit rotating material swatches around it.
$gui = Replace-Once $gui '            let duration = 4.0_f32;' '            let duration = 4.8_f32;' "intro duration"
$introStartAt = $gui.IndexOf('                egui::Area::new(egui::Id::new("prlngzz-startup-intro"))')
$introEndMarker = '                    });' + [string][char]10 + '                ctx.request_repaint_after(std::time::Duration::from_millis(16));'
$introEndAt = $gui.IndexOf($introEndMarker, $introStartAt)
if ($introStartAt -lt 0 -or $introEndAt -le $introStartAt) { throw "Could not isolate startup intro draw area" }
$newIntro = @'
                egui::Area::new(egui::Id::new("prlngzz-startup-intro"))
                    .order(egui::Order::Foreground)
                    .fixed_pos(rect.min)
                    .show(ctx, |ui| {
                        ui.set_min_size(rect.size());
                        let (surface, _) = ui.allocate_exact_size(rect.size(), egui::Sense::hover());
                        let painter = ui.painter_at(surface);
                        theme::splash_gradient(&painter, surface, 0.985 * opacity);
                        let center = surface.center();
                        let shortest = surface.width().min(surface.height());
                        for i in 0..24 {
                            let x = ((i * 73 + 19) % 997) as f32 / 997.0;
                            let y = ((i * 151 + 47) % 991) as f32 / 991.0;
                            let twinkle = 0.10 + 0.16 * (((elapsed * 1.25 + i as f32).sin() + 1.0) * 0.5);
                            let point = egui::pos2(surface.left() + x * surface.width(), surface.top() + y * surface.height());
                            painter.circle_filled(point, 0.8 + (i % 3) as f32 * 0.3, alpha(theme::SPLASH_INK, twinkle * opacity));
                        }
                        painter.circle_stroke(center, shortest * 0.27, Stroke::new(1.0_f32, alpha(theme::accent(), 0.12 * opacity)));
                        painter.circle_stroke(center, shortest * 0.39, Stroke::new(1.0_f32, alpha(theme::SPLASH_INK, 0.075 * opacity)));
                        let labels = ["SKY", "TEXTURE", "PNG", "MATERIAL", "ASSET", "MESH", "CACHE", "RIVALS"];
                        for index in 0..16 {
                            let lane = (index % 4) as f32;
                            let direction = if index % 2 == 0 { 1.0 } else { -1.0 };
                            let angle = elapsed * (0.24 + lane * 0.055) * direction + index as f32 * std::f32::consts::TAU / 16.0;
                            let rx = surface.width() * (0.20 + lane * 0.065);
                            let ry = surface.height() * (0.19 + lane * 0.065);
                            let position = center + Vec2::new(rx * angle.cos(), ry * angle.sin());
                            let spin = elapsed * (0.30 + lane * 0.12) * direction + index as f32 * 0.31;
                            let (sin, cos) = spin.sin_cos();
                            let rotate = |point: Vec2| Vec2::new(point.x * cos - point.y * sin, point.x * sin + point.y * cos);
                            let size = Vec2::new(62.0 + (index % 3) as f32 * 9.0, 43.0 + (index % 2) as f32 * 7.0);
                            let half = size * 0.5;
                            let corners = vec![
                                position + rotate(Vec2::new(-half.x, -half.y)),
                                position + rotate(Vec2::new(half.x, -half.y)),
                                position + rotate(Vec2::new(half.x, half.y)),
                                position + rotate(Vec2::new(-half.x, half.y)),
                            ];
                            let previous = center + Vec2::new(rx * (angle - direction * 0.075).cos(), ry * (angle - direction * 0.075).sin());
                            painter.line_segment([previous, position], Stroke::new(1.2_f32, alpha(theme::accent(), 0.10 * opacity)));
                            painter.add(egui::Shape::convex_polygon(corners, alpha(theme::CARD, 0.72 * opacity), Stroke::new(1.0_f32, alpha(theme::accent(), 0.34 * opacity))));
                            painter.add(egui::Shape::convex_polygon(
                                vec![
                                    position + rotate(Vec2::new(-half.x + 5.0, -half.y + 5.0)),
                                    position + rotate(Vec2::new(half.x - 5.0, -half.y + 5.0)),
                                    position + rotate(Vec2::new(half.x - 5.0, half.y - 5.0)),
                                    position + rotate(Vec2::new(-half.x + 5.0, half.y - 5.0)),
                                ],
                                alpha(theme::RAISED, 0.58 * opacity), Stroke::NONE,
                            ));
                            for stripe in 0..3 {
                                let offset = -half.y * 0.30 + stripe as f32 * 8.0;
                                let from = position + rotate(Vec2::new(-half.x * 0.58, offset));
                                let to = position + rotate(Vec2::new(half.x * 0.58, offset));
                                painter.line_segment([from, to], Stroke::new(2.0_f32, alpha(theme::accent(), (0.22 + stripe as f32 * 0.06) * opacity)));
                            }
                            painter.text(position + rotate(Vec2::new(0.0, half.y * 0.20)), egui::Align2::CENTER_CENTER,
                                labels[index % labels.len()], egui::FontId::proportional(7.5), alpha(theme::SPLASH_INK, 0.88 * opacity));
                        }
                        let pulse = 1.0 + 0.018 * (elapsed * 1.8).sin();
                        painter.circle_filled(center, 88.0 * pulse, alpha(theme::accent(), 0.10 * opacity));
                        painter.circle_stroke(center, 76.0 * pulse, Stroke::new(1.2_f32, alpha(theme::accent(), 0.50 * opacity)));
                        painter.circle_stroke(center, 91.0 * pulse, Stroke::new(1.0_f32, alpha(theme::SPLASH_INK, 0.18 * opacity)));
                        for i in 0..4 {
                            let angle = elapsed * (0.38 + i as f32 * 0.07) + i as f32 * std::f32::consts::FRAC_PI_2;
                            let radius = 84.0 + i as f32 * 3.0;
                            painter.circle_filled(center + Vec2::new(angle.cos(), angle.sin()) * radius, 2.1 + (i % 2) as f32, alpha(theme::accent(), 0.95 * opacity));
                        }
                        painter.text(center + Vec2::new(0.0, 4.0), egui::Align2::CENTER_CENTER, "P",
                            egui::FontId::new(148.0 * pulse, theme::wordmark_font()), alpha(theme::accent(), 0.56 * opacity));
                        painter.text(center, egui::Align2::CENTER_CENTER, "P",
                            egui::FontId::new(148.0 * pulse, theme::wordmark_font()), alpha(theme::SPLASH_INK, opacity));
                        painter.text(center + Vec2::new(0.0, 112.0), egui::Align2::CENTER_CENTER, "PRLNGZZ EDITOR",
                            egui::FontId::new(25.0, theme::wordmark_font()), alpha(theme::SPLASH_INK, opacity));
                        painter.text(center + Vec2::new(0.0, 139.0), egui::Align2::CENTER_CENTER, "ASSET  ·  CONFIG  ·  WORKSPACE",
                            egui::FontId::proportional(10.5), alpha(theme::SPLASH_MUTED, opacity));
                        let version = format!("v{}  ·  BUILT FOR YOUR WORKFLOW", update::CURRENT);
                        painter.text(egui::pos2(center.x, surface.bottom() - 48.0), egui::Align2::CENTER_CENTER, version,
                            egui::FontId::proportional(9.5), alpha(theme::SPLASH_MUTED, opacity));
                        let width = (surface.width() * 0.24).clamp(190.0, 360.0);
                        let bar = Rect::from_center_size(egui::pos2(center.x, surface.bottom() - 28.0), Vec2::new(width, 2.5));
                        painter.rect_filled(bar, CornerRadius::same(2), alpha(theme::BORDER, opacity));
                        painter.rect_filled(Rect::from_min_size(bar.min, Vec2::new(width * t, bar.height())),
                            CornerRadius::same(2), alpha(theme::SPLASH_BAR, opacity));
                    });
'@
$gui = $gui.Substring(0, $introStartAt) + $newIntro + $gui.Substring($introEndAt + ('                    });').Length)
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
        $previewUrl = "https://raw.githubusercontent.com/Prlngzz/Prlngzz-Editor/sky-library-cdn-assets/.github/assets/sky-faces/$slug/front.png"
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
            if sky.name != "Purple goo sky" {
                assert!(sky.preview_url.starts_with("https://raw.githubusercontent.com/Prlngzz/Prlngzz-Editor/sky-library-cdn-assets/"),
                    "{} must use a direct public preview URL", sky.name);
            }
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
# Asynchronous remote thumbnails for Skies and community texture galleries.
$gui = Replace-Once $gui '    lookup_pictures: HashMap<u64, egui::TextureHandle>,' @'
    lookup_pictures: HashMap<u64, egui::TextureHandle>,
    image_previews: HashMap<String, egui::TextureHandle>,
    image_preview_jobs: HashSet<String>,
    image_preview_failed: HashSet<String>,
    image_preview_tx: std::sync::mpsc::Sender<(String, std::result::Result<Vec<u8>, String>)>,
    image_preview_rx: Receiver<(String, std::result::Result<Vec<u8>, String>)>,
'@ "preview state"

$gui = Replace-Once $gui '        let settings = Settings::load();' @'
        let (image_preview_tx, image_preview_rx) = channel();
        let settings = Settings::load();
'@ "preview channel"
$gui = Replace-Once $gui '            lookup_pictures: HashMap::new(),' @'
            lookup_pictures: HashMap::new(),
            image_previews: HashMap::new(),
            image_preview_jobs: HashSet::new(),
            image_preview_failed: HashSet::new(),
            image_preview_tx,
            image_preview_rx,
'@ "preview init"
$gui = Replace-Once $gui '        self.poll_lookup(ctx);' @'
        self.poll_lookup(ctx);
        self.poll_image_previews(ctx);
'@ "poll preview responses"

$previewMethods = @'
    fn request_image_preview(&mut self, ctx: &egui::Context, url: &str) {
        if !url.starts_with("https://")
            || self.image_previews.contains_key(url)
            || self.image_preview_jobs.contains(url)
            || self.image_preview_failed.contains(url)
        {
            return;
        }
        let url = url.to_owned();
        self.image_preview_jobs.insert(url.clone());
        let tx = self.image_preview_tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            use std::io::Read;
            const MAX_PREVIEW_BYTES: u64 = 8 * 1024 * 1024;
            let result = (|| -> std::result::Result<Vec<u8>, String> {
                let response = ureq::get(&url)
                    .set("User-Agent", "Prlngzz-Editor/0.3.37")
                    .timeout(std::time::Duration::from_secs(15))
                    .call()
                    .map_err(|error| format!("Preview request failed: {error}"))?;
                let mut reader = response.into_reader().take(MAX_PREVIEW_BYTES + 1);
                let mut bytes = Vec::new();
                reader.read_to_end(&mut bytes).map_err(|error| format!("Preview download failed: {error}"))?;
                if bytes.len() as u64 > MAX_PREVIEW_BYTES {
                    return Err("Preview image is larger than 8 MiB".to_owned());
                }
                Ok(bytes)
            })();
            let _ = tx.send((url, result));
            ctx.request_repaint();
        });
    }

    fn poll_image_previews(&mut self, ctx: &egui::Context) {
        loop {
            let (url, result) = match self.image_preview_rx.try_recv() {
                Ok(message) => message,
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
            };
            self.image_preview_jobs.remove(&url);
            match result {
                Ok(bytes) => match image::load_from_memory(&bytes) {
                    Ok(image) => {
                        let small = image.thumbnail(480, 270).to_rgba8();
                        let pixels = egui::ColorImage::from_rgba_unmultiplied(
                            [small.width() as usize, small.height() as usize],
                            small.as_raw(),
                        );
                        let name = format!("library-preview-{}", self.image_previews.len());
                        let texture = ctx.load_texture(name, pixels, egui::TextureOptions::LINEAR);
                        self.image_previews.insert(url, texture);
                    }
                    Err(_) => { self.image_preview_failed.insert(url); }
                },
                Err(_) => { self.image_preview_failed.insert(url); }
            }
        }
    }

'@
$gui = Replace-Once $gui '    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {' ($previewMethods + '    fn asset_library_page(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {') "preview worker methods"

$gui = Replace-Once $gui @'
                            for (index, entry) in visible_skies.iter().enumerate() {
                                let column = &mut columns[index % 3];
                                column.push_id(("sky-library-card", &entry.name), |ui| {
'@ @'
                            for (index, entry) in visible_skies.iter().enumerate() {
                                let column = &mut columns[index % 3];
                                let preview_url = entry.preview_url.clone();
                                let preview_rect = Rect::from_min_size(column.cursor().min, Vec2::new(column.available_width().max(100.0), 132.0));
                                if column.is_rect_visible(preview_rect) { self.request_image_preview(column.ctx(), &preview_url); }
                                let preview_texture = self.image_previews.get(&preview_url).cloned();
                                let preview_failed = self.image_preview_failed.contains(&preview_url);
                                column.push_id(("sky-library-card", &entry.name), |ui| {
'@ "fetch visible sky thumbnails"
$gui = Replace-Once $gui @'
                                        if !entry.preview_url.is_empty() {
                                            ui.hyperlink_to("Preview front.png", entry.preview_url.as_str());
                                        }
                                        ui.add_space(6.0);
'@ @'
                                        if let Some(texture) = preview_texture.as_ref() {
                                            let size = texture.size_vec2();
                                            let scale = (ui.available_width() / size.x.max(1.0)).min(132.0 / size.y.max(1.0)).min(1.0);
                                            ui.image((texture.id(), size * scale));
                                        } else if preview_failed {
                                            ui.label(egui::RichText::new("Preview unavailable").color(theme::WARN).small());
                                        } else if !preview_url.is_empty() {
                                            ui.label(egui::RichText::new("Loading front preview…").color(theme::MUTED).small());
                                        }
                                        if !preview_url.is_empty() { ui.hyperlink_to("Open full-size image", preview_url.as_str()); }
                                        ui.add_space(6.0);
'@ "draw sky image previews"

$gui = Replace-Once $gui @'
                            for (index, entry) in visible_textures.iter().enumerate() {
                                let column = &mut columns[index % 3];
                                column.push_id(("texture-library-card", &entry.name), |ui| {
'@ @'
                            for (index, entry) in visible_textures.iter().enumerate() {
                                let column = &mut columns[index % 3];
                                let preview_url = entry.preview_url.clone();
                                let preview_rect = Rect::from_min_size(column.cursor().min, Vec2::new(column.available_width().max(100.0), 132.0));
                                if column.is_rect_visible(preview_rect) { self.request_image_preview(column.ctx(), &preview_url); }
                                let preview_texture = self.image_previews.get(&preview_url).cloned();
                                let preview_failed = self.image_preview_failed.contains(&preview_url);
                                column.push_id(("texture-library-card", &entry.name), |ui| {
'@ "fetch visible texture thumbnails"
$gui = Replace-Once $gui @'
                                        ui.add_space(6.0);
                                        ui.hyperlink_to("Open image preview", entry.preview_url.as_str());
                                        ui.add_space(6.0);
'@ @'
                                        ui.add_space(6.0);
                                        if let Some(texture) = preview_texture.as_ref() {
                                            let size = texture.size_vec2();
                                            let scale = (ui.available_width() / size.x.max(1.0)).min(132.0 / size.y.max(1.0)).min(1.0);
                                            ui.image((texture.id(), size * scale));
                                        } else if preview_failed {
                                            ui.label(egui::RichText::new("Preview unavailable").color(theme::WARN).small());
                                        } else if !preview_url.is_empty() {
                                            ui.label(egui::RichText::new("Loading texture preview…").color(theme::MUTED).small());
                                        }
                                        ui.hyperlink_to("Open full-size image", preview_url.as_str());
                                        ui.add_space(6.0);
'@ "draw texture image previews"

Save-Source $guiPath $gui
Write-Host "Applied v0.3.37 Config Library overhaul, sky previews, profile hand-off, No Hands cache removal and customization."
