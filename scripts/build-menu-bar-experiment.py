#!/usr/bin/env python3
"""Build the optional pair of applications; no install, launch, Git push or release."""
import argparse
import os
import sys
from pathlib import Path
import shutil
import subprocess
import plistlib

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path)
parser.add_argument('--derived-data', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = (args.output or root / '发布/星期五-菜单栏实验版').resolve()
derived = (args.derived_data or root / 'DerivedData/MenuBarExperiment').resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcodebuild', '-project', str(root/'RestBreak/RestBreak.xcodeproj'), '-scheme', 'RestBreak',
                '-configuration', 'Release', '-derivedDataPath', str(derived), '-allowProvisioningUpdates', 'build'], check=True)
product = derived / 'Build/Products/Release/RestBreak.app'
if not product.is_dir():
    raise SystemExit('RestBreak.app not found in build products')
target = out / '星期五.app'
if target.exists():
    info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.lizhiming.RestBreak':
        raise SystemExit('Refusing to replace a different application')
    shutil.rmtree(target)
shutil.copytree(product, target)
subprocess.run(['python3', str(root/'MenuBarCompanion/scripts/build_app.py'), '--configuration', 'release', '--output', str(out)], check=True)
# 组件作为独立程序放进星期五包内（Contents/Helpers），用户只装一个 App；二者仍是两个独立签名的程序。
helpers = target / 'Contents/Helpers'
helpers.mkdir(exist_ok=True)
companion = helpers / '星期五菜单栏.app'
shutil.move(str(out / '星期五菜单栏.app'), str(companion))
subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(companion)], check=True)
# 包内容变了，按原证书重签主程序，保留原有沙盒权限、签名要求和 hardened runtime 设置。
sys.path.insert(0, str(root / 'MenuBarCompanion/scripts'))
from signing import select_identity
identity = select_identity(os.environ.get('FRIDAY_COMPANION_SIGN_IDENTITY'))
subprocess.run(['codesign', '--force', '--sign', identity,
                '--preserve-metadata=entitlements,requirements,flags,runtime', str(target)], check=True)
subprocess.run(['codesign', '--verify', '--strict', '--deep', '--verbose=2', str(target)], check=True)
shutil.copy2(root/'MenuBarCompanion/README.md', out/'菜单栏组件-使用说明.md')
shutil.copy2(root/'MenuBarCompanion/LICENSE', out/'菜单栏组件-GPL-3.0.txt')
shutil.copy2(root/'LICENSE', out/'星期五主程序-MIT.txt')
print(out)
