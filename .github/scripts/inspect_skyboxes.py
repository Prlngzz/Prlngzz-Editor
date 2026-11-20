import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from urllib.parse import quote

ARCHIVE = pathlib.Path("SkyboxImages/SKyboxes.zip")
INDEX = pathlib.Path(".github/assets/sky-library-index.json")
PROFILE_DIR = pathlib.Path(".github/assets/skies")
OUTPUT_DIR = pathlib.Path(".github/assets/sky-faces")
MANIFEST_PATH = pathlib.Path("skybox-archive-manifest.json")
MAP_PATH = pathlib.Path(".github/assets/sky-face-map.json")
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tga", ".dds", ".tex"}
SIDES = {
    "Back": ("back", "bk", "bck"),
    "Down": ("down", "dn", "dw"),
    "Front": ("front", "ft", "fr"),
    "Left": ("left", "lf", "lt"),
    "Right": ("right", "rt"),
    "Up": ("up", "top"),
}
NON_FACE_WORDS = {"logo", "text", "avatar", "name", "preview", "thumb", "thumbnail", "icon", "frame"}

def norm(value: str) -> str:
    return value.replace("\\", "/").lstrip("./").casefold()

def safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    return slug or "sky"

def strip_image_extensions(filename: str) -> str:
    value = pathlib.PurePosixPath(filename).name.casefold()
    while pathlib.PurePosixPath(value).suffix.lower() in IMAGE_EXTENSIONS:
        value = pathlib.PurePosixPath(value).stem
    return value

def face_score(filename: str, aliases: tuple[str, ...]) -> int | None:
    stem = strip_image_extensions(filename)
    compact = re.sub(r"[^a-z0-9]+", "_", stem).strip("_")
    tokens = set(compact.split("_"))
    words = re.findall(r"[a-z0-9]+", stem)
    penalty = 8 * len(tokens.intersection(NON_FACE_WORDS))
    if "onyx" in tokens or "xen" in tokens or "nyx" in tokens or "v2" in tokens:
        penalty += 3
    scores = []
    for alias in aliases:
        if alias in tokens:
            scores.append(10)
        elif stem == alias:
            scores.append(0)
        elif compact == alias:
            scores.append(0)
        elif stem.endswith(alias):
            scores.append(20)
        elif stem.startswith(alias):
            scores.append(25)
        elif alias in words:
            scores.append(15)
        elif len(alias) >= 4 and alias in stem:
            scores.append(30)
        elif alias == "down" and stem.startswith("ddown"):
            scores.append(28)
        elif len(alias) <= 2 and (stem.endswith(alias) or stem.startswith(alias)):
            scores.append(35)
    return min(scores) + penalty if scores else None

def choose_faces(files: list[str]) -> tuple[dict[str, str], dict[str, list[str]]]:
    selected: dict[str, str] = {}
    candidates: dict[str, list[str]] = {}
    for side, aliases in SIDES.items():
        ranked = []
        for filename in files:
            score = face_score(filename, aliases)
            if score is not None:
                ranked.append((score, filename.casefold(), filename))
        if ranked:
            ranked.sort()
            selected[side] = ranked[0][2]
            candidates[side] = [item[2] for item in ranked]
    return selected, candidates

def seven_zip_path() -> str | None:
    found = shutil.which("7z") or shutil.which("7za")
    if found:
        return found
    for root in (os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)")):
        if root:
            candidate = pathlib.Path(root) / "7-Zip" / "7z.exe"
            if candidate.is_file():
                return str(candidate)
    return None

def read_archive_images(outer: zipfile.ZipFile, actual_name: str, archive_type: str):
    if archive_type == "zip" or actual_name.lower().endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(outer.read(actual_name))) as inner:
            members = [
                x.filename for x in inner.infolist()
                if not x.is_dir() and pathlib.PurePosixPath(x.filename).suffix.lower() in IMAGE_EXTENSIONS
            ]
            data = {name: inner.read(name) for name in members}
        return data, None
    if archive_type == "rar" or actual_name.lower().endswith(".rar"):
        seven_zip = seven_zip_path()
        if not seven_zip:
            return {}, "7-Zip is not installed; cannot extract RAR archive"
        with tempfile.TemporaryDirectory(prefix="skybox-rar-") as temp_dir:
            rar_path = pathlib.Path(temp_dir) / pathlib.PurePosixPath(actual_name).name
            rar_path.write_bytes(outer.read(actual_name))
            output = pathlib.Path(temp_dir) / "extracted"
            output.mkdir()
            try:
                subprocess.run([seven_zip, "x", "-y", str(rar_path), f"-o{output}"], check=True, capture_output=True, text=True)
            except Exception as exc:
                return {}, f"RAR extraction failed: {exc}"
            data = {}
            for path in output.rglob("*"):
                if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
                    data[path.relative_to(output).as_posix()] = path.read_bytes()
            return data, None
    return {}, f"unsupported archive type: {actual_name}"

