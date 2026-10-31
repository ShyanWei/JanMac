#!/usr/bin/env node
/**
 * Turns a clean janhq/jan v0.8.8 checkout into a nightly-channel build on
 * macOS, the same way Jan's own CI does it, so Cowork is enabled and the app
 * keeps the nightly identity (data folder, product name, binary name).
 *
 * Usage:
 *   node tools/mac-nightly-channel.mjs [--version 0.8.8-5712] [--with-mlx]
 *
 * Run it from the repo root (after `git apply` of the patch).
 *
 * MLX is dropped from the bundle unless --with-mlx, because building mlx-server
 * needs a Swift/xcodebuild step (Jan's CI caches it). llama.cpp with Metal is
 * unaffected; MLX-backed models simply are not offered in this build.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const argv = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const withMlx = argv.includes('--with-mlx');
const version = argOf('version', '0.8.8-5712');

const read = (p) => readFileSync(p, 'utf8');
const write = (p, text) => writeFileSync(p, text);

// Version with a hyphen is what makes `isNightly` true, which is what makes
// `isCoworkEnabled()` true. Without it the build has no Cowork surface at all.
if (!version.includes('-') || version.includes('beta')) {
  console.error(
    `--version must look nightly (a hyphen, no "beta"), got "${version}"`
  );
  process.exit(1);
}

const pkgPath = 'web-app/package.json';
const pkg = JSON.parse(read(pkgPath));
pkg.version = version;
write(pkgPath, JSON.stringify(pkg, null, 2) + '\n');

const confPath = 'src-tauri/tauri.conf.json';
const conf = JSON.parse(read(confPath));
conf.version = version;
conf.productName = 'Jan-nightly';
conf.identifier = 'jan-nightly.ai.app';
conf.mainBinaryName = 'Jan-Desktop-nightly';
// A self-built binary is unsigned; letting the updater run would replace it
// with an official package on the first successful check.
if (conf.plugins?.updater) conf.plugins.updater.active = false;
write(confPath, JSON.stringify(conf, null, 2) + '\n');

const cargoPath = 'src-tauri/Cargo.toml';
let cargo = read(cargoPath);
cargo = cargo
  .replace(/^version = "0\.8\.5"$/m, `version = "${version}"`)
  .replace(/^default-run = "Jan-Desktop"$/m, 'default-run = "Jan-Desktop-nightly"')
  .replace(/^name = "Jan-Desktop"$/m, 'name = "Jan-Desktop-nightly"');
write(cargoPath, cargo);

const macPath = 'src-tauri/tauri.macos.conf.json';
if (existsSync(macPath)) {
  const mac = JSON.parse(read(macPath));
  if (!withMlx) {
    mac.bundle.resources = (mac.bundle.resources ?? []).filter(
      (r) => !r.includes('mlx-server') && !r.includes('mlx-swift')
    );
    // The MLX plugin itself would still pull Swift-only code into the build on
    // Apple Silicon; Jan declares it as a macOS target dependency, so dropping
    // the resource is what keeps the bundle honest.
  }
  // Single-arch build for Apple Silicon: no universal target, no lipo step.
  mac.bundle.targets = ['app', 'dmg'];
  write(macPath, JSON.stringify(mac, null, 2) + '\n');
}

console.log(`channel: productName=${conf.productName} identifier=${conf.identifier}`);
console.log(`version: ${version} (hyphen => isNightly => Cowork enabled)`);
console.log(`mainBinaryName: ${conf.mainBinaryName}`);
console.log(`updater: active=${conf.plugins?.updater?.active}`);
console.log(`mlx bundled: ${withMlx ? 'yes' : 'no (dropped from resources)'}`);
