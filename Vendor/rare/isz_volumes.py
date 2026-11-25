"""Map UltraISO segment descriptors and cross-volume chunk tails to disk extents."""
import os
import re
import struct

from volumes import VolumeReader, extent, open_volume

RECORD = struct.Struct('<QIIII')
MASK = bytes(c ^ 255 for c in b'IsZ!')


def unmask(raw):
    return bytes(value ^ MASK[index % 4] for index, value in enumerate(raw))


def filename(first, index):
    if index == 0:
        return first
    match = re.fullmatch(r'(.+\.part)(0*1)(\.isz)', first.name, re.I)
    if match:
        return first.with_name(match[1] + str(index + 1).zfill(len(match[2])) + match[3])
    return first.with_suffix(f'.i{index:02d}')


def open_parts(first, header, source, seg_table, segment_size, count, packed_size):
    rows = []
    if seg_table:
        source.seek(seg_table)
        for _ in range(100):
            record = source.read(RECORD.size)
            if len(record) != RECORD.size:
                raise ValueError("ISZ 分卷表不完整")
            row = RECORD.unpack(unmask(record))
            if not row[0]:
                break
            rows.append(row)
        else:
            raise ValueError("ISZ 分卷表缺少结束记录")
        if not rows:
            raise ValueError("ISZ 分卷表为空")

    remaining = sum(packed_size(i) for i in range(count))
    first_chunk = carry = 0
    pieces = []
    for index in range(99):
        path = filename(first, index)
        with open_volume(path) as f:
            size = os.fstat(f.fileno()).st_size
            physical = f.read(48)
            if len(physical) != 48 or physical[:4] != b'IsZ!' or physical[5:17] != header[5:17] or physical[34] != index:
                raise ValueError(f"ISZ 卷序号或镜像标识不匹配：{path.name}")
            header_size = physical[4]
            if header_size not in (48, 64):
                raise ValueError(f"ISZ 分卷头无效：{path.name}")
            if rows:
                declared, chunks, first_id, chunk_start, tail = rows[index]
                if size != declared or first_id != first_chunk or chunks > count - first_id:
                    raise ValueError(f"ISZ 分卷尺寸或块编号不匹配：{path.name}")
                bound = first_id + chunks
                if tail and (not chunks or tail > packed_size(bound - 1)):
                    raise ValueError("ISZ 跨卷块长度无效")
                start = chunk_start - carry
                length = carry + sum(packed_size(i) for i in range(first_id, bound)) - tail
                first_chunk, carry = bound, tail
                last = index + 1 == len(rows)
            else:
                start, = struct.unpack_from('<I', physical, 43)
                length = size - start
                last = length == remaining
                if length <= 0 and remaining or (not last and size != segment_size):
                    raise ValueError(f"ISZ 分卷尺寸不符：{path.name}")
            if start < header_size or not 0 <= length <= remaining:
                raise ValueError(f"ISZ 数据区越界：{path.name}")
            pieces.append(extent(path, f, start, length))
            remaining -= length
            if last:
                if remaining or (rows and (first_chunk != count or carry)):
                    raise ValueError("ISZ 分卷集不完整")
                return VolumeReader(pieces)
    raise ValueError("ISZ 分卷集超出格式范围")
