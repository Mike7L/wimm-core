#!/usr/bin/env python3
"""Content receipts for the packaging step; SwiftPM still checks every build.

Only hashes are persisted. Never put environment values (including API keys)
into a receipt or diagnostic output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ENV_KEYS = (
    'WIMM_APP_ENTITLEMENTS', 'WIMM_MAC_PROFILE', 'WIMM_MAC_BUNDLE_ID',
    'WIMM_CLI_BUNDLE_ID', 'WIMM_MARKETING_VERSION', 'WIMM_CURRENT_PROJECT_VERSION',
    'CODESIGN_ID', 'ALLOW_ADHOC', 'WIMM_BUILD_SIGNING_IDENTITIES',
    'WIMM_FAST_SYNC_RESOURCES',
    'GEMINI_API_KEY', 'GEMINI_API_KEYS', 'OPENROUTER_API_KEY', 'OPENROUTER_API_KEYS',
)


def digest_paths(paths):
    digest = hashlib.sha256()

    def add(path, label):
        digest.update(json.dumps(label).encode())
        if path.is_symlink():
            digest.update(b'link' + os.fsencode(os.readlink(path)))
        elif path.is_dir():
            digest.update(b'dir')
            for child in sorted(path.iterdir()):
                add(child, label + '/' + child.name)
        elif path.is_file():
            digest.update(b'file' + str(path.stat().st_mode & 0o111).encode())
            with path.open('rb') as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b''):
                    digest.update(block)
        else:
            digest.update(b'missing')

    for label, path in sorted(paths.items()):
        add(path, label)
    return digest.hexdigest()


def input_digest(root, binary, cli, kind='wimm'):
    if kind == 'studio':
        paths = {str(p): p for p in (
            binary, root / 'scripts/make_studio.sh', root / 'scripts/app_update_cache.py',
            root / 'WimmLocal.entitlements', root / 'WimmDevCloud.entitlements',
            root / 'Apps/WimmStudio/Info.plist',
        )}
        for name in ('FluidAudio_FluidAudio.bundle', 'WimmCore_WimmInfrastructure.bundle'):
            path = binary.parent / name
            paths[str(path)] = path
        # The CloudKit profile make_studio.sh embeds, found the same way as in
        # make_app.sh; a newly installed or renewed profile must repackage.
        for directory in ('Library/Developer/Xcode/UserData/Provisioning Profiles',
                          'Library/MobileDevice/Provisioning Profiles'):
            for path in (Path.home() / directory).glob('*.provisionprofile'):
                paths[str(path)] = path
        if os.environ.get('WIMM_MAC_PROFILE'):
            path = Path(os.environ['WIMM_MAC_PROFILE']).resolve()
            paths[str(path)] = path
        metadata = {key: os.environ.get(key, '') for key in (
            'CODESIGN_ID', 'ALLOW_ADHOC', 'WIMM_BUILD_SIGNING_IDENTITIES',
        )}
        metadata['files'] = digest_paths(paths)
        return hashlib.sha256(json.dumps(metadata, sort_keys=True).encode()).hexdigest()
    paths = {str(p): p for p in (
        binary, cli, root / 'AppBundle/Info.plist',
        root / 'Sources/WimmCLI/Info.plist', root / 'Sources/WimmCLI/entitlements.plist',
        root / 'scripts/make_app.sh', root / 'scripts/app_update_cache.py',
        root / 'Assets/Wimm.icns', root / 'Wimm.icns',
        Path('/System/Library/Frameworks/Automator.framework/Versions/A/Resources/Speech.icns'),
        root / 'Packages/WimmCore/Sources/WimmInfrastructure/Resources/Prompts',
    )}
    if not (root / 'Packages/WimmCore/Sources/WimmInfrastructure/Resources/Prompts').is_dir():
        for base in ('Sources', 'Packages'):
            for path in (root / base).glob('**/Resources/Prompts'):
                paths[str(path)] = path
    for path in root.glob('Wimm*.entitlements'):
        paths[str(path)] = path
    for path in binary.parent.glob('*.bundle'):
        paths[str(path)] = path
    # Match the profile search performed by make_app.sh, including newly added
    # profiles. Explicit paths are inputs too, even when outside the checkout.
    for directory in ('Library/Developer/Xcode/UserData/Provisioning Profiles',
                      'Library/MobileDevice/Provisioning Profiles'):
        for path in (Path.home() / directory).glob('*.provisionprofile'):
            paths[str(path)] = path
    for key in ('WIMM_APP_ENTITLEMENTS', 'WIMM_MAC_PROFILE'):
        if os.environ.get(key):
            path = Path(os.environ[key]).resolve()
            paths[str(path)] = path
    revision = subprocess.run(
        ['git', '-C', str(root), 'rev-list', '--count', 'HEAD'],
        capture_output=True, text=True,
    ).stdout.strip()
    metadata = {key: os.environ.get(key, '') for key in ENV_KEYS}
    metadata['revision'] = revision or '1'
    metadata['files'] = digest_paths(paths)
    return hashlib.sha256(json.dumps(metadata, sort_keys=True).encode()).hexdigest()


def output_digest(root, kind='wimm'):
    names = ('Wimm Studio.app',) if kind == 'studio' else ('Wimm.app', 'WimmCLI.app')
    return digest_paths({name: root / name for name in names})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'record'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--cli', type=Path)
    parser.add_argument('--kind', choices=('wimm', 'studio'), default='wimm')
    args = parser.parse_args()
    if args.kind == 'wimm' and args.cli is None:
        parser.error('--cli is required for Wimm')
    receipt = args.root / f'.build/{args.kind}-update-receipt.json'
    try:
        current = {'schema': 1, 'inputs': input_digest(args.root, args.binary, args.cli, args.kind),
                   'outputs': output_digest(args.root, args.kind)}
        if args.action == 'check':
            if json.loads(receipt.read_text()) != current:
                return 1
        # A receipt never substitutes for checking the installed signatures.
        names = ('Wimm Studio.app',) if args.kind == 'studio' else ('Wimm.app', 'WimmCLI.app')
        for name in names:
            result = subprocess.run(
                ['codesign', '--verify', '--deep', '--strict', str(args.root / name)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if result.returncode:
                return 1
        if args.action == 'record':
            receipt.parent.mkdir(parents=True, exist_ok=True)
            staged = receipt.with_suffix(f'.{os.getpid()}.tmp')
            staged.write_text(json.dumps(current) + '\n')
            staged.replace(receipt)
        return 0
    except (OSError, ValueError):
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
