param([Parameter(Mandatory=$true)][string]$Project)
$ErrorActionPreference = "Stop"

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$What) {
    # ZIP archives can contain CRLF while GitHub-authored patch scripts use LF.
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($count -ne 1) { throw "Expected exactly one '$What' source block; found $count" }
    return $Text.Replace($Old, $New)
}
function Replace-RegexOnce([string]$Text, [string]$Pattern, [string]$New, [string]$What) {
    $count = [regex]::Matches($Text, $Pattern).Count
    if ($count -ne 1) { throw "Expected exactly one '$What' source match; found $count" }
    return [regex]::Replace($Text, $Pattern, $New)
}
function Remove-RustMatchArm([string]$Text, [string]$StartPattern, [string]$What) {
    $Text = $Text.Replace(([string][char]13 + [char]10), [string][char]10)
    $hits = [regex]::Matches($Text, $StartPattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($hits.Count -lt 1) { throw "Could not find a '$What' match arm to remove" }
    $start = $Text.LastIndexOf([char]10, $hits[0].Index)
    if ($start -lt 0) { $start = 0 } else { $start++ }
    $lineEnd = $Text.IndexOf([char]10, $hits[0].Index)
    if ($lineEnd -lt 0) { $lineEnd = $Text.Length }
    $line = $Text.Substring($start, $lineEnd - $start)
    $indent = [regex]::Match($line, '^\s*').Value
    $closePattern = '(?m)^' + [regex]::Escape($indent) + '\},?[ \t]*$'
    $tail = $Text.Substring($lineEnd)
    $closing = [regex]::Match($tail, $closePattern)
    if (!$closing.Success) { throw "Could not find the end of '$What' match arm" }
    $end = $lineEnd + $closing.Index + $closing.Length
    if ($end -lt $Text.Length -and $Text[$end] -eq [char]10) { $end++ }
    return $Text.Remove($start, $end - $start)
}
function Remove-RustMatchArms([string]$Text, [string]$StartPattern, [string]$What) {
    while ([regex]::Matches($Text, $StartPattern, [Text.RegularExpressions.RegexOptions]::Multiline).Count -gt 0) {
        $Text = Remove-RustMatchArm $Text $StartPattern $What
    }
    return $Text
}
function Save-Source([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# Install the static OBJ -> Roblox FileMesh importer from this repository.
$mainPath = Join-Path $Project "src/main.rs"
$main = [IO.File]::ReadAllText($mainPath)
if (!$main.Contains("mod obj;")) {
    $main = Replace-Once $main "mod originals;" ("mod obj;" + [char]10 + "mod originals;") "OBJ module declaration"
}
$main = Replace-Once $main "mod packs;" "" "Game Library module declaration"
Save-Source $mainPath $main
Copy-Item -LiteralPath (Join-Path $env:GITHUB_WORKSPACE ".github/patches/obj.rs") -Destination (Join-Path $Project "src/obj.rs") -Force

# Retain the compiler fixes needed by the uploaded source snapshot.
$studioPath = Join-Path $Project "src/studio.rs"
$studioSource = [IO.File]::ReadAllText($studioPath)
$studioSource = $studioSource.Replace("let children =", "let children: Vec<Value> =")
foreach ($field in @("asset_id", "path", "url", "type")) {
    $old = '.pointer("/action/' + $field + '")'
    $new = '.get("action").and_then(Value::as_object).and_then(|action| action.get("' + $field + '"))'
    $studioSource = $studioSource.Replace($old, $new)
}
$oldUnknownAction = @'
            Some(other) => report.errors.push(format!("Rule {} has an incomplete or unknown action '{other}'", object.get("name").and_then(Value::as_str).unwrap_or("(unnamed)"))),
'@
$newUnknownAction = @'
            Some(other) => {
                let message = format!("Rule {} has an incomplete or unknown action '{other}'", object.get("name").and_then(Value::as_str).unwrap_or("(unnamed)"));
                report.warnings.push(message.clone());
                report.errors.push(message);
            }
'@
$studioSource = Replace-Once $studioSource $oldUnknownAction $newUnknownAction "unknown actions reported as warnings and errors"
Save-Source $studioPath $studioSource

# Fit personal OBJ files to a Roblox FileMesh target instead of writing OBJ text into the cache.
$configPath = Join-Path $Project "src/config.rs"
$config = [IO.File]::ReadAllText($configPath)
$config = Replace-Once $config '        let foreign = self.bytes.is_empty() || format::sniff(&self.bytes) == "ktx2";' '' "unconditional image replacement decoding"
$config = Replace-Once $config '            ("png" | "jpeg" | "gif" | "webp", _) if foreign =>' '            ("png" | "jpeg" | "gif" | "webp", _) =>' "transcode all image replacements"
$fitAnchor = '    /// True when `current` already is what [`Payload::fit`] would store.'
$fitChecked = @'
    /// Fits a config payload and converts personal Wavefront OBJ files to Roblox mesh data.
    fn fit_checked(&self, kind: &str, current: &[u8]) -> Result<Cow<'_, [u8]>> {
        if kind == "mesh" && crate::obj::looks_like_obj(&self.bytes) {
            return crate::obj::to_roblox_mesh(&self.bytes)
                .map(Cow::Owned)
                .context("converting personal Wavefront OBJ file to Roblox FileMesh");
        }
        Ok(self.fit(kind, current))
    }

'@
$config = Replace-Once $config $fitAnchor ($fitChecked + $fitAnchor) "checked OBJ fitting"
$oldHeld = @'
    fn held_by(&self, kind: &str, current: &[u8]) -> bool {
        if kind == "ktx2" {
            if let (Some(pack), Some(image)) = (Pack::parse(current), self.image()) {
                return <[u8; 16]>::from(Md5::digest(current)) == texture::refit_digest(&pack, &self.digest, image);
            }
        }
        current == &*self.fit(kind, current)
    }
'@
$newHeld = @'
    fn held_by(&self, kind: &str, current: &[u8]) -> bool {
        if kind == "ktx2" {
            if let (Some(pack), Some(image)) = (Pack::parse(current), self.image()) {
                return <[u8; 16]>::from(Md5::digest(current)) == texture::refit_digest(&pack, &self.digest, image);
            }
        }
        current == &*self.fit(kind, current)
    }

    /// Checked variant used by actual replacement writes so malformed OBJ files are reported.
    fn held_by_checked(&self, kind: &str, current: &[u8]) -> Result<bool> {
        if kind == "ktx2" {
            if let (Some(pack), Some(image)) = (Pack::parse(current), self.image()) {
                return Ok(<[u8; 16]>::from(Md5::digest(current)) == texture::refit_digest(&pack, &self.digest, image));
            }
        }
        Ok(current == &*self.fit_checked(kind, current)?)
    }
'@
$config = Replace-Once $config $oldHeld $newHeld "checked replacement ownership"
$config = Replace-Once $config 'let body = payload.fit(kind, &store.read_body(&target)?).into_owned();' 'let body = payload.fit_checked(kind, &store.read_body(&target)?)?.into_owned();' "manual replacement fitting"
$oldHeldCall = @'
                    match store.read_body(&entries[i].id) {
                        Ok(current) if payload.held_by(entries[i].kind, &current) => {}
                        Ok(_) => plan.writes.push(i),
                        Err(e) => plan.report.notes.push(format!("{}: {e:#}", entries[i].id_hex)),
                    }
'@
$newHeldCall = @'
                    match store.read_body(&entries[i].id) {
                        Ok(current) => match payload.held_by_checked(entries[i].kind, &current) {
                            Ok(true) => {}
                            Ok(false) => plan.writes.push(i),
                            Err(e) => plan.report.notes.push(format!("{}: {e:#}", entries[i].id_hex)),
                        },
                        Err(e) => plan.report.notes.push(format!("{}: {e:#}", entries[i].id_hex)),
                    }
'@
$config = Replace-Once $config $oldHeldCall $newHeldCall "replacement plan payload check"
$config = Replace-Once $config 'let fitted = payload.fit(entries[i].kind, &current);' 'let fitted = payload.fit_checked(entries[i].kind, &current)?;' "replacement write fitting"
$config = Replace-RegexOnce $config '(?m)^    /// Takes every fingerprint of `other` that this map does not have\. Returns how many assets gained one\.\r?\n' '' "orphaned IdMap merge documentation"
$config = Replace-Once $config '    pub fn merge(&mut self, other: &IdMap) -> usize {' ('    #[cfg(test)]' + [char]10 + '    pub fn merge(&mut self, other: &IdMap) -> usize {') "test-only IdMap merge helper"
$config = Replace-Once $config '    fn held_by(&self, kind: &str, current: &[u8]) -> bool {' ('    #[cfg(test)]' + [char]10 + '    fn held_by(&self, kind: &str, current: &[u8]) -> bool {') "test-only payload ownership helper"
Save-Source $configPath $config

# Retry an already-replaced entry if Roblox rewrites it with the same byte length.
$watchPath = Join-Path $Project "src/watch.rs"
$watch = [IO.File]::ReadAllText($watchPath)
$watch = Replace-Once $watch @'
    /// Protected replacements are retried indefinitely.
    pub fn may_replace(&self, id: &Id) -> bool {
'@ @'
    /// Whether this entry has been replaced by one of our active rules.
    pub fn tracks(&self, id: &Id) -> bool {
        self.applied.contains_key(id)
    }

    /// Protected replacements are retried indefinitely.
    pub fn may_replace(&self, id: &Id) -> bool {
'@ "Tracker::tracks"
Save-Source $watchPath $watch

$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$oldWatchBlock = @'
            for entry in &change.written {
                written.insert(entry.id);
                self.fresh.insert(entry.id, now);
            }
            watch::merge(&mut self.entries, change);
'@
$newWatchBlock = @'
            for entry in &change.written {
                written.insert(entry.id);
                self.fresh.insert(entry.id, now);
            }
            // The Roblox cache index can report a same-length rewrite as a touch.
            // Tracked entries need to be checked again even when their size stayed the same.
            for stamp in &change.touched {
                if self.tracker.tracks(&stamp.id) {
                    written.insert(stamp.id);
                    self.fresh.insert(stamp.id, now);
                }
            }
            watch::merge(&mut self.entries, change);
'@
$gui = Replace-Once $gui $oldWatchBlock $newWatchBlock "same-size replacement watcher retry"
$lookupLabel = 'ui.weak("These IDs need local cache fingerprints before they can be applied.");'
if ([regex]::Matches($gui, [regex]::Escape($lookupLabel)).Count -eq 1) {
    $lookupUi = $lookupLabel + [char]10 +
        '                        if ui.button("Look up IDs").on_hover_text("Try to fetch these unresolved IDs from Roblox").clicked() {' + [char]10 +
        '                            actions.push(Action::LookupFor(i));' + [char]10 +
        '                        }'
    $gui = $gui.Replace($lookupLabel, $lookupUi)
} elseif (!$gui.Contains('actions.push(Action::LookupFor(i));')) {
    throw "The unresolved-ID config card could not be wired to its LookupFor action"
}

Save-Source $guiPath $gui

# Remove the Game Library, its bundled/remote catalog and its non-RIVALS fingerprints.
$gui = [IO.File]::ReadAllText($guiPath)
$gui = $gui.Replace("use crate::packs::{self, Catalog};" + [char]10, "")
$gui = Replace-RegexOnce $gui '(?m)^type SavedPack = \(PathBuf, Option<Vec<u8>>\);\r?\n' '' "saved pack type"
$gui = Replace-RegexOnce $gui '(?m)^    Packs,\r?\n' '' "Packs tab variant"
$gui = Replace-RegexOnce $gui '(?m)^            "packs" => Some\(Tab::Packs\),\r?\n' '' "Packs command-line tab"
$gui = $gui.Replace(' | Tab::Packs', '')
$gui = Replace-RegexOnce $gui '(?m)^    RefreshPacks,\r?\n    ApplyPack\(usize\),\r?\n' '' "pack actions"
$gui = Replace-RegexOnce $gui '(?s)    /// The known packs:.*?    pack_undo: Option<SavedPack>,\r?\n' '' "pack application state"
$gui = Replace-RegexOnce $gui '(?m)^            catalog: packs::bundled\(\),\r?\n            catalog_job: None,\r?\n            catalog_fetched: false,\r?\n            catalog_note: None,\r?\n            pack_job: None,\r?\n            pack_undo: None,\r?\n' '' "pack application initialization"
$gui = Replace-RegexOnce $gui '(?s)    /// Fetches the pack list.*?(?=    /// Switches tab)' '' "pack catalog methods"
$gui = Replace-RegexOnce $gui '(?m)^        if tab == Tab::Packs && !self\.catalog_fetched \{\r?\n            self\.fetch_catalog\(ctx\);\r?\n        \}\r?\n' '' "automatic pack catalog load"
$gui = [regex]::Replace($gui, '(?m)^\s*self\.idmap\.merge\(&self\.catalog\.fingerprints\);\r?\n', '')
$gui = [regex]::Replace($gui, '(?m)^\s*self\.undo_pack\(\);\r?\n', '')
$gui = [regex]::Replace($gui, '(?m)^\s*self\.pack_undo = None;\r?\n', '')
$gui = Replace-RegexOnce $gui '(?m)^            \(Tab::Packs, "Game Library", "Community and local packs"\),\r?\n' '' "Game Library sidebar row"
$gui = Replace-RegexOnce $gui '(?m)^            \(Tab::Packs, "Game Library", Some\(self\.catalog\.packs\.len\(\)\), theme::LIME\),\r?\n' '' "Game Library manage chip"
$gui = Replace-RegexOnce $gui '(?m)^\s*Tab::Packs => self\.packs_page\(ui, actions\),\r?\n' '' "Game Library page route"
$gui = Replace-RegexOnce $gui '(?m)^\s*item\(ui, actions, true, "Browse packs", "", Action::ShowTab\(Tab::Packs\)\);\r?\n' '' "Browse packs menu item"
$gui = Replace-RegexOnce $gui '(?m)^\s*if ui\.button\("Game Library"\)\.clicked\(\) \{ actions\.push\(Action::ShowTab\(Tab::Packs\)\); \}\r?\n' '' "Game Library RIVALS link"
$gui = Replace-RegexOnce $gui '(?m)^\s*if n == 0 && ui\.button\("Open Packs"\)\.clicked\(\) \{\r?\n\s*actions\.push\(Action::ShowTab\(Tab::Packs\)\);\r?\n\s*\}\r?\n' '' "Guide Game Library link"
$gui = $gui.Replace('("Get a config", "A config is a file of replacement rules: swap this asset for that file, remove that one. Packs lists ready-made ones. Any config made for Fleasion works too; it is the same format."),',
                    '("Get a config", "Use a Fleasion-compatible JSON file of replacement rules. Each rule can swap an asset for another asset or a personal file, or remove it."),')
$gui = $gui.Replace('("Add it", "Press Apply on a pack, or Add configs on the Configs tab for a file of your own. Prlngzz Editor looks up the asset IDs the config names and shows what it would change. Nothing is written until you press Apply in that window."),',
                    '("Add it", "Press Add configs on the Configs tab. Prlngzz Editor looks up the asset IDs the config names and shows what it would change. Nothing is written until you press Apply in that window."),')
$gui = Replace-RegexOnce $gui '(?s)    fn packs_page\(.*?(?=    fn \w+\()' '' "Game Library page implementation"
$gui = Replace-RegexOnce $gui '(?s)        \} else if let Some\(\(_, name\)\) = &self\.pack_job \{.*?        \} else if self\.apply_job\.is_some\(\) \{' '        } else if self.apply_job.is_some() {' "Game Library busy status"
$gui = Replace-RegexOnce $gui '(?m)^\s*self\.poll_catalog\(ctx\);\r?\n\s*self\.poll_pack\(ctx\);\r?\n' '' "Game Library polling"
$gui = $gui.Replace(' | Action::RefreshPacks', '')
$gui = Remove-RustMatchArm $gui '(?m)^\s*Action::RefreshPacks\s*=>' "RefreshPacks"
if ($gui -match '(?m)^\s*Action::ApplyPack\(index\)\s*=>') {
    $gui = Remove-RustMatchArm $gui '(?m)^\s*Action::ApplyPack\(index\)\s*=>' "ApplyPack"
}
$gui = $gui.Replace('overview, rivals, studio, asset-ids, settings, all, live, configs, packs, ids, guide, info or a kind such as textures',
                    'overview, rivals, studio, asset-ids, settings, all, live, configs, ids, guide, info or a kind such as textures')
if ($gui.Contains("Tab::Packs") -or $gui.Contains("catalog.fingerprints") -or $gui.Contains("pack_job") -or $gui.Contains("pack_undo") -or $gui.Contains("RefreshPacks") -or $gui.Contains("ApplyPack")) {
    throw "Game Library removal left GUI references behind"
}
$gui = Replace-Once $gui '/// Where a pack''s config was saved, and what that file held before.' '' "orphaned pack documentation"
$gui = Replace-RegexOnce $gui '(?s)(?m)^fn skeleton_card\(ui: &mut egui::Ui, now: f64, motion: bool\) \{.*?(?=^fn [A-Za-z_])' '' "unused skeleton card helper"
$gui = Replace-Once $gui 'alpha(if selected { theme::TEXT } else { theme::TEXT }, t)' 'alpha(theme::TEXT, t)' "identical selected text color branches"
Save-Source $guiPath $gui

# Remove pack catalog and pack-sharing commands from the CLI.
$cliPath = Join-Path $Project "src/cli.rs"
$cli = [IO.File]::ReadAllText($cliPath)
$cli = Replace-RegexOnce $cli '(?m)^        /// Open on a page:.*\r?\n' ('        /// Open on a page: overview, rivals, studio, asset-ids, settings, all, live, configs, ids, guide, info' + [char]10) "CLI page help"
$cli = Replace-RegexOnce $cli '(?s)    /// List the known packs, or download one and apply it\r?\n    Packs \{.*?\r?\n    \},\r?\n' '' "CLI Packs command"
$cli = Replace-RegexOnce $cli '(?s)    /// Print the fingerprints recorded for the asset IDs in configs, to publish in packs\.json\r?\n    Share \{.*?\r?\n    \},\r?\n' '' "CLI Share command"
$cli = Remove-RustMatchArms $cli '(?m)^\s*Cmd::Packs\s*\{' "Cmd::Packs"
$cli = Remove-RustMatchArms $cli '(?m)^\s*Cmd::Share\s*\{' "Cmd::Share"
$cli = [regex]::Replace($cli, '(?m)^use crate::packs.*\r?\n', '')
Save-Source $cliPath $cli

# The catalog files are no longer included in the shipped app.
$packsModule = Join-Path $Project "src/packs.rs"
if (Test-Path $packsModule) { Remove-Item -LiteralPath $packsModule -Force }
$manifest = Join-Path $Project "packs.json"
if (Test-Path $manifest) { Remove-Item -LiteralPath $manifest -Force }
$packDir = Join-Path $Project "packs"
if (Test-Path $packDir) { Remove-Item -LiteralPath $packDir -Recurse -Force }

# Keep the bundled README aligned with the app's removed navigation.
$readmePath = Join-Path $Project "README.md"
if (Test-Path $readmePath) {
    $readme = [IO.File]::ReadAllText($readmePath)
    $readme = $readme.Replace('Asset Library, Game Library and Settings', 'Asset Library and Settings')
    $readme = $readme.Replace('Existing cache browser is surfaced as Asset Library; bundled presets form the offline Game Library baseline.', 'The cache browser is surfaced as Asset Library; custom Fleasion-compatible JSON profiles are loaded from Config Studio.')
    $readme = $readme.Replace('Game Library currently provides bundled presets and the retained pack workflow. A complete offline custom-game/preset manager and in-app catalog URL settings are not yet implemented.', 'Community pack catalogs are not included. Use your own Fleasion-compatible JSON profiles.')
    Save-Source $readmePath $readme
}


# RIVALS-only local asset workflow and streamlined Config Studio file picker.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)

$gui = Replace-Once $gui @'
    Tag,
    CopyId,
'@ @'
    Tag,
    UseEntryForConfig(Id),
    CopyId,
'@ "selected cache entry Config Studio action"

$gui = Replace-Once $gui @'
    selected: BTreeSet<Id>,
    focus: Option<Id>,
'@ @'
    selected: BTreeSet<Id>,
    /// Cache entries explicitly identified by the user as RIVALS assets.
    rivals_entries: HashSet<Id>,
    focus: Option<Id>,
'@ "RIVALS-only asset library state"

$gui = Replace-Once $gui @'
    studio_replacement_input: String,
    studio_search: String,
'@ @'
    studio_replacement_input: String,
    studio_local_path_input: String,
    studio_search: String,
'@ "local replacement path state"

$gui = Replace-Once $gui @'
            selected: BTreeSet::new(),
            focus: None,
'@ @'
            selected: BTreeSet::new(),
            rivals_entries: load_rivals_entries(),
            focus: None,
'@ "RIVALS asset state initialization"

$gui = Replace-Once $gui @'
            studio_replacement_input: String::new(),
            studio_search: String::new(),
'@ @'
            studio_replacement_input: String::new(),
            studio_local_path_input: String::new(),
            studio_search: String::new(),
'@ "local replacement path initialization"

$helpers = @'
fn load_rivals_entries() -> HashSet<Id> {
    let Ok(path) = crate::protection::data_dir().map(|dir| dir.join("rivals-assets.json")) else { return HashSet::new() };
    let Ok(bytes) = std::fs::read(path) else { return HashSet::new() };
    serde_json::from_slice::<Vec<String>>(&bytes).unwrap_or_default()
        .iter().filter_map(|id| store::parse_id(id)).collect()
}

fn save_rivals_entries(entries: &HashSet<Id>) -> anyhow::Result<()> {
    let dir = crate::protection::data_dir()?;
    std::fs::create_dir_all(&dir)?;
    let mut ids: Vec<String> = entries.iter().map(|id| store::hex(id)).collect();
    ids.sort_unstable();
    std::fs::write(dir.join("rivals-assets.json"), serde_json::to_string_pretty(&ids)?)?;
    Ok(())
}

'@
$gui = Replace-Once $gui 'impl App {' ($helpers + 'impl App {') "RIVALS asset tag persistence helpers"

$gui = Replace-Once $gui @'
        if self.idmap.add(asset, fp) {
            self.idmap.save(&self.idmap_path)?;
        }
        if let Some(sound)
'@ @'
        if self.idmap.add(asset, fp) {
            self.idmap.save(&self.idmap_path)?;
        }
        if self.rivals_entries.insert(entry) {
            save_rivals_entries(&self.rivals_entries)?;
        }
        if let Some(sound)
'@ "lookup-picked cache entry RIVALS tag"

$gui = Replace-Once $gui @'
        let Some(e) = self.focused() else { return Ok(String::new()) };
        if let Some(error) = &self.idmap_error {
'@ @'
        let Some(e) = self.focused() else { return Ok(String::new()) };
        let entry_id = e.id;
        let entry_hex = e.id_hex.clone();
        if let Some(error) = &self.idmap_error {
'@ "focused cache entry borrow"

$gui = Replace-Once $gui @'
        let fp = config::fingerprint(&Store::open(&self.dir, false)?.read_body(&e.id)?);
        let msg = format!("Asset {asset} now points at {}", e.id_hex);
        if self.idmap.add(asset, fp) {
            self.idmap.save(&self.idmap_path)?;
        }
        self.tag_input.clear();
        self.preview = None;
        Ok(msg)
'@ @'
        let fp = config::fingerprint(&Store::open(&self.dir, false)?.read_body(&entry_id)?);
        let msg = format!("Asset {asset} is tagged as a RIVALS asset ({entry_hex})");
        if self.idmap.add(asset, fp) {
            self.idmap.save(&self.idmap_path)?;
        }
        self.rivals_entries.insert(entry_id);
        save_rivals_entries(&self.rivals_entries)?;
        self.tag_input.clear();
        self.preview = None;
        self.rebuild_view();
        Ok(msg)
'@ "tag focused cache entry as RIVALS"

$gui = Replace-Once $gui @'
        let entries = &self.entries;
        // Position of each arrival, which doubles as the Live tab's membership test.
'@ @'
        let entries = &self.entries;
        let rivals_library = matches!(self.tab, Tab::All | Tab::Group(_) | Tab::Other);
        // Position of each arrival, which doubles as the Live tab's membership test.
'@ "RIVALS Asset Library filtering"

$gui = Replace-Once $gui @'
            .filter(|&i| self.tab != Tab::Live || arrived.contains_key(&entries[i].id))
            .filter(|&i| {
'@ @'
            .filter(|&i| self.tab != Tab::Live || arrived.contains_key(&entries[i].id))
            .filter(|&i| !rivals_library || self.rivals_entries.contains(&entries[i].id))
            .filter(|&i| {
'@ "RIVALS-only visible entries"

$gui = Replace-Once $gui @'
            Action::Tag => self.tag_focused(),
            Action::PlayAudio => self.play_audio(),
'@ @'
            Action::Tag => self.tag_focused(),
            Action::UseEntryForConfig(id) => {
                self.rivals_entries.insert(id);
                save_rivals_entries(&self.rivals_entries)?;
                self.studio_target_input = store::hex(&id);
                self.show_tab(Tab::Studio, ctx);
                self.studio_status = "Selected cache entry as a local RIVALS replacement target. Choose a file below.".into();
                Ok(String::new())
            }
            Action::PlayAudio => self.play_audio(),
'@ "selected asset opens Config Studio"

$gui = Replace-Once $gui @'
                if ui.button("Replace...").on_hover_text("Swap the payload for a file of your choice").clicked() {
                    actions.push(Action::Replace);
                }
'@ @'
                if ui.button("Use in Config").on_hover_text("Use this exact cache entry as a RIVALS replacement target").clicked() {
                    if let Some(entry) = entry { actions.push(Action::UseEntryForConfig(entry.id)); }
                }
                if ui.button("Replace...").on_hover_text("Swap the payload for a file of your choice").clicked() {
                    actions.push(Action::Replace);
                }
'@ "Use in Config detail action"

$gui = Replace-Once $gui @'
                if ui.button("Tag").on_hover_text("Remember that this entry is that Roblox asset, so configs can refer to it by ID").clicked()
'@ @'
                if ui.button("Tag as RIVALS").on_hover_text("Add this cache entry to the RIVALS-only Asset Library").clicked()
'@ "RIVALS tag button"

$oldChips = @'
    fn browse_chips(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {
        let mut chips = vec![(Tab::All, "All", Some(self.listed()), theme::MUTED), (Tab::Live, "Live", Some(self.arrivals.len()), theme::OK)];
        for (i, (name, kinds)) in GROUPS.iter().enumerate() {
            if self.group_counts[i] > 0 {
                chips.push((Tab::Group(i), name, Some(self.group_counts[i]), theme::kind_color(kinds[0])));
            }
        }
        if self.other_count > 0 {
            chips.push((Tab::Other, "Other", Some(self.other_count), theme::MUTED));
        }
        self.chips(ui, &chips, actions);
    }
'@
$newChips = @'
    fn browse_chips(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {
        let tagged = rivals_asset_ids().len();
        let chips = [
            (Tab::All, "RIVALS assets", Some(tagged), theme::ACCENT),
            (Tab::Live, "Discover", Some(self.arrivals.len()), theme::OK),
        ];
        self.chips(ui, &chips, actions);
    }
'@
$gui = Replace-Once $gui $oldChips $newChips "RIVALS-only Asset Library tabs"

$gui = Replace-Once $gui @'
            (Tab::AssetIds, "Asset ID Editor", "Bulk ID management"),
            (Tab::All, "Asset Library", "Local cached assets"),
'@ @'
            (Tab::AssetIds, "Asset ID Editor", "RIVALS asset IDs"),
            (Tab::All, "Asset Library", "RIVALS-tagged assets only"),
'@ "RIVALS-only navigation labels"

$gui = Replace-Once $gui @'
        });
        ui.add_space(10.0);
        let rows = self.studio_doc.rules().to_vec();
'@ @'
        });
        ui.add_space(10.0);
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("RIVALS CONFIG BUILDER").strong().size(17.0).color(theme::ACCENT));
            ui.label(egui::RichText::new("Pick a target, choose a local file, then add the replacement rule. Multiple IDs can be pasted together.").color(theme::MUTED).small());
            let target_fade = ui.ctx().animate_value_with_time(egui::Id::new("config-target-field-enter"), 1.0, 0.18);
            ui.add_space((1.0 - target_fade) * 5.0);
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("01  TARGET IDs").strong().small());
                ui.add(egui::TextEdit::singleline(&mut self.studio_target_input).desired_width(280.0).hint_text("RIVALS asset IDs or cache keys"));
            });
            let file_fade = ui.ctx().animate_value_with_time(egui::Id::new("config-file-field-enter"), 1.0, 0.22);
            ui.add_space((1.0 - file_fade) * 5.0);
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("02  FILE").strong().small());
                ui.add(egui::TextEdit::singleline(&mut self.studio_local_path_input).desired_width(280.0).hint_text("Choose OBJ, image, texture map or audio"));
                if ui.button("Browse…").clicked() {
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter("RIVALS replacement assets", &["obj", "png", "jpg", "jpeg", "webp", "gif", "wav", "mp3", "ogg", "flac"])
                        .pick_file()
                    {
                        self.studio_local_path_input = path.display().to_string();
                    }
                }
            });
            let add_enter = ui.ctx().animate_value_with_time(egui::Id::new("config-add-action-enter"), 1.0, 0.26);
            ui.add_space((1.0 - add_enter) * 6.0);
            ui.label(egui::RichText::new("03  ADD TO CONFIG").strong().small().color(theme::ACCENT));
            if ui.add(primary_button("Add to Config")).clicked() {
                match self.add_studio_local_rules() {
                    Ok(count) => self.studio_status = format!("Added {count} local replacement rule(s)."),
                    Err(error) => self.studio_status = format!("Could not add local rule: {error:#}"),
                }
            }
            ui.label(egui::RichText::new("OBJ geometry is converted to Roblox mesh v1.01 for mesh targets. Texture maps are separate image rules; OBJ does not contain rigging or skin weights.").color(theme::MUTED).small());
        });
        ui.add_space(10.0);
        let rows = self.studio_doc.rules().to_vec();
