import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export function inspectFile(filename, bytes) {
  const issues = [];
  const name = filename.replaceAll('\\', '/');
  if (/(^|\/)(?:\.idea|\.hvigor|\.npm-cache|node_modules|oh_modules|build|test-artifacts)(?:\/|$)/i.test(name)) issues.push('local or generated directory');
  if (/\.(?:p12|pfx|p7b|p7c|cer|crt|csr|pem|key|jks|keystore|hap|hsp|app|ipa|mobileprovision|log)$/i.test(name)) issues.push('signing material, package, or log');
  if (/(^|\/)(?:local\.properties|build-profile\.local\.json5|\.env(?:\..*)?)$/i.test(name)) issues.push('local configuration');
  const text = Buffer.from(bytes).toString('utf8');
  if (text.includes('\0')) issues.push('binary content requires separate review');
  if (/-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/.test(text)) issues.push('private key');
  if (/(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})/.test(text)) issues.push('access token');
  if (/\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b/.test(text)) issues.push('private network address');
  if (/[A-Z]:[\\/]+(?:Users[\\/]|prg[\\/])/i.test(text)) issues.push('personal filesystem path');
  for (const match of text.matchAll(/\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b/ig)) {
    if (!/^(?:AA:BB:CC:DD:EE:|11:22:33:44:55:|00:00:00:00:00:)/i.test(match[0])) issues.push('device address');
  }
  if (name === 'build-profile.json5') {
    try {
      const config = JSON.parse(text);
      if (!Array.isArray(config.app?.signingConfigs) || config.app.signingConfigs.length !== 0) issues.push('nonempty or unverifiable signing configuration');
      if (config.app?.products?.some(product => product.signingConfig)) issues.push('product references a personal signing configuration');
    } catch { issues.push('build profile cannot be checked'); }
  }
  return [...new Set(issues)];
}

function main() {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const staged = process.argv.includes('--staged');
  const revisionIndex = process.argv.indexOf('--revision');
  const revision = revisionIndex >= 0 ? process.argv[revisionIndex + 1] : undefined;
  if (revisionIndex >= 0 && !revision) throw new Error('Missing revision');
  const git = process.env.GIT_EXE || 'git';
  const run = args => execFileSync(git, args, { cwd: root, maxBuffer: 16 * 1024 * 1024 });
  const files = run(revision ? ['ls-tree', '-r', '--name-only', '-z', revision] : ['ls-files', '--cached', '-z']).toString('utf8').split('\0').filter(Boolean);
  if (!files.length) throw new Error('No tracked files to inspect');
  const failures = [];
  for (const filename of files) {
    const bytes = staged || revision ? run(['show', (revision || '') + ':' + filename]) : fs.readFileSync(path.join(root, filename));
    const issues = inspectFile(filename, bytes);
    if (issues.length) failures.push({ file: filename, issues });
  }
  if (failures.length) {
    for (const failure of failures) console.error(failure.file + ': ' + failure.issues.join('; '));
    process.exitCode = 1;
  } else {
    console.log('Publication check passed: ' + files.length + ' files; no signing configuration or detected private data.');
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
