import os
import struct
from zipfile import _ZipDecrypter

from __main__ import BadPassword, Password, Unsupported, decode, exact


def extract(source, job):
    end = os.fstat(source.fileno()).st_size
    while source.tell() < end:
        header = exact(source, 37)
        if header[:4] != b'BH\x05\x07':
            raise ValueError("BlakHole 文件头无效")
        flags, method = header[9:11]
        packed, raw_size, crc = struct.unpack_from('<III', header, 15)
        name_size, comment_size = struct.unpack_from('<HH', header, 33)
        name = exact(source, name_size).decode(job.req.get('encoding') or 'cp437')
        exact(source, comment_size)
        if source.tell() + packed > end:
            raise ValueError("BH 文件数据不完整")
        if not job.member(name, raw_size, bool(header[27] & 16)):
            source.seek(packed, 1)
            continue
        if method == 3:
            raise Unsupported("此条目使用 BlakHole Fuse（方法 3），轻解内置引擎尚不能解码：" + name)
        codec = {0: 'store', 8: 'deflate', 12: 'bzip2'}.get(method)
        if codec is None:
            raise Unsupported(f"未知 BH 压缩方法 {method}：{name}")
        transform = None
        if flags & 1:
            if packed < 12:
                raise ValueError("BH ZipCrypto 头不完整")
            password = job.req.get('password')
            if password is None:
                raise Password()
            transform = _ZipDecrypter(password.encode('utf8'))
            check = transform(exact(source, 12))[-1]
            if check != (header[12] if flags & 8 else crc >> 24):
                raise BadPassword()
            packed -= 12
        with job.output(name) as out:
            if transform is None:
                decode(source, packed, codec, raw_size, crc, job, out)
            else:
                decode(source, packed, codec, raw_size, crc, job, out, transform)
