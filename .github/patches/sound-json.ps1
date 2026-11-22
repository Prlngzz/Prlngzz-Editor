param([Parameter(Mandatory=$true)][string]$Project)
$ErrorActionPreference = 'Stop'
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$What) {
    $Text = $Text.Replace(([string][char]13 + [char]10), [string][char]10)
    $Old = $Old.Replace(([string][char]13 + [char]10), [string][char]10)
    $New = $New.Replace(([string][char]13 + [char]10), [string][char]10)
    $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($count -ne 1) { throw "Expected exactly one '$What' block; found $count" }
    return $Text.Replace($Old, $New)
}
function Save-Source([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
$configPath = Join-Path $Project 'src/config.rs'
$config = [IO.File]::ReadAllText($configPath)
$helper = @'
/// Extracts an asset ID from the URL Roblox stored beside a cached response.
/// This is the authoritative local mapping for assets whose public delivery is
/// restricted (notably many RIVALS audio assets).
pub(crate) fn asset_id_from_cache_url(url: &str) -> Option<u64> {
    let (_, rest) = url.split_once("://")?;
    let host = rest.split('/').next()?.to_ascii_lowercase();
    if !(host == "roblox.com"
        || host.ends_with(".roblox.com")
        || host == "rbxcdn.com"
        || host.ends_with(".rbxcdn.com"))
    {
        return None;
    }
    if let Some((_, query)) = rest.split_once('?') {
        for pair in query.split('&') {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            if matches!(key.to_ascii_lowercase().as_str(), "id" | "assetid" | "asset_id") {
                if let Ok(id) = value.parse::<u64>() {
                    if id > 0 { return Some(id); }
                }
            }
        }
    }
    let path = rest.split('?').next()?;
    let segments: Vec<&str> = path.split('/').collect();
    for pair in segments.windows(2) {
        if pair[0].eq_ignore_ascii_case("assetid") {
            if let Ok(id) = pair[1].parse::<u64>() {
                if id > 0 { return Some(id); }
            }
        }
    }
    None
}

'@
$config = Replace-Once $config ("struct Resolver<'a> {" + [Environment]::NewLine) ($helper + "struct Resolver<'a> {" + [Environment]::NewLine) 'cache URL asset-ID resolver'
$old = @'
            Target::Asset(n) => {
                let prints = self
                    .idmap
                    .assets
                    .get(&n.to_string())
                    .ok_or_else(|| Miss::Problem(format!("{target} was never looked up")))?;
'@
$new = @'
            Target::Asset(n) => {
                // Roblox's cache wrapper retains the original request URL. Use it
                // before anonymous asset delivery fingerprints: this also resolves
                // private/restricted audio IDs without manual linking.
                let from_url: Vec<usize> = self
                    .entries
                    .iter()
                    .enumerate()
                    .filter_map(|(i, entry)| {
                        (replaceable(entry) && asset_id_from_cache_url(&entry.url) == Some(*n))
                            .then_some(i)
                    })
                    .collect();
                if !from_url.is_empty() {
                    return Ok(from_url);
                }
                let prints = self
                    .idmap
                    .assets
                    .get(&n.to_string())
                    .ok_or_else(|| Miss::Problem(format!("{target} was never looked up")))?;
'@
$config = Replace-Once $config $old $new 'asset resolver URL-first lookup'
$testNeedle = @'
#[cfg(test)]
mod tests {
    use super::*;
'@
$testBlock = @'
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_url_asset_ids_support_roblox_audio_delivery_urls() {
        assert_eq!(
            asset_id_from_cache_url("https://assetdelivery.roblox.com/v1/asset/?id=16530229616"),
            Some(16530229616)
        );
        assert_eq!(
            asset_id_from_cache_url("https://assetdelivery.roblox.com/v2/assetId/135097031120155"),
            Some(135097031120155)
        );
        assert_eq!(asset_id_from_cache_url("https://example.com/?id=123"), None);
        assert_eq!(asset_id_from_cache_url("https://assetdelivery.roblox.com/?id=0"), None);
    }
'@
$config = Replace-Once $config $testNeedle $testBlock 'cache URL resolver tests'
Save-Source $configPath $config

$resolvePath = Join-Path $Project 'src/resolve.rs'
$resolve = [IO.File]::ReadAllText($resolvePath)
$resolve = Replace-Once $resolve 'use crate::config::{fingerprint, Fingerprint, IdMap};' 'use crate::config::{asset_id_from_cache_url, fingerprint, Fingerprint, IdMap};' 'resolver cache URL import'
$loop = @'
    for &id in ids {
        for fp in idmap
'@
$loopReplacement = @'
    for &id in ids {
        // The cache wrapper preserves Roblox's original asset URL. Prefer this
        // local ID mapping for restricted sounds before attempting public delivery.
        if entries.iter().any(|entry| {
            entry.wrapped
                && !matches!(entry.kind, "redirect" | "missing" | "empty")
                && asset_id_from_cache_url(&entry.url) == Some(id)
        }) {
            outcomes.insert(id, Outcome::Known);
            continue;
        }
        for fp in idmap
'@
$resolve = Replace-Once $resolve $loop $loopReplacement 'identify cached asset IDs from original request URLs'
Save-Source $resolvePath $resolve
$cargoPath = Join-Path $Project 'Cargo.toml'
$cargo = [IO.File]::ReadAllText($cargoPath)
$cargo = [regex]::Replace($cargo, '(?m)^version = "0\.3\.(50|51)"$', 'version = "0.3.52"')
if ($cargo -notmatch '(?m)^version = "0\.3\.52"$') { throw 'Could not update Cargo.toml to 0.3.52' }
Save-Source $cargoPath $cargo

$lockPath = Join-Path $Project 'Cargo.lock'
$lock = [IO.File]::ReadAllText($lockPath)
$lock = [regex]::Replace($lock, '(\[\[package\]\]\s*name = "prlngzz-editor"\s*version = ")0\.3\.(50|51)(")', [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    return $match.Groups[1].Value + '0.3.52' + $match.Groups[3].Value
})
if ($lock -notmatch '(?s)\[\[package\]\]\s*name = "prlngzz-editor"\s*version = "0\.3\.52"') { throw 'Could not update Cargo.lock to 0.3.52' }
Save-Source $lockPath $lock

$changelogPath = Join-Path $Project 'changelog.json'
$changelog = [IO.File]::ReadAllText($changelogPath)
$changelog = $changelog.Replace('"version": "0.3.51"', '"version": "0.3.52"')
$changelog = $changelog.Replace('"version": "0.3.50"', '"version": "0.3.52"')
$changelog = $changelog.Replace('"0.3.51": {', '"0.3.52": {')
$changelog = $changelog.Replace('"0.3.50": {', '"0.3.52": {')
$changelog = [regex]::Replace($changelog, '(?s)("0\.3\.52"\s*:\s*\{\s*"title"\s*:\s*")[^"]+', '$1Automatic sound config matching', 1)
if ($changelog -notmatch '0\.3\.52') { throw 'Could not update changelog to 0.3.52' }
Save-Source $changelogPath $changelog
