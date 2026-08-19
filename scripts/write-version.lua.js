#!/usr/bin/env node
// Write plugin/version.lua for WezTerm installs that cannot see package.json (e.g. Flatpak).
const fs = require("fs");
const path = require("path");

const version = process.argv[2];
if (!version || !/^\d+\.\d+/.test(version)) {
    console.error("usage: node scripts/write-version.lua.js <semver>");
    process.exit(1);
}

const body =
    "-- Bundled install version. semantic-release rewrites this via scripts/write-version.lua.js.\n" +
    '-- Keep in sync with package.json "version". Loaded with require("version") so the UI\n' +
    "-- can show a semver even when package.json / git are outside the Lua path (Flatpak).\n" +
    'return { version = "' +
    version +
    '" }\n';

const dest = path.join(__dirname, "..", "plugin", "version.lua");
fs.writeFileSync(dest, body);
console.log("wrote", dest, "version", version);
