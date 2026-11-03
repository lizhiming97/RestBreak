#!/usr/bin/env python3
"""Build the separate GPL companion; never installs or launches it."""
import argparse
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from signing import select_identity, verify_signed_certificate

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = (args.output or root / 'dist').resolve()
out.mkdir(parents=True, exist_ok=True)
command = ['swift', 'build', '--build-system', 'native', '--package-path', str(root), '-c', args.configuration]
subprocess.run(command, check=True)
bin_dir = Path(subprocess.check_output(command + ['--show-bin-path'], text=True).strip())
identity = select_identity(os.environ.get('FRIDAY_COMPANION_SIGN_IDENTITY'))
source = out / 'MenuBarCompanion-source.tar.gz'
with tarfile.open(source, 'w:gz') as archive:
    for name in ['Package.swift', 'LICENSE', 'README.md', 'UPSTREAM.md', 'ShelfLab.entitlements', 'Sources', 'Tests', 'scripts']:
        archive.add(root / name, arcname='MenuBarCompanion/' + name,
                    filter=lambda info: None if '__pycache__' in Path(info.name).parts else info)
with tempfile.TemporaryDirectory(prefix='friday-companion-') as temp:
    app = Path(temp) / '星期五菜单栏.app'
    contents = app / 'Contents'
    macos = contents / 'MacOS'
    resources = contents / 'Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(bin_dir / 'ShelfLab', macos / 'ShelfLab')
    os.chmod(macos / 'ShelfLab', 0o755)
    info = {
        'CFBundleExecutable': 'ShelfLab', 'CFBundleIdentifier': 'com.lizhiming.MenuBarShelfLab',
        'CFBundleName': '星期五菜单栏', 'CFBundleDisplayName': '星期五菜单栏',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1.0',
        'LSMinimumSystemVersion': '14.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': 'Derived from Ice by Jordan Baird and contributors; GPL-3.0',
        'CFBundleURLTypes': [{'CFBundleURLName': 'com.lizhiming.MenuBarShelfLab', 'CFBundleURLSchemes': ['friday-menubar']}],
    }
    with (contents / 'Info.plist').open('wb') as f: plistlib.dump(info, f)
    shutil.copy2(root / 'LICENSE', resources / 'LICENSE-GPL-3.0.txt')
    shutil.copy2(root / 'UPSTREAM.md', resources / 'UPSTREAM.md')
    shutil.copy2(source, resources / source.name)
    sign = ['codesign', '--force', '--options', 'runtime', '--sign', identity]
    # App Group 以团队 ID 为前缀，只有正式证书签名时才加；本地 ad-hoc 构建不写快照，星期五菜单显示为未启用。
    if identity != '-':
        sign += ['--entitlements', str(root / 'ShelfLab.entitlements')]
    subprocess.run(sign + [str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(app)], check=True)
    if identity != '-':
        verify_signed_certificate(app)
    destination = out / app.name
    if destination.exists():
        existing = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
        if existing.get('CFBundleIdentifier') != info['CFBundleIdentifier']:
            raise SystemExit('Refusing to replace a different application')
        shutil.rmtree(destination)
    shutil.copytree(app, destination)
print(destination)
