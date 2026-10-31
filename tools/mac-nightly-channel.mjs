#!/usr/bin/env node
/**
 * Turns a clean janhq/jan v0.8.8 checkout into a nightly-channel build on
 * macOS, the same way Jan's own CI does it, so Cowork is enabled and the app
 * keeps the nightly identity (data folder, product name, binary name).
 *
 * Usage:
 *   node tools/mac-nightly-channel.mjs [--version 0.8.8-5712] [--with-mlx]
 *
 * Run it from the repo root (after `git apply` of the patch). It edits files by
 * relative path, so `cd <checkout> && node /abs/path/to/mac-nightly-channel.mjs`
 * works without copying this script into the tree.
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

const touched = [];

const pkgPath = 'web-app/package.json';
const pkg = JSON.parse(read(pkgPath));
pkg.version = version;
write(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
touched.push(`${pkgPath} version -> ${version}`);

const confPath = 'src-tauri/tauri.conf.json';
const conf = JSON.parse(read(confPath));
conf.version = version;
conf.productName = 'Jan-nightly';
conf.identifier = 'jan-nightly.ai.app';
conf.mainBinaryName = 'Jan-Desktop-nightly';
// A self-built binary is unsigned; letting the updater run would replace it
// with an official package on the first successful check.
if (conf.plugins?.updater) conf.plugins.updater.active = false;
// Upstream CI flips this to true and signs the artifacts with its own key. An
// unsigned build must not ask for a signing key, or bundling aborts.
conf.bundle = conf.bundle ?? {};
conf.bundle.createUpdaterArtifacts = false;
write(confPath, JSON.stringify(conf, null, 2) + '\n');
touched.push(
  `${confPath} -> ${conf.productName} / ${conf.identifier} / ${conf.mainBinaryName}, updater off, no updater artifacts`
);

const cargoPath = 'src-tauri/Cargo.toml';
let cargo = read(cargoPath);
cargo = cargo
  .replace(/^version = "0\.8\.5"$/m, `version = "${version}"`)
  .replace(
    /^default-run = "Jan-Desktop"$/m,
    'default-run = "Jan-Desktop-nightly"'
  )
  .replace(/^name = "Jan-Desktop"$/m, 'name = "Jan-Desktop-nightly"');
write(cargoPath, cargo);
// mainBinaryName has to name a real Cargo bin target and default-run has to name
// the same one, so all three move together or the manifest stops parsing.
for (const need of ['Jan-Desktop-nightly', version]) {
  if (!cargo.includes(need)) {
    console.error(
      `Cargo.toml does not carry "${need}" -- the upstream baseline changed, check the replace patterns above`
    );
    process.exit(1);
  }
}
touched.push(`${cargoPath} -> package version ${version}, bin Jan-Desktop-nightly`);

// Info.plist ships inside the .app and still names the stable bundle id and
// URL scheme unless it is rewritten; Jan's own nightly script does this too.
const plistPath = 'src-tauri/Info.plist';
if (existsSync(plistPath)) {
  let plist = read(plistPath);
  plist = plist
    .replace(/jan\.ai\.app/g, 'jan-nightly.ai.app')
    .replace(/<string>jan<\/string>/g, '<string>jan-nightly</string>');
  write(plistPath, plist);
  touched.push(`${plistPath} -> bundle id jan-nightly.ai.app, scheme jan-nightly`);
}

const macPath = 'src-tauri/tauri.macos.conf.json';
if (existsSync(macPath)) {
  const mac = JSON.parse(read(macPath));
  if (!withMlx) {
    const before = mac.bundle?.resources ?? [];
    mac.bundle.resources = before.filter(
      (r) => !r.includes('mlx-server') && !r.includes('mlx-swift')
    );
    // tauri-build's generate_context! fails the build script on any declared
    // resource path that does not exist, and nothing here compiles mlx-server,
    // so those two entries have to go -- not merely be skipped at runtime.
    touched.push(
      `${macPath} resources: ${before.length} -> ${mac.bundle.resources.length} (MLX dropped)`
    );
  }
  // Single-arch build for Apple Silicon: no universal target, no lipo step.
  mac.bundle.targets = ['app', 'dmg'];
  write(macPath, JSON.stringify(mac, null, 2) + '\n');
  touched.push(`${macPath} targets -> app, dmg`);
}

for (const line of touched) console.log(`  ${line}`);
console.log(`channel ready: version ${version} (hyphen => isNightly => Cowork)`);