'@ "Config Studio local replacement card"

$localHelper = @'
    fn add_studio_local_rules(&mut self) -> anyhow::Result<usize> {
        let path = self.studio_local_path_input.trim().to_owned();
        anyhow::ensure!(!path.is_empty() && std::fs::metadata(&path).is_ok_and(|meta| meta.is_file()),
            "Choose an existing local replacement file");

        let raw = self.studio_target_input.trim();
        let mut targets = Vec::new();
        let mut seen = HashSet::new();
        for token in raw.split(|ch: char| ch.is_whitespace() || ch == ',' || ch == ';') {
            let token = token.trim().trim_matches('"');
            if token.is_empty() { continue; }

            if token.len() == 32 && token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                let key = token.to_ascii_lowercase();
                if seen.insert(key.clone()) { targets.push(key); }
            } else if let Ok(id) = token.parse::<u64>() {
                if id > 0 {
                    let value = id.to_string();
                    if seen.insert(value.clone()) { targets.push(value); }
                }
            } else {
                for id in crate::studio::extract_asset_ids(token) {
                    if id > 0 {
                        let value = id.to_string();
                        if seen.insert(value.clone()) { targets.push(value); }
                    }
                }
            }
        }
        anyhow::ensure!(!targets.is_empty(),
            "Paste one or more decimal Roblox asset IDs or 32-character cache-entry keys");
        for target in &targets { self.studio_doc.add_local_rule(target, &path)?; }
        self.studio_target_input.clear();
        self.studio_local_path_input.clear();
        Ok(targets.len())
    }

