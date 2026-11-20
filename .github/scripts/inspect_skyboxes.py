import io
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import zipfile

ARCHIVE = pathlib.Path("SkyboxImages/SKyboxes.zip")
INDEX = pathlib.Path(".github/assets/sky-library-index.json")
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga", ".dds"}

def norm(value: str) -> str:
    return value.replace("\\", "/").lstrip("./").casefold()

def image_members(archive: zipfile.ZipFile):
    return [
        item.filename for item in archive.infolist()
        if not item.is_dir() and pathlib.PurePosixPath(item.filename).suffix.lower() in IMAGE_EXTENSIONS
    ]

def rar_members(data: bytes):
    seven_zip = shutil.which("7z") or shutil.which("7za")
    if not seven_zip:
        return [], "7-Zip is not installed on this runner"
    path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".rar", delete=False) as tmp:
            tmp.write(data)
            path = tmp.name
        result = subprocess.run([seven_zip, "l", "-slt", path], text=True, capture_output=True, check=True)
        names = []
        for line in result.stdout.splitlines():
            if line.startswith("Path = "):
                name = line[7:].strip()
                if pathlib.PurePosixPath(name).suffix.lower() in IMAGE_EXTENSIONS:
                    names.append(name)
        return names, None
    except Exception as exc:
        return [], f"RAR listing failed: {exc}"
    finally:
        if path and os.path.exists(path):
            os.unlink(path)

def main():
    if not ARCHIVE.is_file() or ARCHIVE.stat().st_size < 1_000_000:
        size = ARCHIVE.stat().st_size if ARCHIVE.exists() else 0
        raise SystemExit(f"Git LFS archive was not materialized: {ARCHIVE} ({size} bytes)")
    index = json.loads(INDEX.read_text(encoding="utf-8"))
    records = []
    with zipfile.ZipFile(ARCHIVE) as outer:
        outer_entries = {norm(name): name for name in outer.namelist()}
        print(f"Outer sky archive: {ARCHIVE.stat().st_size:,} bytes; {len(outer_entries)} entries")
        for item in index["items"]:
            requested = norm(item["archive"])
            actual = outer_entries.get(requested)
            if actual is None:
                leaf = pathlib.PurePosixPath(requested).name
                actual = next((name for key, name in outer_entries.items() if pathlib.PurePosixPath(key).name == leaf), None)
            record = {"name": item["name"], "archive": item["archive"], "members": [], "error": None}
            if actual is None:
                record["error"] = "archive missing from parent ZIP"
            elif actual.lower().endswith(".zip"):
                try:
                    with zipfile.ZipFile(io.BytesIO(outer.read(actual))) as inner:
                        record["members"] = image_members(inner)
                except Exception as exc:
                    record["error"] = f"nested ZIP failed: {exc}"
            elif actual.lower().endswith(".rar"):
                record["members"], record["error"] = rar_members(outer.read(actual))
            else:
                record["error"] = f"unsupported archive type: {actual}"
            records.append(record)
            detail = record["error"] or "; ".join(record["members"])
            print(f"SKY|{item['name']}|{len(record['members'])} images|{detail}")
    pathlib.Path("skybox-archive-manifest.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
    readable = sum(1 for record in records if not record["error"] and record["members"])
    print(f"SUMMARY|{readable}/{len(records)} readable sky archives")
    if len(records) != 65:
        raise SystemExit(f"Expected 65 indexed skies, received {len(records)}")

if __name__ == "__main__":
    main()
