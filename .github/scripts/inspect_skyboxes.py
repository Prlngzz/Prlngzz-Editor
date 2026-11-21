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
OUTPUT_DIR = pathlib.Path(".github/assets/sky-faces")
MANIFEST_PATH = pathlib.Path("skybox-archive-manifest.json")
MAP_PATH = pathlib.Path(".github/assets/sky-face-map.json")
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tga", ".dds", ".tex", ".vtf"}
FACE_ALIASES = {
    "Back": ("bk", "back"),
    "Down": ("dn", "down"),
    "Front": ("ft", "front"),
    "Left": ("lf", "left"),
    "Right": ("rt", "right"),
    "Up": ("up", "top"),
}

def norm(value: str) -> str:
    return value.replace("\\", "/").strip("/").casefold()

def safe_slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "sky"

def face_match(path: str, aliases: tuple[str, ...]) -> bool:
    stem = pathlib.PurePosixPath(path).stem.casefold()
    compact = re.sub(r"[^a-z0-9]+", "", stem)
    return any(
        re.search(rf"(?:^|[^a-z0-9]){re.escape(alias)}$", stem)
        or compact.endswith(alias)
        for alias in aliases
    )

def face_rank(path: str) -> tuple[int, int, int, str]:
    lowered = path.casefold().replace("\\", "/")
    basename = pathlib.PurePosixPath(lowered).name
    if basename.startswith("sky512_"):
        family = 0
    elif basename.startswith("indoor512_"):
        family = 10
    elif basename.startswith("skys512_"):
        family = 15
    else:
        family = 25
    canonical_dir = 0 if "/platformcontent/pc/textures/sky/" in f"/{lowered}" else 3
    ext = pathlib.PurePosixPath(lowered).suffix
    ext_rank = {".tex": 0, ".vtf": 1, ".png": 2, ".jpg": 3, ".jpeg": 4, ".webp": 5}.get(ext, 9)
    return family, canonical_dir, ext_rank, lowered

def decode_texture(data: bytes, source_name: str) -> tuple[bytes, str, dict]:
    ext = pathlib.PurePosixPath(source_name).suffix.lower()
    image = None
    pillow_error = None
    try:
        from PIL import Image
        image = Image.open(io.BytesIO(data))
        image.load()
    except Exception as exc:
        pillow_error = str(exc)
        image = None

    if image is None and ext == ".vtf":
        try:
            from vtf2img import Parser
            with tempfile.NamedTemporaryFile(suffix=".vtf", delete=False) as tmp:
                tmp.write(data)
                temp_path = tmp.name
            try:
                image = Parser(temp_path).get_image()
                image.load()
            finally:
                os.unlink(temp_path)
        except Exception as exc:
            raise ValueError(
                f"VTF decode failed for {source_name}; magic={data[:16].hex()}; "
                f"Pillow={pillow_error}; vtf2img={exc}"
            ) from exc

    if image is None:
        raise ValueError(
            f"Texture decode failed for {source_name}; magic={data[:24].hex()}; "
            f"Pillow={pillow_error}"
        )

    info = {"source_format": getattr(image, "format", None), "width": image.width, "height": image.height}
    output = io.BytesIO()
    image.convert("RGBA").save(output, format="PNG", optimize=True)
    return output.getvalue(), ".png", info

def choose_faces(files: list[str]) -> tuple[dict[str, str], dict[str, list[str]]]:
    chosen = {}
    candidates = {}
    for side, aliases in FACE_ALIASES.items():
        ranked = [path for path in files if face_match(path, aliases)]
        ranked.sort(key=face_rank)
        if ranked:
            chosen[side] = ranked[0]
            candidates[side] = ranked
    return chosen, candidates

