-- Bundled install version. semantic-release rewrites this via scripts/write-version.lua.js.
-- Keep in sync with package.json "version". Loaded with require("version") so the UI
-- can show a semver even when package.json / git are outside the Lua path (Flatpak).
return { version = "1.17.0" }
