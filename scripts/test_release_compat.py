"""Exercise the installed CLI's multipart reads, listing and integrity fallbacks."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile
import zlib


def run(cli, *args):
    result = subprocess.run([cli, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise AssertionError(result.stderr.decode(errors='replace'))
    return json.loads(result.stdout)


def check_file(cli, target, member, data, folder):
    folder.mkdir()
    assert [item['path'] for item in run(cli, '--list', target)['items']] == [member]
    assert run(cli, '--test', target)['bytes'] == len(data)
    assert run(cli, '--here', '--out', folder, target)['ok']
    assert (folder / member).read_bytes() == data


def expect_failure(cli, path, folder, diagnostic):
    folder.mkdir()
    result = subprocess.run([cli, '--here', '--out', folder, path], capture_output=True)
    assert result.returncode and diagnostic in result.stderr.decode(), result.stderr
    assert list(folder.iterdir()) == []


def masked(raw):
    return bytes(b ^ b'IsZ!'[i % 4] ^ 255 for i, b in enumerate(raw))


def isz_header(number, segment_size, sectors, table, parts, start, data):
    h = struct.pack('<4sBBIHIBQIIBBIIIB', b'IsZ!', 64, 1, 0x20402, 512, sectors, 0,
                    segment_size, sectors, 512, 3, number, table, parts, start, 0)
    return h + struct.pack('<IIII', zlib.crc32(data) ^ 0xffffffff, 0, 0, 0)


def indexed_isz(first, second):
    raws = [bytes(512), b's' * 512, bytes(range(256)) * 2, b'u' * 512]
    packed = [b'', raws[1], zlib.compress(raws[2]), zlib.compress(raws[3])]
    data = b''.join(raws)
    table = masked(b''.join((kind << 22 | len(chunk)).to_bytes(3, 'little')
                            for kind, chunk in zip([0, 1, 2, 2], packed)))
    start = 64 + 3 * 24 + len(table)
    tail = 17
    left = packed[1] + packed[2][:-tail]
    right = packed[2][-tail:] + packed[3]
    lengths = [start + len(left), 64 + len(right)]
    descriptors = masked(struct.pack('<QIIII', lengths[0], 3, 0, start, tail)
                         + struct.pack('<QIIII', lengths[1], 1, 3, 64 + tail, 0) + bytes(24))
    first.write_bytes(isz_header(0, lengths[0], 4, 136, 64, start, data) + descriptors + table + left)
    second.write_bytes(isz_header(1, lengths[0], 4, 0, 0, 64, data) + right)
    return data


def check_isz(cli, tmp):
    first, second = tmp/'disk.isz', tmp/'disk.i01'
    data = indexed_isz(first, second)
    check_file(cli, second, 'disk.iso', data, tmp/'indexed-output')
    check_file(cli, first, 'disk.iso', data, tmp/'first-output')
    saved = second.read_bytes()
    second.unlink()
    expect_failure(cli, first, tmp/'missing', 'disk.i01')
    second.write_bytes(saved[:6] + b'xxxx' + saved[10:])
    expect_failure(cli, first, tmp/'mixed', '镜像标识')
    second.write_bytes(saved[:-1])
    expect_failure(cli, first, tmp/'short', '尺寸')
    second.write_bytes(saved[:-1] + bytes([saved[-1] ^ 1]))
    expect_failure(cli, first, tmp/'damaged', '解码失败')
    first, second = tmp/'parts.part001.isz', tmp/'parts.part002.isz'
    indexed_isz(first, second)
    check_file(cli, second, 'parts.iso', data, tmp/'numbered-output')
    # Tableless, raw sector data with a split inside one chunk.
    data = bytes(range(256)) * 512
    cut = 102400 - 64
    first, second = tmp/'plain.isz', tmp/'plain.i01'
    for i, path, part in [(0, first, data[:cut]), (1, second, data[cut:])]:
        path.write_bytes(isz_header(i, 102400, len(data)//512, 0, 0, 64, data) + part)
    check_file(cli, second, 'plain.iso', data, tmp/'plain-output')


def field(tag, data=b'', flags=0):
    return struct.pack('<IB', tag, flags) + len(data).to_bytes(4 if flags & 1 else 2, 'little') + data


def check_egg(cli, tmp):
    # Solid, split, Deflate and a non-UTF-8 name. Split inside compressed data.
    name = '报告.txt'
    data = bytes(range(256)) * 100
    comp = zlib.compressobj(wbits=-15)
    packed = comp.compress(data) + comp.flush()
    end = struct.pack('<I', 0x08e28222)
    headers = struct.pack('<IIQ', 0x0a8590e3, 0, len(data))
    headers += field(0x0a8591ac, struct.pack('<H', 936) + name.encode('gbk'), 8) + end
    headers += struct.pack('<IBBIII', 0x02b50c13, 1, 0, len(data), len(packed), zlib.crc32(data)) + end
    first, second = tmp/'books.vol1.egg', tmp/'books.vol2.egg'
    def volume(uid, prev, nxt):
        return (struct.pack('<4sHII', b'EGGA', 256, uid, 0) + field(0x24e5a060)
                + field(0x24f5a262, struct.pack('<II', prev, nxt), 1) + end)
    first.write_bytes(volume(12, 0, 13) + headers + packed[:100])
    second.write_bytes(volume(13, 12, 0) + packed[100:] + end)
    check_file(cli, second, name, data, tmp/'solid-split')
    second.write_bytes(volume(14, 12, 0) + packed[100:] + end)
    expect_failure(cli, first, tmp/'egg-wrong', '编号')


def check_directory(cli, tmp):
    path = tmp/'many.zip'
    with zipfile.ZipFile(path, 'w') as z:
        for index in range(10003):
            z.writestr(f'd/{index:05d}', b'')
    page = run(cli, '--list', path)
    assert page['truncated'] and len(page['items']) == 10000
    complete = run(cli, '--list', '--limit', '20000', path)
    assert not complete['truncated'] and complete['items'][-1]['path'] == 'd/10002'


def check_wim(cli, tmp):
    seven = cli.parent.parent/'Resources/Tools/7zz'
    (tmp/'hello.txt').write_bytes(b'Hello from WIM\n')
    subprocess.run([seven, 'a', '-twim', 'disk.wim', 'hello.txt'], cwd=tmp, check=True, stdout=subprocess.DEVNULL)
    result = run(cli, '--test', tmp/'disk.wim')
    assert result['ok'] and result['bytes'] == 15, result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('cli', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as name:
        for check in (check_isz, check_egg, check_directory, check_wim):
            check(args.cli.resolve(), Path(name))
            print('PASS', check.__name__, flush=True)
