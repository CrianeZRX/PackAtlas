"""Check BH and solid EGG through the packaged CLI with independent crypto producers."""
import argparse
import bz2
import hashlib
import hmac
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile
import zlib

PASSWORD = 'sample-password'
END = bytes.fromhex('2282e208')
SOLID = bytes.fromhex('60a0e524000000')
HEADER = b'EGGA\0\1' + struct.pack('<II', 23, 0) + SOLID + END


def field(tag, data):
    return struct.pack('<IBH', tag, 0, len(data)) + data


def member(name, size, info, index):
    return (struct.pack('<IIQ', 0x0a8590e3, index, size) + field(0x0a8591ac, name.encode())
            + (field(0x08d1470f, info) if info else b'') + END)


def block(method, raw, data):
    return struct.pack('<IBBIII', 0x02b50c13, method, 0, len(raw), len(data), zlib.crc32(raw)) + END + data


def raw_deflate(data):
    z = zlib.compressobj(wbits=-15)
    return z.compress(data) + z.flush()


def aes_vector(cipher_input, salt):
    key = hashlib.pbkdf2_hmac('sha1', PASSWORD.encode(), salt, 1000, 34)
    counters = b''.join(i.to_bytes(16, 'little') for i in range(1, (len(cipher_input)+15)//16 + 1))
    stream = subprocess.run(['/usr/bin/openssl', 'enc', '-aes-128-ecb', '-nopad', '-nosalt', '-K', key[:16].hex()],
                            input=counters, capture_output=True, check=True).stdout
    cipher = bytes(x ^ y for x, y in zip(cipher_input, stream))
    mac = hmac.new(key[16:32], cipher, 'sha1').digest()[:10]
    return b'\x01' + salt + key[-2:] + mac, cipher


def call(cli, path, *options, password=None):
    flags = ['--password-stdin'] if password is not None else []
    return subprocess.run([cli, *flags, *options, path], input=((password or '')+'\n').encode(), capture_output=True)


def success(cli, archive, target, expected, password=PASSWORD, selection=None):
    result = call(cli, archive, '--list')
    assert result.returncode == 0, result.stderr
    paths = [x['path'] for x in json.loads(result.stdout)['items']]
    assert all(name in paths for name in expected)
    integrity = call(cli, archive, '--test', password=password)
    assert integrity.returncode == 0, integrity.stderr
    target.mkdir()
    selection = ['--select', selection] if selection else []
    result = call(cli, archive, '--here', '--out', target, *selection, password=password)
    assert result.returncode == 0, result.stderr
    actual = {str(p.relative_to(target)): p.read_bytes() for p in target.rglob('*') if p.is_file()}
    assert actual == expected, archive


def fails(cli, archive, target, password, reason):
    target.mkdir()
    result = call(cli, archive, '--here', '--out', target, password=password)
    assert result.returncode and reason in result.stderr.decode(), result.stderr
    assert list(target.iterdir()) == []


def bh(cli, tmp):
    # Keep the encrypted 12-byte header and payload from Info-ZIP, with a BH container header.
    raw = b'hello BH\n' * 400
    (tmp/'text').write_bytes(raw)
    subprocess.run(['/usr/bin/zip', '-q', '-P', PASSWORD, 'payload.zip', 'text'], cwd=tmp, check=True)
    with zipfile.ZipFile(tmp/'payload.zip') as zipf:
        entry = zipf.infolist()[0]
        assert zipf.read(entry, pwd=PASSWORD.encode()) == raw
    data = (tmp/'payload.zip').read_bytes()
    flags, method, timestamp = struct.unpack_from('<HHH', data, 6)
    name_size, extra = struct.unpack_from('<HH', data, 26)
    start = 30 + name_size + extra
    cipher = data[start:start + entry.compress_size]
    name = b'before.txt'
    header = struct.pack('<4sH5BHHIIIHIHH', b'BH\x05\x07', 37+len(name), 37, 218, 4,
                         flags & 255, method, timestamp, 0, len(cipher), len(raw), entry.CRC, 32, 0, len(name), 0)
    p = tmp/'cipher.bh'
    p.write_bytes(header + name + cipher)
    success(cli, p, tmp/'bh-ok', {name.decode():raw})
    fails(cli, p, tmp/'bh-no-pw', None, '需要密码')
    fails(cli, p, tmp/'bh-wrong-pw', 'wrong', '密码')
    # Alter the original-data checksum, retaining the password-check byte.
    bad = bytearray(p.read_bytes())
    bad[23] ^= 1
    p.write_bytes(bad)
    fails(cli, p, tmp/'bh-crc', PASSWORD, 'CRC')
    # Method 3 is listed separately and identified even in a mixed-method archive.
    bad = bytearray(header + name + cipher)
    bad[9], bad[10] = 0, 3
    p.write_bytes(bad)
    result = call(cli, p, '--list')
    assert result.returncode == 0
    fails(cli, p, tmp/'bh-method', None, 'Fuse')
    normal = b'untouched'
    regular_name = b'plain.txt'
    normal_header = struct.pack('<4sH5BHHIIIHIHH', b'BH\x05\x07', 37+len(regular_name), 37, 218, 4, 0, 0,
                                0, 0, len(normal), len(normal), zlib.crc32(normal), 32, 0, len(regular_name), 0)
    p.write_bytes(bad + normal_header + regular_name + normal)
    dest = tmp/'mixed-bh-selected'
    dest.mkdir()
    assert call(cli, p, '--select', 'plain.txt', '--here', '--out', dest).returncode == 0
    assert (dest/'plain.txt').read_bytes() == normal


def eggs(cli, tmp):
    raw_a = b'abcd' * 800
    raw_b = bytes(range(255))*15
    first, second = raw_deflate(raw_a[:1303]), raw_deflate(raw_a[1303:])
    a_info, a_enc = aes_vector(first + second, b'12345678')
    b_info, b_enc = aes_vector(bz2.compress(raw_b), b'87654321')
    entries = member('one', len(raw_a), a_info, 0) + member('two', len(raw_b), b_info, 1)
    packets = (block(1, raw_a[:1303], a_enc[:len(first)]) + block(1, raw_a[1303:], a_enc[len(first):])
               + block(2, raw_b, b_enc))
    path = tmp/'solid.egg'
    path.write_bytes(HEADER + entries + packets + END)
    success(cli, path, tmp/'egg-ok', {'one':raw_a,'two':raw_b})
    success(cli, path, tmp/'egg-select', {'two':raw_b}, selection='two')
    fails(cli, path, tmp/'egg-no-pw', None, '需要密码')
    fails(cli, path, tmp/'egg-wrong-pw', 'wrong', '密码')
    bad_info = b_info[:-1] + bytes([b_info[-1] ^ 1])
    path.write_bytes(HEADER + entries.replace(b_info, bad_info) + packets + END)
    fails(cli, path, tmp/'egg-auth', PASSWORD, 'HMAC')
    # One stored block crosses two independently authenticated members.
    a_info, a_enc = aes_vector(raw_a, b'abcdefgh')
    b_info, b_enc = aes_vector(raw_b, b'hgfedcba')
    entries = member('one', len(raw_a), a_info, 0) + member('two', len(raw_b), b_info, 1)
    path.write_bytes(HEADER + entries + block(0, raw_a + raw_b, a_enc + b_enc) + END)
    success(cli, path, tmp/'egg-stored', {'one':raw_a,'two':raw_b})
    path.write_bytes(HEADER + entries + block(1, raw_a + raw_b, raw_deflate(raw_a + raw_b)) + END)
    fails(cli, path, tmp/'egg-ambiguous', PASSWORD, '密文边界')


def converted(cli, tmp, samples):
    for fname, pw in [('aes256.egg','test1234'), ('protected.egg','1q2w3e4r!')]:
        orig = samples/fname
        ref = tmp/(fname+'-reference')
        ref.mkdir()
        result = call(cli, orig, '--here', '--out', ref, password=pw)
        assert result.returncode == 0, result.stderr
        expected = {str(p.relative_to(ref)):p.read_bytes() for p in ref.rglob('*') if p.is_file()}
        assert expected
        raw = orig.read_bytes()
        assert raw[14:18] == END
        out = tmp/('solid-'+fname)
        out.write_bytes(raw[:14] + SOLID + raw[14:])
        success(cli, out, tmp/(fname+'-output'), expected, password=pw)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('cli', type=Path)
    parser.add_argument('--public-samples', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        for test in (bh, eggs):
            test(args.cli.resolve(), Path(directory))
            print('PASS', test.__name__, flush=True)
        if args.public_samples:
            converted(args.cli.resolve(), Path(directory), args.public_samples.resolve())
            print('PASS public AES-256 and ZipCrypto ciphertext with a solid header', flush=True)
