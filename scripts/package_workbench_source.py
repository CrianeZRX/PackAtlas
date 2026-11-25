"""Pack the public source tree without local runtimes, outputs or credentials."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

root = Path(__file__).resolve().parents[1]
output = root / "dist/Workbench/PackAtlas-3.0.0-preview.1-source.zip"

roots = (
    ".github", ".gitignore", "LICENSE", "README.md", "THIRD_PARTY.md", "Package.swift",
    "Sources", "Tests", "Workbench", "Vendor", "Docs", "Examples", "scripts",
)
local = (
    "Workbench/node_modules", "Workbench/dist", "Workbench/engine",
    "Vendor/rare/bin", "Vendor/rare/runtime", "Vendor/7zip/7zz",
    "Vendor/7zip/7z", "Vendor/7zip/7z.so",
)
output.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(output, "w", ZIP_DEFLATED, compresslevel=6) as archive:
    for name in roots:
        item = root / name
        for file in [item] if item.is_file() else sorted(item.rglob("*")):
            if not file.is_file() or file.is_symlink():
                continue
            relative = file.relative_to(root)
            posix = relative.as_posix()
            if any(posix == prefix or posix.startswith(prefix + "/") for prefix in local):
                continue
            if file.suffix in {".pyc", ".pkg", ".dylib", ".exe", ".dll"}:
                continue
            if any(part.startswith(".") and part not in {".github", ".gitignore"} for part in relative.parts):
                continue
            archive.write(file, Path("PackAtlas") / relative)
print(output)