'@
$gui = Replace-Once $gui '    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {' ($localHelper + '    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {') "local-file Config Studio helper"

$gui = Replace-Once $gui @'
    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {
        let mut clicked: Option<usize> = None;
'@ @'
    fn table(&mut self, ui: &mut egui::Ui, actions: &mut Vec<Action>) {
        if self.view.is_empty() && self.tab == Tab::All {
            ui.vertical_centered(|ui| {
                ui.add_space(56.0);
                ui.label(egui::RichText::new("No RIVALS assets tagged yet").size(18.0).strong());
                ui.add_space(5.0);
                ui.label(egui::RichText::new("Open Discover, select a cache entry, enter its Roblox asset ID and choose Tag as RIVALS.").color(theme::MUTED).small());
                ui.add_space(12.0);
                if ui.add(primary_button("Open Discover")).clicked() {
                    actions.push(Action::ShowTab(Tab::Live));
                }
            });
            return;
        }
        let mut clicked: Option<usize> = None;
'@ "RIVALS Asset Library empty state"

Save-Source $guiPath $gui

# Add local_file actions to the profile document used by Config Studio.
$studioPath = Join-Path $Project "src/studio.rs"
$studio = [IO.File]::ReadAllText($studioPath)
$addRule = @'
    pub fn add_rule(&mut self, target_id: u64, replacement_id: u64) -> Result<()> {
        ensure!(target_id > 0 && replacement_id > 0, "Asset IDs must be greater than zero");
        let rules = self.raw.get_mut("rules").and_then(Value::as_array_mut).context("The profile rules field must be an array")?;
        let mut sequence = count_rules(rules) + 1;
        while rule_id_exists(rules, &format!("rule-{sequence:03}")) { sequence += 1; }
        rules.push(json!({
            "id": format!("rule-{sequence:03}"),
            "name": "Asset replacement",
            "enabled": true,
            "targets": [target_id],
            "action": { "type": "asset_id", "asset_id": replacement_id },
            "notes": ""
        }));
        Ok(())
    }
'@
$localMethod = @'

    /// Adds a local replacement to a Roblox asset ID or a 32-hex cache-entry ID.
    pub fn add_local_rule(&mut self, target: &str, path: &str) -> Result<()> {
        ensure!(!path.trim().is_empty(), "Choose a local replacement file");
        let target = target.trim();
        let target = match target.parse::<u64>() {
            Ok(id) if id > 0 => json!(id),
            _ => {
                ensure!(target.len() == 32 && target.bytes().all(|b| b.is_ascii_hexdigit()),
                    "Target must be a positive Roblox asset ID or a 32-character cache entry ID");
                json!(target.to_ascii_lowercase())
            }
        };
        let rules = self.raw.get_mut("rules").and_then(Value::as_array_mut).context("The profile rules field must be an array")?;
        let mut sequence = count_rules(rules) + 1;
        while rule_id_exists(rules, &format!("rule-{sequence:03}")) { sequence += 1; }
        rules.push(json!({
            "id": format!("rule-{sequence:03}"),
            "name": "Local file replacement",
            "enabled": true,
            "targets": [target],
            "action": { "type": "local_file", "path": path },
            "notes": "Local RIVALS cache replacement; OBJ geometry is converted to Roblox mesh v1.01 for mesh targets."
        }));
        Ok(())
    }
'@
$studio = Replace-Once $studio $addRule ($addRule + $localMethod) "local-file profile rule constructor"
Save-Source $studioPath $studio

# Give hover states a softer purple lift while preserving the existing navigation and selection easing.
$themePath = Join-Path $Project "src/theme.rs"
$theme = [IO.File]::ReadAllText($themePath)
# Refine the visual system: richer violet surfaces, clearer contrast, larger radii and roomier controls.
$theme = Replace-Once $theme 'pub const BG: Color32 = Color32::from_rgb(11, 9, 18);' 'pub const BG: Color32 = Color32::from_rgb(9, 8, 18);' "deep background palette"
$theme = Replace-Once $theme 'pub const PANEL: Color32 = Color32::from_rgb(20, 16, 29);' 'pub const PANEL: Color32 = Color32::from_rgb(17, 15, 30);' "panel palette"
$theme = Replace-Once $theme 'pub const CARD: Color32 = Color32::from_rgb(28, 22, 41);' 'pub const CARD: Color32 = Color32::from_rgb(25, 21, 43);' "card palette"
$theme = Replace-Once $theme 'pub const RAISED: Color32 = Color32::from_rgb(38, 30, 53);' 'pub const RAISED: Color32 = Color32::from_rgb(36, 29, 58);' "raised surface palette"
$theme = Replace-Once $theme 'pub const BORDER: Color32 = Color32::from_rgb(48, 36, 64);' 'pub const BORDER: Color32 = Color32::from_rgb(64, 48, 91);' "border palette"
$theme = Replace-Once $theme 'pub const TEXT: Color32 = Color32::from_rgb(245, 240, 255);' 'pub const TEXT: Color32 = Color32::from_rgb(248, 245, 255);' "text palette"
$theme = Replace-Once $theme 'pub const MUTED: Color32 = Color32::from_rgb(169, 158, 184);' 'pub const MUTED: Color32 = Color32::from_rgb(178, 168, 198);' "muted text palette"
$theme = Replace-Once $theme 'pub const ACCENT: Color32 = Color32::from_rgb(153, 92, 255);' 'pub const ACCENT: Color32 = Color32::from_rgb(169, 112, 255);' "violet accent palette"
$theme = Replace-Once $theme 'pub const SPLASH_PURPLE: Color32 = Color32::from_rgb(62, 30, 100);' 'pub const SPLASH_PURPLE: Color32 = Color32::from_rgb(76, 35, 132);' "splash gradient palette"
$theme = Replace-Once $theme 'pub const SPLASH_BAR: Color32 = Color32::from_rgb(153, 92, 255);' 'pub const SPLASH_BAR: Color32 = Color32::from_rgb(169, 112, 255);' "splash bar palette"
$theme = Replace-Once $theme 'pub const LIME: Color32 = Color32::from_rgb(181, 138, 255);' 'pub const LIME: Color32 = Color32::from_rgb(194, 157, 255);' "wordmark palette"
$theme = Replace-Once $theme @'
    v.extreme_bg_color = Color32::from_rgb(30, 34, 46);
    v.faint_bg_color = Color32::from_rgb(22, 25, 33);
'@ @'
    v.extreme_bg_color = Color32::from_rgb(14, 12, 25);
    v.faint_bg_color = Color32::from_rgb(21, 18, 35);
'@ "violet window surfaces"
$theme = Replace-Once $theme @'
    v.window_corner_radius = CornerRadius::same(14);
    v.menu_corner_radius = CornerRadius::same(10);
    v.window_shadow = egui::Shadow { offset: [0, 14], blur: 40, spread: 0, color: Color32::from_black_alpha(140) };
    v.popup_shadow = egui::Shadow { offset: [0, 8], blur: 24, spread: 0, color: Color32::from_black_alpha(120) };
'@ @'
    v.window_corner_radius = CornerRadius::same(18);
    v.menu_corner_radius = CornerRadius::same(13);
    v.window_shadow = egui::Shadow { offset: [0, 18], blur: 52, spread: 1, color: Color32::from_black_alpha(165) };
    v.popup_shadow = egui::Shadow { offset: [0, 10], blur: 30, spread: 1, color: Color32::from_black_alpha(145) };
'@ "premium rounded windows and layered shadows"
$theme = Replace-Once $theme '    let radius = CornerRadius::same(7);' '    let radius = CornerRadius::same(10);' "rounded controls"
$theme = Replace-Once $theme @'
    s.item_spacing = Vec2::new(8.0, 6.0);
    s.button_padding = Vec2::new(10.0, 5.0);
    s.interact_size.y = 26.0;
    s.menu_margin = Margin::same(6);
    s.window_margin = Margin::same(14);
    s.scroll.bar_width = 8.0;
'@ @'
    s.item_spacing = Vec2::new(10.0, 8.0);
    s.button_padding = Vec2::new(14.0, 7.0);
    s.interact_size.y = 32.0;
    s.menu_margin = Margin::same(9);
    s.window_margin = Margin::same(18);
    s.scroll.bar_width = 9.0;
'@ "roomier layout spacing"
$theme = Replace-Once $theme @'
    style.text_styles.insert(TextStyle::Body, FontId::proportional(14.0));
    style.text_styles.insert(TextStyle::Button, FontId::proportional(14.0));
    style.text_styles.insert(TextStyle::Small, FontId::proportional(11.5));
    style.text_styles.insert(TextStyle::Heading, FontId::proportional(20.0));
'@ @'
    style.text_styles.insert(TextStyle::Body, FontId::proportional(14.5));
    style.text_styles.insert(TextStyle::Button, FontId::proportional(14.0));
    style.text_styles.insert(TextStyle::Small, FontId::proportional(12.0));
    style.text_styles.insert(TextStyle::Heading, FontId::proportional(22.0));
'@ "refined app typography"
$theme = Replace-Once $theme '    style.animation_time = 0.16;' '    style.animation_time = 0.28;' "smoother global widget transitions"

$theme = Replace-Once $theme @'
    w.hovered.bg_fill = Color32::from_rgb(50, 57, 78);
    w.hovered.weak_bg_fill = Color32::from_rgb(50, 57, 78);
'@ @'
    w.hovered.bg_fill = Color32::from_rgb(56, 42, 82);
    w.hovered.weak_bg_fill = Color32::from_rgb(56, 42, 82);
'@ "soft hover colours"
$theme = Replace-Once $theme @'
    w.open.bg_fill = Color32::from_rgb(44, 50, 70);
    w.open.weak_bg_fill = Color32::from_rgb(44, 50, 70);
'@ @'
    w.open.bg_fill = Color32::from_rgb(48, 36, 74);
    w.open.weak_bg_fill = Color32::from_rgb(48, 36, 74);
'@ "soft open colours"
Save-Source $themePath $theme



# Validate local OBJ file extensions and cache target kinds before any replacement write.
$configPath = Join-Path $Project "src/config.rs"
$config = [IO.File]::ReadAllText($configPath)
$oldObjFit = @'
        if kind == "mesh" && crate::obj::looks_like_obj(&self.bytes) {
            return crate::obj::to_roblox_mesh(&self.bytes)
                .map(Cow::Owned)
                .context("converting personal Wavefront OBJ file to Roblox FileMesh");
        }
'@
$newObjFit = @'
        if crate::obj::looks_like_obj(&self.bytes) {
            ensure!(kind == "mesh", "OBJ files can only replace RIVALS mesh cache entries; select a mesh asset as the target");
            return crate::obj::to_roblox_mesh(&self.bytes)
                .map(Cow::Owned)
                .context("converting personal Wavefront OBJ file to Roblox FileMesh");
        }
'@
$config = Replace-Once $config $oldObjFit $newObjFit "OBJ cache-kind validation"
$oldLocal = '            Action::Local(path) => std::fs::read(path).map(|body| Some(Arc::new(body))).with_context(|| format!("reading {}", path.display())),'
$newLocal = @'
            Action::Local(path) => (|| {
                let mut body = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
                let is_obj = path.extension().and_then(std::ffi::OsStr::to_str)
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("obj"));
                if is_obj {
                    ensure!(matched.iter().all(|&i| resolver.kind(i) == "mesh"),
                        "OBJ files can only replace RIVALS mesh cache entries; select a mesh asset as the target");
                    body = crate::obj::to_roblox_mesh(&body)?;
                }
                Ok(Some(Arc::new(body)))
            })(),
'@
$config = Replace-Once $config $oldLocal $newLocal "local OBJ conversion and target validation"
Save-Source $configPath $config


# Keep selected-entry actions inside the existing Result-returning action dispatcher.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$oldAction = @'
            Action::UseEntryForConfig(id) => {
                self.rivals_entries.insert(id);
                save_rivals_entries(&self.rivals_entries)?;
                self.studio_target_input = store::hex(&id);
                self.show_tab(Tab::Studio, ctx);
                self.studio_status = "Selected cache entry as a local RIVALS replacement target. Choose a file below.".into();
                Ok(String::new())
            }
'@
$newAction = @'
            Action::UseEntryForConfig(id) => {
                self.rivals_entries.insert(id);
                save_rivals_entries(&self.rivals_entries)?;
                self.studio_target_input = store::hex(&id);
                self.show_tab(Tab::Studio, ctx);
                self.studio_status = "Selected cache entry as a local RIVALS replacement target. Choose a file below.".into();
                Ok(String::new())
            }
'@
$gui = Replace-Once $gui $oldAction $newAction "Result-wrapped Use in Config action"
Save-Source $guiPath $gui


# Remove the obsolete generic-list counter after the Asset Library became RIVALS-only.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui @'
    /// How many entries the All list has: redirect records only count while they are listed.
    fn listed(&self) -> usize {
        let redirects = self.kinds.iter().find(|(kind, _)| *kind == "redirect").map_or(0, |(_, n)| *n);
        self.entries.len() - if self.show_redirects { 0 } else { redirects }
    }
'@ '' "obsolete generic asset list count"
Save-Source $guiPath $gui


# Install the curated RIVALS-only asset ID allowlist and catalogue.
Copy-Item -LiteralPath (Join-Path $env:GITHUB_WORKSPACE ".github/patches/rivals_asset_ids.json") -Destination (Join-Path $Project "rivals_asset_ids.json") -Force
Copy-Item -LiteralPath (Join-Path $env:GITHUB_WORKSPACE ".github/patches/rivals_asset_catalog.json") -Destination (Join-Path $Project "rivals_asset_catalog.json") -Force

$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)

