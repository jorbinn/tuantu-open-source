"""Check tracked public files without printing possible secret values.

This is a guardrail, not a complete privacy or license audit. Run Gitleaks too.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
forbidden_suffixes = {'.onnx', '.apk', '.ipa', '.aab', '.db', '.sqlite', '.sqlite3',
                      '.p8', '.p12', '.pfx', '.pem', '.key', '.jks', '.keystore',
                      '.mobileprovision', '.uuid', '.har'}
rules = {
    'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'GitHub credential': r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})',
    'AWS access key': r'\bAKIA[A-Z0-9]{16}\b',
    'personal filesystem path': r'(?:[A-Z]:[\\/]+Users[\\/]+|/Users/)[A-Za-z0-9_.-]+',
    'Apple device id': r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b',
    'populated Apple team': r'DEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}"?;',
}
issues = []
for name in filter(None, paths):
    path = ROOT / name
    if path.suffix.lower() in forbidden_suffixes or name.startswith(('data/', 'output/', 'evidence/', '.dsh/')):
        issues.append(f'{name}: forbidden private/binary asset type')
    if name.endswith(('hotspot.local.json', 'key.properties', 'local.properties')):
        issues.append(f'{name}: local configuration')
    if name == 'scripts/check_public_source.py':
        continue
    try:
        content = path.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    for label, pattern in rules.items():
        for match in re.finditer(pattern, content):
            issues.append(f'{name}:{content[:match.start()].count(chr(10)) + 1}: {label}')
if issues:
    print('\n'.join(issues))
    raise SystemExit(1)
print(f'Public source checks passed ({len(list(filter(None, paths)))} tracked files)')
