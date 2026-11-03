#!/usr/bin/env python3
"""Build a removable mouse helper and optionally embed it in a signed Friday app.

No installing, launching, permission changes, or release publishing.
"""
import argparse
import hashlib
import pathlib
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parent


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def signing_authority(app):
    # 同名开发证书可能同时存在，必须用主程序实际签名证书的摘要，而不是 Common Name。
    with tempfile.TemporaryDirectory(prefix="friday-mouse-certificate-") as folder:
        prefix = pathlib.Path(folder) / "cert"
        run("codesign", "-d", "--extract-certificates=" + str(prefix), app, capture_output=True)
        leaf = pathlib.Path(str(prefix) + "0")
        if not leaf.exists():
            raise RuntimeError("The main app has no certificate; pass --identity explicitly for a local build.")
        run("security", "verify-cert", "-c", leaf, "-p", "codeSign", "-R", "ocsp", "-R", "require", capture_output=True, timeout=30)
        return hashlib.sha1(leaf.read_bytes()).hexdigest().upper()


def sign(app, identity, entitlements=None):
    args = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
    if entitlements:
        args += ["--entitlements", entitlements]
    run(*args, app)
    run("codesign", "--verify", "--deep", "--strict", app)


def source_filter(info):
    parts = pathlib.PurePosixPath(info.name).parts
    if any(part in {".build", ".swiftpm", "dist", "__pycache__", ".DS_Store"} for part in parts):
        return None
    return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--main-app", type=pathlib.Path, help="Copy this existing signed Friday build and embed helper")
    parser.add_argument("--build-friday", action="store_true", help="Build the main app in this worktree first")
    parser.add_argument("--identity", help="Override signing identity; '-' is explicit ad-hoc signing")
    args = parser.parse_args()
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    source_app = args.main_app
    if args.build_friday:
        derived = dist / "DerivedData"
        run("xcodebuild", "build", "-scheme", "RestBreak", "-configuration", "Release",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", derived,
            "-allowProvisioningUpdates", "ONLY_ACTIVE_ARCH=YES", "-quiet", cwd=REPO / "RestBreak")
        source_app = derived / "Build/Products/Release/RestBreak.app"
    if source_app:
        source_app = source_app.resolve()
        info = plistlib.loads((source_app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "com.lizhiming.RestBreak":
            raise RuntimeError("--main-app must be a Friday app with its existing bundle identifier")
    identity = args.identity or (signing_authority(source_app) if source_app else "-")
    run("swift", "build", "--build-system", "native", "--package-path", ROOT, "-c", "release")
    binary_dir = pathlib.Path(run("swift", "build", "--build-system", "native", "--package-path", ROOT,
                                 "-c", "release", "--show-bin-path", capture_output=True, text=True).stdout.strip())
    helper = dist / "星期五鼠标.app"
    if helper.exists():
        shutil.rmtree(helper)
    macos = helper / "Contents/MacOS"
    resources = helper / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(binary_dir / "FridayMouse", macos / "FridayMouse")
    (helper / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.lizhiming.FridayMouse",
        "CFBundleName": "星期五鼠标", "CFBundleDisplayName": "星期五鼠标",
        "CFBundleExecutable": "FridayMouse", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "CFBundleURLTypes": [{"CFBundleURLName": "Friday Mouse", "CFBundleURLSchemes": ["friday-mouse"]}],
    }))
    for name in ["LICENSE", "UPSTREAM.md", "README.md"]:
        shutil.copy2(ROOT / name, resources / name)
    with tarfile.open(resources / "FridayMouse-source.tar.gz", "w:gz") as archive:
        archive.add(ROOT, arcname="MouseCompanion", filter=source_filter)
    # 与星期五共用 App Group：读星期五写的设置、写回运行状态。组件本身不开沙盒。
    sign(helper, identity, ROOT / "FridayMouse.entitlements")
    print(f"Helper: {helper}")
    if source_app:
        combined = dist / "星期五.app"
        if source_app == combined.resolve():
            raise RuntimeError("Source and output apps must differ")
        if combined.exists():
            shutil.rmtree(combined)
        run("ditto", source_app, combined)
        destination = combined / "Contents/Helpers/星期五鼠标.app"
        destination.parent.mkdir(exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)
        run("ditto", helper, destination)
        # 保存主程序原有沙盒/App Group 权限；不把 helper 的权限带给主程序。
        entitlements = run("codesign", "-d", "--entitlements", ":-", source_app, capture_output=True).stdout
        parsed = plistlib.loads(entitlements)
        if parsed.get("com.apple.security.app-sandbox") is not True:
            raise RuntimeError("Expected sandboxed Friday main app")
        with tempfile.NamedTemporaryFile(suffix=".plist") as output:
            output.write(plistlib.dumps(parsed)); output.flush()
            sign(combined, identity, output.name)
        print(f"Friday with removable helper: {combined}")


if __name__ == "__main__":
    main()