# Use a versioned tag store so old arbitrary cache tags from the previous draft cannot leak into the RIVALS-only library.
$gui = $gui.Replace('dir.join("rivals-assets.json")', 'dir.join("rivals-assets-v2.json")')

$catalogHelpers = @'
fn rivals_asset_ids() -> &'static std::collections::HashSet<u64> {
    static IDS: std::sync::OnceLock<std::collections::HashSet<u64>> = std::sync::OnceLock::new();
    IDS.get_or_init(|| {
        let values: Vec<String> = serde_json::from_str(include_str!("../rivals_asset_ids.json")).unwrap_or_default();
        values.into_iter().filter_map(|value| value.parse::<u64>().ok()).collect()
    })
}

'@
$gui = Replace-Once $gui 'impl App {' ($catalogHelpers + 'impl App {') "curated RIVALS asset ID allowlist"

# Only IDs in the pinned RIVALS catalogue may be tagged into the Asset Library.
$gui = Replace-Once $gui @'
        let fp = config::fingerprint(&Store::open(&self.dir, false)?.read_body(&entry_id)?);
'@ @'
        anyhow::ensure!(rivals_asset_ids().contains(&asset), "This Roblox ID is not in the curated RIVALS catalogue, so it cannot be added to the RIVALS Asset Library.");
        let fp = config::fingerprint(&Store::open(&self.dir, false)?.read_body(&entry_id)?);
