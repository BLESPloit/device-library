-- Pixel Buds 2a: match by device name in manifest scan_conditions.
-- Lua observer (non-manifest-only) so the pack does not push manifest.name into scan-row display_name;
-- icon + tint come from manifest assets via FingerprintScriptRunner.applyManifestObserverUiDefaults.

function parse(input)
  return {}, {}
end
