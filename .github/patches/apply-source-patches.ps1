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
$config = Replace-RegexOnce $config '(?s)(?m)^    pub fn merge\(&mut self, other: &IdMap\) -> usize \{.*?^    \}\r?\n' '' "unused IdMap merge method"
$config = Replace-RegexOnce $config '(?s)(?m)^    fn held_by\(&self, kind: &str, current: &\[u8\]\) -> bool \{.*?^    \}\r?\n' '' "unused unchecked payload ownership method"
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
