// The manifest version is what the store and the device report; the constant
// in source/Version.mc is what the screen shows. They have to agree, and no
// Connect IQ API reads the manifest at runtime, so this check keeps them so.
import { readFileSync } from "node:fs";

const manifest = readFileSync("manifest.xml", "utf8").match(/\bversion="(\d+\.\d+\.\d+)"/);
const source = readFileSync("source/Version.mc", "utf8").match(/APP_VERSION = "(\d+\.\d+\.\d+)"/);

if (!manifest || !source) {
  console.error("check_version: could not find a version in manifest.xml or source/Version.mc");
  process.exit(1);
}
if (manifest[1] !== source[1]) {
  console.error(`check_version: manifest.xml says ${manifest[1]} but source/Version.mc says ${source[1]}`);
  process.exit(1);
}
console.log(`version ${manifest[1]} (manifest and source agree)`);