'@ "reject non-RIVALS asset IDs"

# Cache lookups only add entries to the RIVALS library when the requested Roblox ID is on the allowlist.
$gui = Replace-Once $gui @'
        if self.rivals_entries.insert(entry) {
            save_rivals_entries(&self.rivals_entries)?;
        }
'@ @'
        if rivals_asset_ids().contains(&asset) && self.rivals_entries.insert(entry) {
            save_rivals_entries(&self.rivals_entries)?;
        }
'@ "only catalogue IDs enter the RIVALS library"

# Using an entry in Config Studio must not silently classify an arbitrary cache entry as a RIVALS asset.
$gui = Replace-Once $gui @'
            Action::UseEntryForConfig(id) => {
                self.rivals_entries.insert(id);
                save_rivals_entries(&self.rivals_entries)?;
                self.studio_target_input = store::hex(&id);
'@ @'
            Action::UseEntryForConfig(id) => {
                self.studio_target_input = store::hex(&id);
'@ "keep Config Studio selection separate from RIVALS library membership"

# Accept any file extension in the picker; the payload decoder will validate the actual format.
$gui = Replace-Once $gui @'
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter("RIVALS replacement assets", &["obj", "png", "jpg", "jpeg", "webp", "gif", "wav", "mp3", "ogg", "flac"])
                        .pick_file()
'@ @'
                    if let Some(path) = rfd::FileDialog::new()
                        .pick_file()
'@ "unrestricted local file picker"

# Make the local-file card and library-tab changes ease in with small, unobtrusive motion.
$gui = Replace-Once $gui @'
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("RIVALS CONFIG BUILDER").strong().size(17.0).color(theme::ACCENT));
'@ @'
        let card_fade = ui.ctx().animate_value_with_time(egui::Id::new("config-local-file-card"), 1.0, 0.20);
        ui.add_space((1.0 - card_fade) * 7.0);
        card(ui, card_fade, |ui| {
            ui.label(egui::RichText::new("RIVALS CONFIG BUILDER").strong().size(17.0).color(theme::ACCENT));
'@ "Config Studio card fade transition"

# Explain that one local-file action applies to every target ID entered in the same rule.
$gui = $gui.Replace("Select an asset and choose “Use in Config”, or enter its Roblox asset ID / cache entry ID in Target IDs above.",
                    "Select an asset and choose “Use in Config”, or paste one or more RIVALS target IDs above. One click adds the chosen file to every target.")
$gui = $gui.Replace("Add local rule", "Add file to Config")
Save-Source $guiPath $gui


# Replace the cache-only Asset Library view with a searchable curated RIVALS catalogue.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui @'
    rivals_entries: HashSet<Id>,
'@ @'
    rivals_entries: HashSet<Id>,
    rivals_catalog_search: String,
'@ "RIVALS catalogue search state"
$gui = Replace-Once $gui @'
            rivals_entries: load_rivals_entries(),
'@ @'
            rivals_entries: load_rivals_entries(),
            rivals_catalog_search: String::new(),
'@ "RIVALS catalogue search initialization"

$oldEmpty = @'
        if self.view.is_empty() && self.tab == Tab::All {
            ui.vertical_centered(|ui| {
                ui.add_space(56.0);
                ui.label(egui::RichText::new("No RIVALS assets tagged yet").size(18.0).strong());
                ui.add_space(5.0);
                ui.label(egui::RichText::new("Open Discover, select a cache entry, enter its Roblox asset ID and choose Tag as RIVALS.").color(theme::MUTED).small());
                ui.add_space(12.0);
                if ui.add(primary_button("Open Discover")).clicked() {
                    actions.push(Action::ShowTab(Tab::Live));
                }
            });
            return;
        }
'@
$newLibrary = @'
        if self.tab == Tab::All {
            let tab_fade = ui.ctx().animate_value_with_time(egui::Id::new("rivals-library-enter"), 1.0, 0.18);
            ui.add_space((1.0 - tab_fade) * 4.0);
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("RIVALS ASSET CATALOGUE").strong());
                ui.add_space(8.0);
                ui.add(egui::TextEdit::singleline(&mut self.rivals_catalog_search)
                    .desired_width(260.0)
                    .hint_text("Search skins, skies, sounds or ID…"));
            });
            ui.label(egui::RichText::new("Curated Roblox IDs for RIVALS weapon icons, community skyboxes and audio. Select an item to use its ID in Config Studio.").color(theme::MUTED).small());
            let query = self.rivals_catalog_search.trim().to_lowercase();
            let catalog: serde_json::Value = serde_json::from_str(include_str!("../rivals_asset_catalog.json")).unwrap_or_default();
            let assets = catalog.get("assets").and_then(serde_json::Value::as_array).cloned().unwrap_or_default();
            let total = assets.len();
            let mut selected_id: Option<String> = None;
            if ui.button("Use all known map sky IDs").on_hover_text("Add every currently verified RIVALS map-sky target to one local replacement rule").clicked() {
                let ids: Vec<&str> = assets.iter()
                    .filter(|asset| asset.get("category").and_then(serde_json::Value::as_str) == Some("RIVALS map sky texture"))
                    .filter_map(|asset| asset.get("id").and_then(serde_json::Value::as_str))
                    .collect();
                if !ids.is_empty() { selected_id = Some(ids.join("\n")); }
            }
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                ui.label(egui::RichText::new(format!("{total} curated RIVALS asset IDs")).color(theme::MUTED).small());
                for asset in assets {
                    let id = asset.get("id").and_then(serde_json::Value::as_str).unwrap_or("");
                    let name = asset.get("name").and_then(serde_json::Value::as_str).unwrap_or("RIVALS asset");
                    let category = asset.get("category").and_then(serde_json::Value::as_str).unwrap_or("RIVALS");
                    let variant = asset.get("variant").and_then(serde_json::Value::as_str).unwrap_or("");
                    let haystack = format!("{category} {name} {variant} {id}").to_lowercase();
                    if !query.is_empty() && !haystack.contains(&query) { continue; }
                    let row_enter = ui.ctx().animate_value_with_time(egui::Id::new(("rivals-catalog-entry-enter", id)), 1.0, 0.20);
                    ui.add_space((1.0 - row_enter) * 4.0);
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(category).color(theme::MUTED).small());
                        ui.label(name);
                        if !variant.is_empty() { ui.label(egui::RichText::new(variant).color(theme::MUTED).small()); }
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui.small_button("Use in Config").clicked() { selected_id = Some(id.to_owned()); }
                            ui.monospace(id);
                        });
                    });
                    ui.separator();
                }
            });
            if let Some(id) = selected_id {
                self.studio_target_input = id;
                self.show_tab(Tab::Studio, ui.ctx());
            }
            return;
        }
'@
$gui = Replace-Once $gui $oldEmpty $newLibrary "searchable RIVALS Asset Library catalogue"
Save-Source $guiPath $gui


# Persistent in-app customization and Config Manager navigation.
$settingsPath = Join-Path $Project "src/settings.rs"
$settings = [IO.File]::ReadAllText($settingsPath)
$settings = Replace-Once $settings @'
    pub animations: bool,
'@ @'
    pub animations: bool,
    /// Accent palette selected in the Customization page.
    pub accent: String,
    /// Denser spacing for smaller windows and faster scanning.
    pub compact_layout: bool,
    /// Show glyph icons beside sidebar labels.
    pub show_nav_icons: bool,
