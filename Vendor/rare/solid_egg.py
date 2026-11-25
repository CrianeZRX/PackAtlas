"""Decode blocks in archive order and distribute their verified output by file size."""
from bisect import bisect_right
from contextlib import ExitStack, nullcontext
import struct
import zlib

from __main__ import END, Unsupported, blocks, decode, exact, integer
from egg_crypto import decryptor

CODECS = {0: 'store', 1: 'deflate', 2: 'bzip2', 3: 'azo', 4: 'lzma'}


class MemberSink:
    def __init__(self, job, members, handles):
        self.job = job
        self.members = iter(members)
        self.handles = handles
        self.remaining = 0
        self.out = None

    def advance(self):
        self.handles.close()
        for name, size, self.active, _ in self.members:
            self.remaining = size
            self.out = self.handles.enter_context(self.job.output(name) if self.active else nullcontext())
            if size:
                return True
            self.handles.close()
        return False

    def put(self, _, data):
        start = 0
        while start < len(data):
            if not self.remaining and not self.advance():
                raise ValueError("EGG 固实块超出目录大小")
            count = min(self.remaining, len(data) - start)
            if self.active:
                self.job.put(self.out, data[start:start + count])
            self.remaining -= count
            start += count


def unpack(source, job, members, tag, fields):
    ends = []
    encrypted = []
    total = 0
    # Empty files have no share of the block stream.
    spans = [m for m in members if m[1]]
    for index, (_, size, _, enc) in enumerate(spans):
        total += size
        ends.append(total)
        if enc is not None:
            encrypted.append(index)

    current = transform = verify = None
    def cipher(index):
        nonlocal current, transform, verify
        if index != current:
            if verify is not None:
                verify()
            current = index
            info = spans[index][3]
            if info is None:
                transform, verify = (lambda data: data), None
            else:
                transform, verify = decryptor(info, job.req.get('password'))
        return transform

    pos = 0
    with ExitStack() as handles:
        sink = MemberSink(job, members, handles)
        if job.mode != 'list':
            for _, size, _, info in members:
                if size == 0 and info is not None:
                    _, finish = decryptor(info, job.req.get('password'))
                    finish()
        while tag == 0x02b50c13:
            method, _, raw, packed, crc = struct.unpack('<BBIII', exact(source, 14))
            for block_tag, _, _ in fields():
                if block_tag == 0x08d1470f:
                    raise Unsupported("未知的 EGG 固实块级加密布局")
            if pos + raw > total:
                raise ValueError("EGG 固实块超过条目总长度")
            if job.mode == 'list':
                source.seek(packed, 1)
            elif not raw:
                if encrypted:
                    raise Unsupported("含空块的加密固实 EGG 无法确定该块所属的条目")
                decode(source, packed, CODECS.get(method), 0, crc, sink, None)
            else:
                first = bisect_right(ends, pos)
                last = bisect_right(ends, pos + raw - 1)
                # Compressed bytes have no file boundary inside a shared block.
                # A stored block has a 1:1 mapping, including across cipher changes.
                if first != last and bisect_right(encrypted, last) > bisect_right(encrypted, first - 1):
                    if method != 0:
                        raise Unsupported("EGG 的同一压缩块跨越使用独立密码信息的文件，无法确定密文边界")
                    if packed != raw:
                        raise ValueError("EGG 固实存储块大小无效")
                    offset = pos
                    checksum = 0
                    for owner in range(first, last + 1):
                        count = min(ends[owner], pos + raw) - offset
                        update = cipher(owner)
                        for data in blocks(source, count):
                            clear = update(data)
                            checksum = zlib.crc32(clear, checksum)
                            sink.put(None, clear)
                        offset += count
                    if crc != checksum:
                        raise ValueError("EGG 固实块 CRC-32 校验失败")
                else:
                    codec = CODECS.get(method)
                    decode(source, packed, codec, raw, crc, sink, None, cipher(first))
            pos += raw
            tag = integer(source, 4)
        if tag != END or pos != total:
            raise ValueError("EGG 固实块不完整")
        if verify is not None:
            verify()
        if job.mode != 'list' and (sink.remaining or sink.advance()):
            raise ValueError("EGG 固实成员不完整")
