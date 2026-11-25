"""Build non-JIT ZPAQ and PMarc helpers for the Apple Silicon release."""
from pathlib import Path
import subprocess, sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
zsrc = root / "Vendor/zpaq"
src = (zsrc / "zpaq.cpp").read_text()

# Extract only to numeric slots in an empty, private working directory.
# The Swift/Python frontend exclusively owns pathname validation and publishing.
def replace(old, new):
    global src
    if src.count(old) != 1:
        raise RuntimeError("ZPAQ source revision mismatch")
    src = src.replace(old, new)

replace("  int doCommand(int argc,", """  std::map<string,string> slots;
  void quickIndex() {
    if (!getenv("QZ_FLAT")) return;
    const char *manifest = getenv("QZ_INDEX");
    if (!manifest) error("missing manifest");
    FILE *f = fopen(manifest, "wb");
    if (!f) error("manifest open");
    unsigned next = 0;
    for (DTMap::iterator it=dt.begin(); it!=dt.end(); ++it) {
      if (!it->second.date || it->first.empty()) continue;
      if (++next > 200000 || it->first.size() > 8192) error("index limit");
      char slot[32];
      snprintf(slot,sizeof(slot),"member-%u",next);
      slots[it->first] = slot;
      fprintf(f,"%s\\t%lld\\t",slot,(long long)it->second.size);
      for (size_t j=0;j<it->first.size();++j) fprintf(f,"%02x",(unsigned char)it->first[j]);
      fputc('\\n',f);
      if (ftell(f) > 32*1024*1024 || ferror(f)) error("index too large");
    }
    if (fclose(f)) error("index write");
  }
  int doCommand(int argc,""")
replace("string Jidac::rename(string name) {", """string Jidac::rename(string name) {
  if (getenv("QZ_FLAT")) {
    std::map<string,string>::const_iterator slot=slots.find(name);
    if (slot==slots.end()) error("unknown member");
    return slot->second;
  }""")
replace('if (sz<1) error("archive not found");','if (sz<1) error("archive not found");\n  quickIndex();')
replace('if (archive!="") csize=read_archive(archive.c_str());','if (archive!="") csize=read_archive(archive.c_str());\n  if (getenv("QZ_FLAT")) { if (csize<1) error("empty input"); quickIndex(); return 0; }')
replace('else if (opt=="-key" && i<argc-1) {','''else if (opt=="-stdin-key") {
      libzpaq::SHA256 hash;
      int c;
      while ((c=getchar())!=EOF) hash.put(c);
      memcpy(password_string,hash.result(),32); password=password_string;
    }
    else if (opt=="-key" && i<argc-1) {''')
cache = root / ".build/rare"
cache.mkdir(parents=True,exist_ok=True)
source = cache / "zpaq.cpp"
source.write_text(src)
sdk = subprocess.check_output(["xcrun","--sdk","macosx","--show-sdk-path"],text=True).strip()
flags = ["-isysroot", sdk, "-O2","-arch","arm64","-mmacosx-version-min=13.0"]
subprocess.run(["xcrun", "clang++", *flags, "-std=c++11","-Dunix","-DNOJIT","-Wno-deprecated-declarations","-I",str(zsrc),str(source),str(zsrc/"libzpaq.cpp"),"-o",str(out/"zpaq")],check=True)
lib = root/"Vendor/lhasa/lib"
sources = [s for s in lib.glob("*.c") if s.name not in {"bit_stream_reader.c","lh_new_decoder.c","tree_decode.c","pma_common.c","lha_arch_win32.c"}]
subprocess.run(["xcrun","clang", *flags,"-dynamiclib","-install_name","@loader_path/pma.dylib","-lcompression","-I",str(lib),"-I",str(lib/"public"),"-DVERSION=\"0.0\"",
                str(root/"scripts/pma_bridge.c"),*map(str,sources),"-o",str(out/"pma.dylib")],check=True)

subprocess.run(["xcrun","clang++",*flags,"-std=c++17","-dynamiclib","-install_name","@loader_path/azo.dylib",str(root/"scripts/azo.cpp"),"-o",str(out/"azo.dylib")],check=True)
alz = root/"Vendor/alzbzip"
subprocess.run(["xcrun","clang",*flags,"-dynamiclib","-install_name","@loader_path/alzbzip.dylib",*map(str,sorted(alz.glob("*.c"))),*map(str,sorted((alz/"bzip2").glob("*.c"))),"-o",str(out/"alzbzip.dylib")],check=True)