'@ "persisted appearance preferences"
$settings = Replace-Once $settings @'
        Self { close_to_tray: true, animations: true, watch: true, configs: Vec::new(), winners: BTreeMap::new(), seen_version: String::new() }
'@ @'
        Self {
            close_to_tray: true,
            animations: true,
            accent: "violet".into(),
            compact_layout: false,
            show_nav_icons: true,
            watch: true,
            configs: Vec::new(),
            winners: BTreeMap::new(),
            seen_version: String::new(),
        }
'@ "default appearance preferences"
Save-Source $settingsPath $settings

# Runtime accent palettes and a compact density preset.
$themePath = Join-Path $Project "src/theme.rs"
$theme = [IO.File]::ReadAllText($themePath)
$theme = Replace-Once $theme 'use eframe::egui::{self, Color32, CornerRadius, FontId, Margin, Rect, Shape, Stroke, TextStyle, Vec2};' @'
use eframe::egui::{self, Color32, CornerRadius, FontId, Margin, Rect, Shape, Stroke, TextStyle, Vec2};
use std::sync::atomic::{AtomicU32, Ordering};
'@ "runtime palette imports"
$theme = Replace-Once $theme @'
pub fn alpha(color: Color32, a: f32) -> Color32 {
'@ @'
static ACCENT_RGB: AtomicU32 = AtomicU32::new(0xA970FF);

/// The active accent colour, selected by the user in Customization.
pub fn accent() -> Color32 {
    let rgb = ACCENT_RGB.load(Ordering::Relaxed);
    Color32::from_rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)
}

/// Select one of the built-in accent palettes.
pub fn set_accent_name(name: &str) {
    let rgb = match name {
        "blue" => 0x68A7FF,
        "cyan" => 0x55D6D1,
        "rose" => 0xF07BAE,
        "amber" => 0xE8B65D,
        _ => 0xA970FF,
    };
    ACCENT_RGB.store(rgb, Ordering::Relaxed);
}

/// Re-tint interactive states without rebuilding fonts or resetting spacing.
pub fn apply_accent(ctx: &egui::Context) {
    let accent = accent();
    let mut style = (*ctx.style()).clone();
    let visuals = &mut style.visuals;
    visuals.hyperlink_color = accent;
    visuals.selection.bg_fill = alpha(accent, 0.26);
    visuals.widgets.hovered.bg_stroke = Stroke::new(1.0, alpha(accent, 0.72));
    visuals.widgets.active.bg_fill = alpha(accent, 0.55);
    visuals.widgets.active.bg_stroke = Stroke::new(1.0, accent);
    visuals.widgets.open.bg_stroke = Stroke::new(1.0, alpha(accent, 0.72));
    ctx.set_style(style);
}

/// Apply comfortable or compact spacing while retaining the rest of the theme.
pub fn apply_density(ctx: &egui::Context, compact: bool) {
    let mut style = (*ctx.style()).clone();
    let spacing = &mut style.spacing;
    if compact {
        spacing.item_spacing = Vec2::new(6.0, 4.0);
        spacing.button_padding = Vec2::new(9.0, 4.0);
        spacing.interact_size.y = 27.0;
        spacing.window_margin = Margin::same(12);
        spacing.scroll.bar_width = 7.0;
    } else {
        spacing.item_spacing = Vec2::new(10.0, 8.0);
        spacing.button_padding = Vec2::new(14.0, 7.0);
        spacing.interact_size.y = 32.0;
        spacing.window_margin = Margin::same(18);
        spacing.scroll.bar_width = 9.0;
    }
    ctx.set_style(style);
}

pub fn alpha(color: Color32, a: f32) -> Color32 {
'@ "accent and density helpers"
$applyStart = $theme.IndexOf("pub fn apply(ctx: &egui::Context) {")
$kindStart = $theme.IndexOf("/// Colour that identifies a content type", $applyStart)
if ($applyStart -lt 0 -or $kindStart -lt 0) { throw "Could not locate theme apply function" }
$apply = $theme.Substring($applyStart, $kindStart - $applyStart)
$apply = $apply.Replace("    let v = &mut style.visuals;", ("    let accent = accent();" + [char]10 + "    let v = &mut style.visuals;"))
$apply = $apply.Replace("v.hyperlink_color = ACCENT;", "v.hyperlink_color = accent;")
$apply = $apply.Replace("alpha(ACCENT, 0.26)", "alpha(accent, 0.26)")
$apply = $apply.Replace("alpha(ACCENT, 0.7)", "alpha(accent, 0.7)")
$apply = $apply.Replace("alpha(ACCENT, 0.55)", "alpha(accent, 0.55)")
$apply = $apply.Replace("Stroke::new(1.0_f32, ACCENT)", "Stroke::new(1.0_f32, accent)")
$theme = $theme.Substring(0, $applyStart) + $apply + $theme.Substring($kindStart)
Save-Source $themePath $theme

# Move Config Manager into the first sidebar slot, add iconography and Customization.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$gui = Replace-Once $gui @'
    Studio,
    AssetIds,
    Settings,
'@ @'
    Studio,
    AssetIds,
    Settings,
    Customization,
'@ "Customization tab variant"
$gui = Replace-Once $gui @'
            "settings" => Some(Tab::Settings),
'@ @'
            "settings" => Some(Tab::Settings),
            "customization" | "customise" | "customize" => Some(Tab::Customization),
'@ "Customization command-line tab"
$gui = Replace-Once $gui @'
Tab::Overview | Tab::Rivals | Tab::Studio | Tab::AssetIds | Tab::Settings | Tab::Configs
'@ @'
Tab::Overview | Tab::Rivals | Tab::Studio | Tab::AssetIds | Tab::Settings | Tab::Customization | Tab::Configs
'@ "Customization page list exclusion"
$gui = Replace-Once $gui @'
                        Tab::Settings => self.settings_page(ui, actions),
'@ @'
                        Tab::Settings => self.settings_page(ui, actions),
                        Tab::Customization => self.customization_page(ui, actions),
'@ "Customization page route"

$oldRows = @'
        let rows = [
            (Tab::Overview, "Overview", "Your workspace"),
            (Tab::Rivals, "RIVALS Workspace", "Game-specific profiles"),
            (Tab::Studio, "Config Studio", "Build and edit JSON"),
            (Tab::AssetIds, "Asset ID Editor", "RIVALS asset IDs"),
            (Tab::All, "Asset Library", "RIVALS-tagged assets only"),
            (Tab::Packs, "Game Library", "Community and local packs"),
            (Tab::Settings, "Settings", "Appearance and behavior"),
        ];
        for (index, (tab, label, hint)) in rows.iter().enumerate() {
            let now = ui.input(|i| i.time);
            let seen = *self.nav_seen.entry(label).or_insert(now);
            let t = if self.settings.animations { theme::ease_out(((now - seen) as f32 - index as f32 * 0.035) / 0.32) } else { 1.0 };
            if t < 1.0 { ui.ctx().request_repaint(); }
            let (rect, response) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 52.0), egui::Sense::click());
            let response = response.on_hover_cursor(egui::CursorIcon::PointingHand);
            let selected = self.tab == *tab || (*tab == Tab::All && matches!(self.tab, Tab::Live | Tab::Group(_) | Tab::Other));
            if selected {
                ui.painter().rect_filled(rect.shrink2(Vec2::new(8.0, 2.0)), CornerRadius::same(9), alpha(theme::ACCENT, 0.16));
                ui.painter().rect_filled(Rect::from_min_size(rect.left_top() + Vec2::new(8.0, 10.0), Vec2::new(3.0, rect.height() - 20.0)), CornerRadius::same(2), theme::ACCENT);
            } else if response.hovered() {
                ui.painter().rect_filled(rect.shrink2(Vec2::new(8.0, 2.0)), CornerRadius::same(9), alpha(theme::RAISED, 0.8));
            }
            let x = rect.left() + 23.0;
            ui.painter().text(egui::pos2(x, rect.center().y - 6.0), egui::Align2::LEFT_CENTER, *label, egui::FontId::proportional(14.0), alpha(if selected { theme::TEXT } else { theme::TEXT }, t));
            ui.painter().text(egui::pos2(x, rect.center().y + 11.0), egui::Align2::LEFT_CENTER, *hint, egui::FontId::proportional(10.5), alpha(theme::MUTED, t));
            if response.clicked() { actions.push(Action::ShowTab(*tab)); }
        }
'@
$newRows = @'
        let rows = [
            (Tab::Configs, "▤", "Config Manager", "Active skin and removal rules"),
            (Tab::Rivals, "◆", "RIVALS Workspace", "Game-specific profiles"),
            (Tab::Studio, "✎", "Config Builder", "Create and edit replacement rules"),
            (Tab::Overview, "⌂", "Overview", "Your workspace"),
            (Tab::AssetIds, "#", "Asset ID Editor", "Bulk ID management"),
            (Tab::All, "▦", "Asset Library", "RIVALS catalogue"),
            (Tab::Packs, "◇", "Game Library", "Community and local packs"),
            (Tab::Customization, "✦", "Customization", "Theme, layout and motion"),
            (Tab::Settings, "⚙", "Settings", "Cache behavior and application"),
        ];
        for (index, (tab, glyph, label, hint)) in rows.iter().enumerate() {
            let now = ui.input(|i| i.time);
            let seen = *self.nav_seen.entry(label).or_insert(now);
            let entrance = if self.settings.animations { theme::ease_out(((now - seen) as f32 - index as f32 * 0.028) / 0.30) } else { 1.0 };
            if entrance < 1.0 { ui.ctx().request_repaint(); }
            let row_height = if self.settings.compact_layout { 46.0 } else { 52.0 };
            let (rect, response) = ui.allocate_exact_size(Vec2::new(ui.available_width(), row_height), egui::Sense::click());
            let response = response.on_hover_cursor(egui::CursorIcon::PointingHand);
            let selected = self.tab == *tab || (*tab == Tab::All && matches!(self.tab, Tab::Live | Tab::Group(_) | Tab::Other));
            let active = if self.settings.animations {
                ui.ctx().animate_value_with_time(egui::Id::new(("nav-active", label)), if selected { 1.0 } else { 0.0 }, 0.17)
            } else { if selected { 1.0 } else { 0.0 } };
            let hover = if self.settings.animations {
                ui.ctx().animate_bool_with_time(egui::Id::new(("nav-hover", label)), response.hovered(), 0.12)
            } else { if response.hovered() { 1.0 } else { 0.0 } };
            if active > 0.001 {
                ui.painter().rect_filled(rect.shrink2(Vec2::new(8.0, 2.0)), CornerRadius::same(10), alpha(theme::accent(), 0.16 * active));
                ui.painter().rect_filled(Rect::from_min_size(rect.left_top() + Vec2::new(8.0, 9.0), Vec2::new(3.0, rect.height() - 18.0)), CornerRadius::same(2), alpha(theme::accent(), active));
            } else if hover > 0.001 {
                ui.painter().rect_filled(rect.shrink2(Vec2::new(8.0, 2.0)), CornerRadius::same(10), alpha(theme::RAISED, 0.75 * hover));
            }
            let show_icon = self.settings.show_nav_icons;
            let icon_x = rect.left() + 25.0;
            let label_x = rect.left() + if show_icon { 48.0 } else { 23.0 };
            if show_icon {
                ui.painter().text(egui::pos2(icon_x, rect.center().y), egui::Align2::CENTER_CENTER, *glyph,
                    egui::FontId::proportional(if self.settings.compact_layout { 15.0 } else { 17.0 }),
                    alpha(if selected { theme::accent() } else { theme::MUTED }, entrance));
            }
            ui.painter().text(egui::pos2(label_x, rect.center().y - 6.0), egui::Align2::LEFT_CENTER, *label,
                egui::FontId::proportional(if self.settings.compact_layout { 13.0 } else { 14.0 }),
                alpha(theme::TEXT, entrance));
            if !self.settings.compact_layout {
                ui.painter().text(egui::pos2(label_x, rect.center().y + 11.0), egui::Align2::LEFT_CENTER, *hint,
                    egui::FontId::proportional(10.0), alpha(theme::MUTED, entrance));
            }
            if response.clicked() { actions.push(Action::ShowTab(*tab)); }
        }
