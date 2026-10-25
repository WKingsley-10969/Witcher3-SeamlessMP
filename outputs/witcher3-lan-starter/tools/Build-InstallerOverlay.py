"""Add tested installer scripts to the pinned existing LAN package; no game data or runtimes."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import zipfile

BASE_SHA256 = "2cc7700ee5def09aa533c6d0cc1d8ec3817cb883dd02d160f130f5697daf6ef5"
FILES = [
    "W3ModInstall.psm1", "W3LanProfile.psm1", "Install-LAN.ps1", "Install-Copy.ps1",
    "Remove-LAN.ps1", "Manage-Mod.ps1", "Manage Mod.cmd", "Remove Mod.cmd",
    "Setup LAN.cmd", "Play-LAN.ps1", "README.md", "INSTALL-UPDATE-REMOVE.md",
    "tests/Test-Install.ps1", "tests/Test-InstallPackage.ps1",
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-zip", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    with args.base_zip.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != BASE_SHA256:
            raise SystemExit("Base package checksum differs. Identify the intended package before building.")
    source = Path(__file__).resolve().parents[1]
    mapping = {name: source / name for name in FILES}
    mapping["TEST-RESULTS.md"] = source / "GAME-TEST-RESULTS.md"
    for file in mapping.values():
        if not file.is_file():
            raise SystemExit(f"Missing installer source: {file.name}")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    complete = args.output_dir / "Witcher3-LAN-0.2.0-dev-inplace.zip"
    update = args.output_dir / "Witcher3-LAN-installer-update.zip"
    prefix = "Witcher3-LAN-0.2.0-dev/"
    with zipfile.ZipFile(args.base_zip) as old, zipfile.ZipFile(complete, "w", zipfile.ZIP_DEFLATED) as out:
        seen = set()
        for entry in old.infolist():
            name = entry.filename
            p = PurePosixPath(name)
            if not name.startswith(prefix) or "\\" in name or ".." in p.parts or name.lower() in seen:
                raise SystemExit("Unexpected or duplicate path in pinned package")
            seen.add(name.lower())
            if name[len(prefix):] not in mapping:
                out.writestr(entry, old.read(entry))
        for name, file in mapping.items():
            data = file.read_bytes()
            if name.endswith(".cmd"):
                data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            out.writestr(prefix + name, data)
    with zipfile.ZipFile(update, "w", zipfile.ZIP_DEFLATED) as out:
        for name, file in mapping.items():
            data = file.read_bytes()
            if name.endswith(".cmd"):
                data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            out.writestr(name, data)
    # Every game payload/manifest byte must remain identical to the pinned base.
    with zipfile.ZipFile(args.base_zip) as old, zipfile.ZipFile(complete) as new:
        for name in old.namelist():
            if name.startswith(prefix + "mod/") or name == prefix + "mod-manifest.json":
                if old.read(name) != new.read(name):
                    raise SystemExit("Game payload unexpectedly changed")
        bad = new.testzip()
        if bad:
            raise SystemExit(f"Archive CRC failure: {bad}")
    for archive in (complete, update):
        with archive.open("rb") as stream:
            checksum = hashlib.file_digest(stream, "sha256").hexdigest()
        archive.with_suffix(".zip.sha256").write_text(checksum + "  " + archive.name + "\n", encoding="ascii")
        print(f"READY {archive.name} bytes={archive.stat().st_size} SHA256={checksum}")

if __name__ == "__main__":
    main()
