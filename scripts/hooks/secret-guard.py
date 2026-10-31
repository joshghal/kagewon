#!/usr/bin/env python3
"""Stops a commit or a push that contains a private file or a secret saved on this Mac.

It compares against the API keys in config.json and the values in .env.local, byte for byte, in every file that is
staged or pushed (binary files and files with non-ASCII names included) and in commit messages. It never prints a key,
not even part of one. Install it with: npm run hooks
"""
import json, os, re, subprocess, sys

ROOT = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()
PRIVATE_PATH = re.compile(r'(^|/)(config\.json(\..*)?|\.env(\..*)?|\.helper\.pid|\.system-proxy\.json.*|.*\.(pem|key|p12|pfx)|id_(rsa|ed25519).*)$|(^|/)\.tor/')


def git(*args):
    return subprocess.run(['git', '-c', 'core.quotePath=false', *args], capture_output=True).stdout


def names(raw):
    """File names from NUL separated output (-z), so odd characters are never quoted or lost."""
    return [n for n in raw.decode('utf-8', 'replace').split('\0') if n]


def saved_secrets():
    found = set()
    try:
        for p in json.load(open(os.path.join(ROOT, 'config.json'))).get('providers', []):
            key = p.get('apiKey')
            if isinstance(key, str) and len(key) >= 8:
                found.add(key)
    except Exception:
        pass
    try:
        for line in open(os.path.join(ROOT, '.env.local')):
            m = re.match(r'\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.*)$', line)
            if m:
                value = m.group(1).strip().strip('\'"')
                if len(value) >= 12:
                    found.add(value)
    except Exception:
        pass
    return found


def main():
    mode, refs = sys.argv[1], sys.argv[2:]
    secrets = [s.encode() for s in saved_secrets()]
    if not secrets:
        print('secret guard: no saved key found on this machine, so only file names are checked', file=sys.stderr)
    leaks = lambda blob: any(s in blob for s in secrets)
    problems = []

    if mode == 'staged':
        for name in names(git('diff', '--cached', '-z', '--name-only', '--diff-filter=ACMR')):
            if PRIVATE_PATH.search(name):
                problems.append(f'{name} is a private file and must not be committed')
            elif leaks(git('cat-file', 'blob', f':{name}')):
                problems.append(f'{name} contains a secret saved on this Mac')
    else:
        for sha in refs:
            if leaks(git('log', '-1', '--format=%B%n%an%n%ae', sha)):
                problems.append(f'the message of commit {sha[:8]} contains a secret saved on this Mac')
            for name in names(git('diff-tree', '-z', '--no-commit-id', '--name-only', '-r', '--root', '-m', '--diff-filter=ACMR', sha)):
                if PRIVATE_PATH.search(name):
                    problems.append(f'commit {sha[:8]} contains the private file {name}')
                elif leaks(git('cat-file', 'blob', f'{sha}:{name}')):
                    problems.append(f'commit {sha[:8]} has a secret saved on this Mac in {name}')

    if problems:
        print('\nBLOCKED by the secret guard:', file=sys.stderr)
        for p in sorted(set(problems)):
            print(f'  - {p}', file=sys.stderr)
        print('Remove it (and rewrite history if it is already committed) before trying again.\n', file=sys.stderr)
        sys.exit(1)


main()