'@
$gui = Replace-Once $gui $oldRows $newRows "icon navigation with Config Manager pinned first"

# The Customization page is the single place for visual preferences.
$customPage = @'
    fn customization_page(&mut self, ui: &mut egui::Ui, _actions: &mut Vec<Action>) {
        self.page_header(ui, "Customization", "Make Prlngzz Editor feel right for you. Changes are saved locally and preview immediately.");
        let mut accent_changed = false;
        let mut density_changed = false;
        let mut preferences_changed = false;
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("ACCENT COLOUR").strong());
            ui.label(egui::RichText::new("Choose the highlight colour used by selected tabs, focus states and interactive controls.").color(theme::MUTED).small());
            egui::ComboBox::from_id_salt("custom-accent-palette")
                .selected_text(match self.settings.accent.as_str() {
                    "blue" => "Ocean blue",
                    "cyan" => "Electric cyan",
                    "rose" => "Soft rose",
                    "amber" => "Warm amber",
                    _ => "Prlngzz violet",
                })
                .show_ui(ui, |ui| {
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "violet".into(), "Prlngzz violet").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "blue".into(), "Ocean blue").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "cyan".into(), "Electric cyan").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "rose".into(), "Soft rose").changed();
                    accent_changed |= ui.selectable_value(&mut self.settings.accent, "amber".into(), "Warm amber").changed();
                });
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("Live preview").color(theme::MUTED));
                theme::pill(ui, "Accent sample", theme::accent());
            });
        });
        ui.add_space(10.0);
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("LAYOUT").strong());
            ui.label(egui::RichText::new("Tune density and navigation for your screen size.").color(theme::MUTED).small());
            density_changed |= ui.checkbox(&mut self.settings.compact_layout, "Compact layout").on_hover_text("Reduce spacing and navigation row height").changed();
            preferences_changed |= ui.checkbox(&mut self.settings.show_nav_icons, "Show sidebar icons").changed();
        });
        ui.add_space(10.0);
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("MOTION").strong());
            preferences_changed |= ui.checkbox(&mut self.settings.animations, "Enable animations and transitions").changed();
            ui.label(egui::RichText::new("Controls page transitions, sidebar easing and decorative motion. Disabling this keeps the interface still while preserving progress and status feedback.").color(theme::MUTED).small());
        });
        ui.add_space(10.0);
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("PERFORMANCE").strong());
            ui.label(egui::RichText::new("The RIVALS catalogue is parsed once and virtualized while scrolling. Compact mode and reduced motion lower UI work on smaller PCs.").color(theme::MUTED).small());
        });
        if accent_changed {
            theme::set_accent_name(&self.settings.accent);
            theme::apply_accent(ui.ctx());
            preferences_changed = true;
        }
        if density_changed { theme::apply_density(ui.ctx(), self.settings.compact_layout); }
        if preferences_changed || density_changed { self.settings.save(); }
    }

'@
$gui = Replace-Once $gui '    fn settings_page(&mut self, ui: &mut egui::Ui, _actions: &mut Vec<Action>) {' ($customPage + '    fn settings_page(&mut self, ui: &mut egui::Ui, _actions: &mut Vec<Action>) {') "Customization page implementation"
$oldAppearance = @'
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("APPEARANCE").strong());
            ui.label(egui::RichText::new("Prlngzz dark purple").color(theme::MUTED).small());
            ui.horizontal(|ui| {
                ui.colored_label(theme::ACCENT, "Accent #995CFF");
                ui.colored_label(theme::TEXT, "Text #F5F0FF");
                ui.colored_label(theme::BORDER, "Borders #302440");
            });
        });
        ui.add_space(10.0);
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("ANIMATIONS").strong());
            if ui.checkbox(&mut self.settings.animations, "Enable interface animations").changed() { self.settings.save(); }
            ui.label(egui::RichText::new("Turn off decorative transitions and motion effects. Operation status and real progress remain visible.").color(theme::MUTED).small());
        });
        ui.add_space(10.0);
'@
$gui = Replace-Once $gui $oldAppearance '' "move appearance controls into Customization"
$gui = Replace-Once $gui '        theme::apply(&cc.egui_ctx);' '' "defer theme until saved preferences load"
$gui = Replace-Once $gui @'
        let settings = Settings::load();
'@ @'
        let settings = Settings::load();
        theme::set_accent_name(&settings.accent);
        theme::apply(&cc.egui_ctx);
        theme::apply_density(&cc.egui_ctx, settings.compact_layout);
'@ "restore saved theme and density on startup"
Save-Source $guiPath $gui

# Broaden config import compatibility and fail clearly on unknown structures.
$configPath = Join-Path $Project "src/config.rs"
$config = [IO.File]::ReadAllText($configPath)
$oldTargets = @'
        let targets: Vec<Target> =
            obj.get("replace_ids").and_then(Value::as_array).map(|a| a.iter().filter_map(parse_target).collect()).unwrap_or_default();
'@
$newTargets = @'
        let target_values = obj.get("replace_ids")
            .or_else(|| obj.get("target_ids"))
            .or_else(|| obj.get("asset_ids"))
            .or_else(|| obj.get("targets"));
        let targets: Vec<Target> = match target_values {
            Some(Value::Array(values)) => values.iter().filter_map(parse_target).collect(),
            Some(single) => parse_target(single).into_iter().collect(),
            None => Vec::new(),
        };
'@
$config = Replace-Once $config $oldTargets $newTargets "compatible target field parsing"
$oldMode = @'
        let mode = match (text("mode"), obj.get("remove").and_then(Value::as_bool)) {
            (Some(m), _) => m.to_ascii_lowercase(),
            (None, Some(true)) => "remove".to_string(),
            _ => "id".to_string(),
        };
'@
$newMode = @'
        let native_action = obj.get("action").and_then(Value::as_object);
        let native_action_type = native_action.and_then(|action| action.get("type")).and_then(Value::as_str);
        let mode = match native_action_type {
            Some("remove") => "remove".to_string(),
            Some("local_file") => "local".to_string(),
            Some("https") => "cdn".to_string(),
            Some("asset_id") => "id".to_string(),
            _ => match (text("mode"), obj.get("remove").and_then(Value::as_bool)) {
                (Some(m), _) => m.to_ascii_lowercase(),
                (None, Some(true)) => "remove".to_string(),
                _ => "id".to_string(),
            },
        };
'@
$config = Replace-Once $config $oldMode $newMode "native action compatibility"
$config = Replace-Once $config '            "remove" => Action::Remove,' @'
            "remove" | "delete" | "remove_asset" => Action::Remove,
