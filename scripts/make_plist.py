import plistlib
import sys

formats = {
    'zip': ('public.zip-archive', ['zip', 'zipx', 'xpi', 'jar']),
    '7z': ('org.7-zip.7-zip-archive', ['7z']),
    'rar': ('com.rarlab.rar-archive', ['rar']),
    'tar': ('public.tar-archive', ['tar']),
    'gzip': ('org.gnu.gnu-zip-archive', ['gz', 'tgz']),
    'bzip2': ('public.bzip2-archive', ['bz2', 'tbz', 'tbz2']),
    'xz': ('org.tukaani.xz-archive', ['xz', 'txz']),
    'zstd': ('org.zstandard.zstd', ['zst', 'tzst']),
    'other': ('app.quickunzip.archive', ['cab', 'cpio', 'xar', 'ar', 'lzma', 'arj', 'lzh', 'lha', 'chm', 'wim', 'swm', 'vhd', 'vhdx', 'udf', 'deb', 'rpm', '001', 'egg', 'alz', 'ace', 'pma', 'zpaq', 'isz', 'bh', 'aes', 'uu', 'uue', 'xxe', 'br', 'lzfse', 'lz4', 'lz'] + [f'i{n:02d}' for n in range(1, 99)]),
}
info = {
    'CFBundleExecutable': 'QuickUnzip',
    'CFBundleIdentifier': 'app.quickunzip.mac',
    'CFBundleName': 'QuickUnzip',
    'CFBundleDisplayName': '轻解 QuickUnzip',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '2.3.0',
    'CFBundleVersion': '6',
    'CFBundleIconFile': 'AppIcon',
    'LSMinimumSystemVersion': '13.0',
    'LSApplicationCategoryType': 'public.app-category.utilities',
    'NSHighResolutionCapable': True,
    'NSSupportsAutomaticTermination': False,
    'NSHumanReadableCopyright': 'QuickUnzip · 2026',
    'NSServices': [
        {'NSMenuItem': {'default': '轻解 / 智能解压'}, 'NSMessage': 'extractSmart',
         'NSPortName': 'QuickUnzip', 'NSSendTypes': ['public.file-url'],
         'NSRequiredContext': {'NSServiceCategory': 'public.item'}},
        {'NSMenuItem': {'default': '轻解 / 解压到独立文件夹'}, 'NSMessage': 'extractFolder',
         'NSPortName': 'QuickUnzip', 'NSSendTypes': ['public.file-url'],
         'NSRequiredContext': {'NSServiceCategory': 'public.item'}},
    ],
    'CFBundleDocumentTypes': [
        {'CFBundleTypeName': name.upper() + ' Archive',
         'CFBundleTypeRole': 'Viewer', 'LSHandlerRank': 'Alternate',
         'LSItemContentTypes': [uti], 'CFBundleTypeExtensions': extensions}
        for name, (uti, extensions) in formats.items()
    ],
    'UTImportedTypeDeclarations': [
        {'UTTypeIdentifier': uti, 'UTTypeConformsTo': ['public.archive'],
         'UTTypeDescription': name.upper() + ' Archive',
         'UTTypeTagSpecification': {'public.filename-extension': extensions}}
        for name, (uti, extensions) in formats.items()
    ],
}
if "--workbench" in sys.argv:
    info["CFBundleIdentifier"] = "app.packatlas.desktop"
    info["CFBundleName"] = "PackAtlas"
    info["CFBundleExecutable"] = "PackAtlas"
    info["NSHumanReadableCopyright"] = "PackAtlas · 2026"
    info["CFBundleShortVersionString"] = "3.0.0"
    info["CFBundleVersion"] = "7"
    info["CFBundleDisplayName"] = "PackAtlas"
    info.pop("NSServices")
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(info, f, sort_keys=False)
