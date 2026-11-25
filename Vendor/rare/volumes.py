"""Seek across validated file extents, keeping at most one payload file open."""
from bisect import bisect_right
from contextlib import contextmanager
from dataclasses import dataclass
import os
import re
import stat
import struct

EGG_END = 0x08e28222
EGG_SPLIT = 0x24f5a262


@contextmanager
def open_volume(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise ValueError(f"缺少分卷 {path.name}") from None
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError(f"无效的分卷 {path.name}")
        yield source


@dataclass(frozen=True)
class Extent:
    path: object
    start: int
    length: int
    identity: tuple


def extent(path, source, start, length):
    info = os.fstat(source.fileno())
    if start < 0 or length < 0 or start + length > info.st_size:
        raise ValueError(f"分卷不完整：{path.name}")
    return Extent(path, start, length, (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns))


class VolumeReader:
    def __init__(self, extents):
        self.extents = [part for part in extents if part.length]
        self.ends = []
        self.size = self.position = 0
        for part in self.extents:
            self.size += part.length
            self.ends.append(self.size)
        self.index = self.handle = None

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        position = (0, self.position, self.size)[whence] + offset
        if position < 0:
            raise ValueError("分卷定位越界")
        self.position = position
        return position

    def read(self, n):
        remaining = min(n, self.size - self.position)
        pieces = []
        while remaining > 0:
            index = bisect_right(self.ends, self.position)
            part = self.extents[index]
            if index != self.index:
                self.close()
                self.handle = open_volume(part.path)
                self.source = self.handle.__enter__()
                self.index = index
                info = os.fstat(self.source.fileno())
                if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != part.identity:
                    raise ValueError(f"读取期间分卷已变更：{part.path.name}")
            available = self.ends[index] - self.position
            count = min(remaining, available)
            self.source.seek(part.start + part.length - available)
            data = self.source.read(count)
            if len(data) != count:
                raise ValueError(f"分卷提前结束：{part.path.name}")
            pieces.append(data)
            remaining -= count
            self.position += count
        return b''.join(pieces)

    def close(self):
        if self.index is not None:
            self.handle.__exit__(None, None, None)
            self.index = self.handle = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def egg_header(source, size):
    head = source.read(14)
    if len(head) != 14 or head[:6] != b'EGGA\0\1':
        raise ValueError("EGG 分卷头无效")
    uid, = struct.unpack_from('<I', head, 6)
    chain = None
    while source.tell() + 4 <= size:
        tag, = struct.unpack('<I', source.read(4))
        if tag == EGG_END:
            return uid, chain
        flags = source.read(1)
        if not flags:
            break
        width = 4 if flags[0] & 1 else 2
        field = source.read(width)
        if len(field) != width:
            break
        length = int.from_bytes(field, 'little')
        if length > size - source.tell():
            break
        if tag == EGG_SPLIT:
            if chain is not None or length != 8:
                raise ValueError("EGG 分卷字段无效")
            chain = struct.unpack('<II', source.read(8))
        else:
            source.seek(length, 1)
    raise ValueError("EGG 分卷头不完整")


def archive_stream(path, fmt):
    with path.open('rb') as first:
        size = os.fstat(first.fileno()).st_size
        if fmt == 'EGG':
            _, chain = egg_header(first, size)
            if chain is None:
                return path.open('rb')
            match = re.fullmatch(r'(.+\.vol)([0-9]+)(\.egg)', path.name, re.I)
            if not match or int(match[2]) != 1:
                raise ValueError("请将 .vol1.egg 首卷和后续卷放在同一目录")
        else:
            if size < 8:
                raise ValueError("ALZ 文件头不完整")
            first.seek(-4, 2)
            if first.read(4) != b'CLZ\x03':
                return path.open('rb')
    parts = []
    previous = expected = 0
    index = 0
    while True:
        if fmt == 'EGG':
            volume = path.with_name(match[1] + str(index + 1).zfill(len(match[2])) + match[3])
        else:
            if index > 2600:
                raise ValueError("ALZ 分卷编号超出命名范围")
            volume = path if not index else path.with_suffix('.' + chr(97 + (index-1)//100) + f'{(index-1)%100:02d}')
        with open_volume(volume) as source:
            size = os.fstat(source.fileno()).st_size
            if fmt == 'EGG':
                uid, chain = egg_header(source, size)
                if chain is None or chain[0] != previous or (index and uid != expected):
                    raise ValueError(f"EGG 分卷编号不匹配：{volume.name}")
                previous, expected = uid, chain[1]
                start = source.tell() if index else 0
                end = size
                done = expected == 0
            else:
                head = source.read(8)
                if len(head) != 8 or head[:4] != b'ALZ\x01' or int.from_bytes(head[6:], 'little') != index:
                    raise ValueError(f"ALZ 分卷编号不匹配：{volume.name}")
                source.seek(-4, 2)
                tail = source.read(4)
                if tail not in (b'CLZ\x03', b'CLZ\x02'):
                    raise ValueError(f"ALZ 分卷尾部无效：{volume.name}")
                done = tail == b'CLZ\x02'
                start = 8 if index else 0
                end = size if done else size - 16
            parts.append(extent(volume, source, start, end - start))
        if done:
            return VolumeReader(parts)
        index += 1
