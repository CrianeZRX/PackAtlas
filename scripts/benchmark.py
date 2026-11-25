"""Small reproducible warm-cache benchmark; never use private user archives."""
from pathlib import Path
import hashlib
import json
import random
import shutil
import statistics
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
work = root / '.build/benchmark-v2'
work.mkdir(parents=True, exist_ok=True)
out = work / 'out'
out.mkdir(exist_ok=True)
archive = work / 'sample.zip'
rng = random.Random(20261124)
expected = {}
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for i in range(4):
        block = rng.randbytes(256*1024) + b'point cloud research data\n'*10000
        data = (block*34)[:16*1024*1024]
        name = f'file-{i}.bin'
        z.writestr(name, data)
        expected[name] = hashlib.sha256(data).hexdigest()
results = {'input_bytes': 64*1024*1024, 'archive_bytes': archive.stat().st_size, 'scenario': 'warm-cache synthetic ZIP32 Deflate, 4 x 16 MiB, Utility QoS, writes not fsync', 'runs': []}
for mode in ['serial', 'balanced', 'balanced', 'serial', 'serial', 'balanced']:
    args = [str(root/'.build/release/qunzip'), '--out', str(out)]
    if mode == 'serial': args.append('--serial')
    run = json.loads(subprocess.check_output(args+[str(archive)], text=True))
    dest = Path(run['outputs'][0])
    assert all(hashlib.sha256((dest/name).read_bytes()).hexdigest() == digest for name, digest in expected.items())
    run['mode'] = mode
    run['sha256_match'] = True
    run.pop('outputs', None)
    results['runs'].append(run)
    shutil.rmtree(dest)
results['median_seconds'] = {mode: statistics.median(r['seconds'] for r in results['runs'] if r['mode']==mode) for mode in ['serial','balanced']}
results['speedup_for_this_sample'] = results['median_seconds']['serial']/results['median_seconds']['balanced']
(root/'Docs').mkdir(exist_ok=True)
(root/'Docs/benchmark-v2.json').write_text(json.dumps(results, indent=2, ensure_ascii=False)+'\n')
print(json.dumps({'median_seconds': results['median_seconds'], 'ratio': results['speedup_for_this_sample'], 'sha256_match': True}, ensure_ascii=False))
archive.unlink()