'@ "remove action aliases"
$config = Replace-Once $config @'
            "local" => match text("local_path") {
                Some(p) => Action::Local(absolute_or_beside(base, p)),
'@ @'
            "local" | "local_file" | "file" => match text("local_path").or_else(|| native_action.and_then(|action| action.get("path")).and_then(Value::as_str).map(str::trim).filter(|value| !value.is_empty())) {
                Some(p) => Action::Local(absolute_or_beside(base, p)),
'@ "local action aliases"
$config = Replace-Once $config @'
            "cdn" => match text("cdn_url") {
                Some(url) if url.starts_with("https://") => Action::Cdn(url.to_string()),
'@ @'
            "cdn" | "url" | "https" => match text("cdn_url").or_else(|| native_action.and_then(|action| action.get("url")).and_then(Value::as_str).map(str::trim).filter(|value| !value.is_empty())) {
                Some(url) if url.starts_with("https://") => Action::Cdn(url.to_string()),
'@ "remote action aliases"
$config = Replace-Once $config '            "id" => match obj.get("with_id") {' '            "id" | "asset_id" | "replace" => match obj.get("with_id").or_else(|| obj.get("replacement_id")).or_else(|| native_action.and_then(|action| action.get("asset_id"))) {' "replacement ID aliases"
$config = Replace-Once $config @'
        Value::Object(obj) => obj.get("replacement_rules").and_then(Value::as_array).map_or(&[][..], Vec::as_slice),
'@ @'
        Value::Object(obj) => obj.get("replacement_rules").or_else(|| obj.get("rules"))
            .and_then(Value::as_array)
            .context("the config object must contain a replacement_rules or rules array")?,
'@ "clear config root validation"
$noHandsTests = @'
    #[test]
    fn accepts_no_hands_remove_rules_with_multiple_targets() {
        let rules = parse(r#"{"replacement_rules":[{"name":"No Hands","replace_ids":[123,456],"mode":"remove"}]}"#, Path::new(".")).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].targets, [Target::Asset(123), Target::Asset(456)]);
        assert_eq!(rules[0].action, Action::Remove);
    }

    #[test]
    fn accepts_skinchanger_replacement_aliases_and_rules_root() {
        let rules = parse(r#"{"rules":[{"name":"Skin swap","targets":[123,456],"mode":"asset_id","replacement_id":"789"}]}"#, Path::new(".")).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].targets, [Target::Asset(123), Target::Asset(456)]);
        assert_eq!(rules[0].action, Action::With(Target::Asset(789)));
    }

    #[test]
    fn rejects_unknown_config_objects_instead_of_treating_them_as_empty() {
        assert!(parse(r#"{"name":"No Hands","items":[]}"#, Path::new(".")).is_err());
    }

'@
$config = Replace-Once $config '    fn accepts_a_bare_list_and_rejects_garbage() {' ($noHandsTests + '    fn accepts_a_bare_list_and_rejects_garbage() {') "config compatibility regression tests"
Save-Source $configPath $config

# Add a first-class Remove target action for no-hands-style local cache profiles.
$studioPath = Join-Path $Project "src/studio.rs"
$studio = [IO.File]::ReadAllText($studioPath)
$studio = Replace-Once $studio @'
            Value::Object(object) => {
                let items = object.get("replacement_rules").and_then(Value::as_array)
                    .context("The Fleasion configuration has no replacement_rules array")?;
'@ @'
            Value::Object(object) => {
                let items = object.get("replacement_rules").or_else(|| object.get("rules")).and_then(Value::as_array)
                    .context("The configuration has no replacement_rules or rules array")?;
'@ "profile import rules alias"
$studio = Replace-Once $studio 'targets": object.get("replace_ids").and_then(Value::as_array).cloned().unwrap_or_default(),' 'targets": object.get("replace_ids").or_else(|| object.get("target_ids")).or_else(|| object.get("targets")).and_then(Value::as_array).cloned().unwrap_or_default(),' "profile import target aliases"
$removeMethod = @'
    /// Removes a Roblox asset ID or a specific 32-hex cache-entry key.
    pub fn add_remove_rule(&mut self, target: &str) -> Result<()> {
        let target = target.trim();
        let target = match target.parse::<u64>() {
            Ok(id) if id > 0 => json!(id),
            _ => {
                ensure!(target.len() == 32 && target.bytes().all(|b| b.is_ascii_hexdigit()),
                    "Target must be a positive Roblox asset ID or a 32-character cache entry ID");
                json!(target.to_ascii_lowercase())
            }
        };
        let rules = self.raw.get_mut("rules").and_then(Value::as_array_mut).context("The profile rules field must be an array")?;
        let mut sequence = count_rules(rules) + 1;
        while rule_id_exists(rules, &format!("rule-{sequence:03}")) { sequence += 1; }
        rules.push(json!({
            "id": format!("rule-{sequence:03}"),
            "name": "Remove target asset",
            "enabled": true,
            "targets": [target],
            "action": { "type": "remove" },
            "notes": "Local cache removal rule; Roblox may download the original again after a cache refresh."
        }));
        Ok(())
    }

'@
$studio = Replace-Once $studio '    /// Adds a local replacement to a Roblox asset ID or a 32-hex cache-entry ID.' ($removeMethod + '    /// Adds a local replacement to a Roblox asset ID or a 32-hex cache-entry ID.') "native remove-rule constructor"
Save-Source $studioPath $studio

# Add a multi-ID removal action beside the local-file Config Builder.
$guiPath = Join-Path $Project "src/gui.rs"
$gui = [IO.File]::ReadAllText($guiPath)
$guiRemoveHelper = @'
    fn add_studio_remove_rules(&mut self) -> anyhow::Result<usize> {
        let raw = self.studio_target_input.trim();
        let mut targets = Vec::new();
        let mut seen = HashSet::new();
        for token in raw.split(|ch: char| ch.is_whitespace() || ch == ',' || ch == ';') {
            let token = token.trim().trim_matches('"');
            if token.is_empty() { continue; }
            if token.len() == 32 && token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                let key = token.to_ascii_lowercase();
                if seen.insert(key.clone()) { targets.push(key); }
            } else if let Ok(id) = token.parse::<u64>() {
                if id > 0 {
                    let value = id.to_string();
                    if seen.insert(value.clone()) { targets.push(value); }
                }
            } else {
                for id in crate::studio::extract_asset_ids(token) {
                    if id > 0 {
                        let value = id.to_string();
                        if seen.insert(value.clone()) { targets.push(value); }
                    }
                }
            }
        }
        anyhow::ensure!(!targets.is_empty(), "Paste one or more target asset IDs or cache-entry keys");
        for target in &targets { self.studio_doc.add_remove_rule(target)?; }
        self.studio_target_input.clear();
        Ok(targets.len())
    }

'@
$gui = Replace-Once $gui '    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {' ($guiRemoveHelper + '    fn add_studio_rules(&mut self) -> anyhow::Result<usize> {') "multi-ID remove rule helper"
$gui = Replace-Once $gui @'
            if ui.add(primary_button("Add to Config")).clicked() {
                match self.add_studio_local_rules() {
                    Ok(count) => self.studio_status = format!("Added {count} local replacement rule(s)."),
                    Err(error) => self.studio_status = format!("Could not add local rule: {error:#}"),
                }
            }
'@ @'
            ui.horizontal_wrapped(|ui| {
                if ui.add(primary_button("Add to Config")).clicked() {
                    match self.add_studio_local_rules() {
                        Ok(count) => self.studio_status = format!("Added {count} local replacement rule(s)."),
                        Err(error) => self.studio_status = format!("Could not add local rule: {error:#}"),
                    }
                }
                if ui.button("Remove target(s)").on_hover_text("Create a no-hands-style rule that removes every pasted target from the local cache").clicked() {
                    match self.add_studio_remove_rules() {
                        Ok(count) => self.studio_status = format!("Added {count} removal rule(s). Preview / Apply to cache to apply them."),
                        Err(error) => self.studio_status = format!("Could not add removal rule: {error:#}"),
                    }
                }
            });
'@ "No Hands removal action in Config Builder"

# Explain cache-only application and stale target IDs in the Config Manager.
$gui = Replace-Once $gui @'
        self.page_header(
            ui,
            "Applied Configurations",
            "Replacement rules that stay applied. What is switched on is put on whatever Roblox downloads; what is switched off is put back.",
        );
'@ @'
        self.page_header(
            ui,
            "Config Manager",
            "Manage skin swaps, local file replacements and removal profiles. Enabled rules are applied to matching entries in the local Roblox cache.",
        );
        card(ui, 1.0, |ui| {
            ui.label(egui::RichText::new("CACHE APPLY NOTES").strong().color(theme::accent()));
            ui.label(egui::RichText::new("Close Roblox before applying when possible, then relaunch it to see the changes. RIVALS can change asset IDs after updates. A rule that shows 0 matches needs current target IDs or a cache entry selected directly in Asset ID Editor.").color(theme::MUTED).small());
        });
        ui.add_space(8.0);
'@ "Config Manager cache and stale-ID guidance"

# Cache and virtualize the RIVALS catalogue rather than reparsing/cloning it on every frame.
$catalogHelpers = @'
fn rivals_asset_catalog() -> &'static [serde_json::Value] {
    static CATALOG: std::sync::OnceLock<Vec<serde_json::Value>> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        let catalog: serde_json::Value = serde_json::from_str(include_str!("../rivals_asset_catalog.json")).unwrap_or_default();
        catalog.get("assets").and_then(serde_json::Value::as_array).cloned().unwrap_or_default()
    }).as_slice()
}

fn rivals_catalog_search_text() -> &'static [String] {
    static SEARCH: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    SEARCH.get_or_init(|| {
        rivals_asset_catalog().iter().map(|asset| {
            let id = asset.get("id").and_then(serde_json::Value::as_str).unwrap_or("");
            let name = asset.get("name").and_then(serde_json::Value::as_str).unwrap_or("");
            let category = asset.get("category").and_then(serde_json::Value::as_str).unwrap_or("");
            let variant = asset.get("variant").and_then(serde_json::Value::as_str).unwrap_or("");
            format!("{category} {name} {variant} {id}").to_lowercase()
        }).collect()
    }).as_slice()
}

'@
$gui = Replace-Once $gui 'fn rivals_asset_ids() -> &' ($catalogHelpers + 'fn rivals_asset_ids() -> &') "cached RIVALS catalogue helpers"
$oldAssets = @'
            let catalog: serde_json::Value = serde_json::from_str(include_str!("../rivals_asset_catalog.json")).unwrap_or_default();
            let assets = catalog.get("assets").and_then(serde_json::Value::as_array).cloned().unwrap_or_default();
            let total = assets.len();
'@
$newAssets = @'
            let assets = rivals_asset_catalog();
            let total = assets.len();
            let matches: Vec<usize> = rivals_catalog_search_text().iter().enumerate()
                .filter_map(|(index, text)| (query.is_empty() || text.contains(&query)).then_some(index))
                .collect();
'@
$gui = Replace-Once $gui $oldAssets $newAssets "one-time catalogue parse and cached search"
$oldRows = @'
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                ui.label(egui::RichText::new(format!("{total} curated RIVALS asset IDs")).color(theme::MUTED).small());
                for asset in assets {
                    let id = asset.get("id").and_then(serde_json::Value::as_str).unwrap_or("");
                    let name = asset.get("name").and_then(serde_json::Value::as_str).unwrap_or("RIVALS asset");
                    let category = asset.get("category").and_then(serde_json::Value::as_str).unwrap_or("RIVALS");
                    let variant = asset.get("variant").and_then(serde_json::Value::as_str).unwrap_or("");
                    let haystack = format!("{category} {name} {variant} {id}").to_lowercase();
                    if !query.is_empty() && !haystack.contains(&query) { continue; }
                    let row_enter = ui.ctx().animate_value_with_time(egui::Id::new(("rivals-catalog-entry-enter", id)), 1.0, 0.20);
                    ui.add_space((1.0 - row_enter) * 4.0);
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(category).color(theme::MUTED).small());
                        ui.label(name);
                        if !variant.is_empty() { ui.label(egui::RichText::new(variant).color(theme::MUTED).small()); }
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui.small_button("Use in Config").clicked() { selected_id = Some(id.to_owned()); }
                            ui.monospace(id);
                        });
                    });
                    ui.separator();
                }
            });
'@
$newRows = @'
            ui.label(egui::RichText::new(format!("{total} curated IDs · {} shown", matches.len())).color(theme::MUTED).small());
            egui::ScrollArea::vertical().auto_shrink([false, false]).show_rows(ui, 34.0, matches.len(), |ui, visible| {
                for row in visible {
                    let asset = &assets[matches[row]];
                    let id = asset.get("id").and_then(serde_json::Value::as_str).unwrap_or("");
                    let name = asset.get("name").and_then(serde_json::Value::as_str).unwrap_or("RIVALS asset");
                    let category = asset.get("category").and_then(serde_json::Value::as_str).unwrap_or("RIVALS");
                    let variant = asset.get("variant").and_then(serde_json::Value::as_str).unwrap_or("");
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(category).color(theme::MUTED).small());
                        ui.label(name);
                        if !variant.is_empty() { ui.label(egui::RichText::new(variant).color(theme::MUTED).small()); }
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui.small_button("Use in Config").clicked() { selected_id = Some(id.to_owned()); }
                            ui.monospace(id);
                        });
                    });
                    ui.separator();
                }
            });
'@
$gui = Replace-Once $gui $oldRows $newRows "virtualized RIVALS catalogue rows"
$gui = $gui.Replace('theme::ACCENT', 'theme::accent()')
Save-Source $guiPath $gui

# Non-GUI surfaces retain the brand's default accent; the interactive editor uses the selected palette.