def main() -> None:
    if not ARCHIVE.is_file() or ARCHIVE.stat().st_size < 1_000_000:
        size = ARCHIVE.stat().st_size if ARCHIVE.exists() else 0
        raise SystemExit(f"Git LFS archive was not materialized: {ARCHIVE} ({size} bytes)")

    index = json.loads(INDEX.read_text(encoding="utf-8"))
    asset_branch = os.environ.get("SKY_ASSET_BRANCH", "sky-library-cdn-assets")
    media_base = f"https://media.githubusercontent.com/media/Prlngzz/Prlngzz-Editor/{asset_branch}/"
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    records = []
    face_map = {}

    with zipfile.ZipFile(ARCHIVE) as outer:
        outer_names = outer.namelist()
        pathlib.Path("skybox-outer-entries.txt").write_text("\n".join(outer_names) + "\n", encoding="utf-8")
        normalized_names = {norm(name): name for name in outer_names}
        print(f"Outer sky archive: {ARCHIVE.stat().st_size:,} bytes; {len(outer_names)} entries")

        for item in index["items"]:
            sky_name = item["name"]
            prefix = norm(f"Extracted Skies/{sky_name}/") + "/"
            files = [
                original for normalized, original in normalized_names.items()
                if normalized.startswith(prefix) and pathlib.PurePosixPath(original).suffix.lower() in IMAGE_EXTENSIONS
            ]
            record = {
                "name": sky_name,
                "archive": item["archive"],
                "archive_folder": f"Extracted Skies/{sky_name}/",
                "members": sorted(files),
                "selected_faces": {},
                "candidate_faces": {},
                "missing_faces": [],
                "errors": {},
                "error": None,
            }

            if not files:
                # Case-insensitive folder-name fallback for minor archive/index capitalization differences.
                leaf = norm(sky_name)
                alt_prefix = f"extracted skies/{leaf}/"
                files = [
                    original for normalized, original in normalized_names.items()
                    if normalized.startswith(alt_prefix) and pathlib.PurePosixPath(original).suffix.lower() in IMAGE_EXTENSIONS
                ]
                record["members"] = sorted(files)

            chosen, candidates = choose_faces(files)
            record["candidate_faces"] = candidates
            slug = safe_slug(sky_name)
            urls = {}

            for side in FACE_ALIASES:
                source_name = chosen.get(side)
                if not source_name:
                    record["missing_faces"].append(side)
                    continue
                try:
                    png_bytes, out_ext, details = decode_texture(outer.read(source_name), source_name)
                    relative = pathlib.Path(".github/assets/sky-faces") / slug / f"{side.casefold()}{out_ext}"
                    target = pathlib.Path(relative)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(png_bytes)
                    url = media_base + quote(relative.as_posix(), safe="/")
                    urls[side] = url
                    record["selected_faces"][side] = {
                        "source": source_name,
                        "path": relative.as_posix(),
                        "url": url,
                        **details,
                    }
                except Exception as exc:
                    record["errors"][side] = str(exc)
                    record["missing_faces"].append(side)

            if urls:
                face_map[sky_name] = urls

            status = f"{len(urls)}/6 faces"
            details = "; ".join(f"{side}={record['selected_faces'][side]['source']}" for side in record["selected_faces"])
            errors = "; ".join(f"{side}: {error}" for side, error in record["errors"].items())
            print(f"SKY|{sky_name}|{status}|{details}|{errors}")
            records.append(record)

    MANIFEST_PATH.write_text(json.dumps(records, indent=2), encoding="utf-8")
    MAP_PATH.parent.mkdir(parents=True, exist_ok=True)
    MAP_PATH.write_text(json.dumps(face_map, indent=2), encoding="utf-8")

    complete = sum(1 for record in records if len(record["selected_faces"]) == 6)
    missing = [record for record in records if len(record["selected_faces"]) != 6]
    total_bytes = sum(path.stat().st_size for path in OUTPUT_DIR.rglob("*") if path.is_file())
    print(f"SUMMARY|{complete}/{len(records)} complete six-face skyboxes|{len(missing)} incomplete|{total_bytes:,} extracted bytes")
    for record in missing:
        print(
            f"INCOMPLETE_SKY|{record['name']}|missing={','.join(record['missing_faces'])}|"
            f"errors={json.dumps(record['errors'], ensure_ascii=False)}"
        )
    if len(records) != len(index["items"]):
        raise SystemExit(f"Expected {len(index['items'])} indexed skies, received {len(records)}")
    if missing:
        print(f"WARNING|{len(missing)} skyboxes have one or more undecodable archive faces; continuing with complete skies and existing profile fallbacks")

if __name__ == "__main__":
    main()
