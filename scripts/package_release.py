"""Create a portable app/source ZIP without Finder or resource-fork metadata."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent.parent
destination = root / 'dist/QuickUnzip-2.3-macOS-arm64.zip'
app = root / 'dist/QuickUnzip.app'
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_file():
            archive.write(path, Path('QuickUnzip.app') / path.relative_to(app))
    for name in ['Package.swift', 'README.md', 'Sources', 'Tests', 'scripts', 'Vendor', 'Docs', 'Examples']:
        target = root / name
        for path in sorted(target.rglob('*')) if target.is_dir() else [target]:
            if path.is_file() and '__pycache__' not in path.parts:
                archive.write(path, Path('Source/QuickUnzip') / path.relative_to(root))
    archive.write(root / 'README.md', 'README.md')
print(destination)
