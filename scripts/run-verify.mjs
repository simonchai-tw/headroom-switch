import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const script = path.join(root, 'verify-fix.ps1');
const systemRoot = process.env.SystemRoot;
const powershell = systemRoot
  ? path.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : null;

if (process.platform !== 'win32' || !powershell || !existsSync(powershell)) {
  console.error('Headroom Switch tests require Windows PowerShell 5.1 on Windows.');
  process.exit(1);
}

const result = spawnSync(
  powershell,
  ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script],
  {
    stdio: 'inherit',
    cwd: root,
    env: process.env,
  },
);

if (result.error) {
  console.error(result.error.message);
}

process.exit(result.status === null ? 1 : result.status);