def convert_to_supported_image(data: bytes, source_name: str) -> tuple[bytes, str]:
    ext = pathlib.PurePosixPath(source_name).suffix.lower()
    if ext in {".png", ".jpg", ".jpeg", ".webp", ".gif"}:
        return data, ext
    try:
        from PIL import Image
        image = Image.open(io.BytesIO(data))
        image.load()
        output = io.BytesIO()
        image.convert("RGBA").save(output, format="PNG", optimize=True)
        return output.getvalue(), ".png"
    except Exception as exc:
        raise ValueError(f"cannot convert {source_name} ({ext}) to PNG: {exc}") from exc

def main() -> None:
    if not ARCHIVE.is_file() or ARCHIVE.stat().st_size < 1_000_000:
        size = ARCHIVE.stat().st_size if ARCHIVE.exists() else 0
        raise SystemExit(f"Git LFS archive was not materialized: {ARCHIVE} ({size} bytes)")
    index = json.loads(INDEX.read_text(encoding="utf-8"))
    branch = os.environ.get("GITHUB_REF_NAME", "codex/sky-library-gallery-functional-v031")
    map_base = f"https://media.githubusercontent.com/media/Prlngzz/Prlngzz-Editor/{branch}/"
    records = []
    face_map = {}
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(ARCHIVE) as outer:
        outer_names = outer.namelist()
        pathlib.Path("skybox-outer-entries.txt").write_text("\\n".join(outer_names) + "\\n", encoding="utf-8")
        for outer_name in outer_names:
            print(f"OUTER|{outer_name}")
        outer_entries = {norm(name): name for name in outer_names}
        print(f"Outer sky archive: {ARCHIVE.stat().st_size:,} bytes; {len(outer_entries)} entries")
        for item in index["items"]:
            name = item["name"]
            requested = norm(item["archive"])
            actual = outer_entries.get(requested)
            if actual is None:
                leaf = pathlib.PurePosixPath(requested).name
                actual = next((entry for key, entry in outer_entries.items()
                               if pathlib.PurePosixPath(key).name == leaf), None)
            record = {
                "name": name, "archive": item["archive"], "actual_archive": actual,
                "members": [], "selected_faces": {}, "candidate_faces": {}, "missing_faces": [],
                "error": None,
            }
            if actual is None:
                record["error"] = "archive missing from parent ZIP"
            else:
                data, error = read_archive_images(outer, actual, item.get("archive_type", "zip"))
                record["members"] = sorted(data.keys())
                record["error"] = error
                if not error and data:
                    chosen, candidates = choose_faces(list(data.keys()))
                    record["candidate_faces"] = candidates
                    slug = safe_slug(name)
                    urls = {}
                    for side, source_name in chosen.items():
                        try:
                            converted, ext = convert_to_supported_image(data[source_name], source_name)
                        except ValueError as exc:
                            record["error"] = str(exc)
                            continue
                        relative = pathlib.Path(".github/assets/sky-faces") / slug / f"{side.casefold()}{ext}"
                        target = pathlib.Path(relative)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(converted)
                        url = map_base + quote(relative.as_posix(), safe="/")
                        urls[side] = url
                        record["selected_faces"][side] = {
                            "source": source_name, "path": relative.as_posix(), "url": url,
                        }
                    record["missing_faces"] = [side for side in SIDES if side not in urls]
                    if urls:
                        face_map[name] = urls
            detail = record["error"] or "; ".join(
                f"{side}={record['selected_faces'][side]['source']}" for side in record["selected_faces"]
            )
            print(f"SKY|{name}|{len(record['selected_faces'])}/6 faces|{detail}")
            records.append(record)

    MANIFEST_PATH.write_text(json.dumps(records, indent=2), encoding="utf-8")
    MAP_PATH.parent.mkdir(parents=True, exist_ok=True)
    MAP_PATH.write_text(json.dumps(face_map, indent=2), encoding="utf-8")
    complete = sum(1 for item in records if len(item["selected_faces"]) == 6 and not item["error"])
    partial = len(records) - complete
    total_bytes = sum(path.stat().st_size for path in OUTPUT_DIR.rglob("*") if path.is_file())
    print(f"SUMMARY|{complete}/{len(records)} complete six-face skyboxes|{partial} incomplete|{total_bytes:,} extracted bytes")
    if len(records) != 65:
        raise SystemExit(f"Expected 65 indexed skies, received {len(records)}")
    if partial:
        incomplete = [f"{x['name']}: missing={','.join(x['missing_faces']) or x['error'] or 'unknown'}"
                      for x in records if len(x["selected_faces"]) != 6 or x["error"]]
        print("INCOMPLETE_SKIES|" + " | ".join(incomplete))

if __name__ == "__main__":
    main()
