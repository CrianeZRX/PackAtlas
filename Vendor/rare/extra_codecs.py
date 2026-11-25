import ctypes as C
import struct
import zlib
from __main__ import BASE,exact

def azo(f,packed,want,transform,emit):
    def take(n):
        nonlocal packed
        if n>packed: raise ValueError("AZO 块不完整")
        packed-=n
        return transform(exact(f,n))
    version,flags=take(2)
    if version!=0x31: raise ValueError("AZO 版本无效")
    lib=C.CDLL(str(BASE/'bin/azo.dylib'))
    lib.azo_block.argtypes=[C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t]
    total=0
    while True:
        raw,n,check=struct.unpack('>III',take(12))
        if not raw and not n:
            if packed or check or total!=want: raise ValueError("AZO 长度不匹配")
            return
        total+=raw
        if check!=(raw^n) or total>want or raw>32*1024*1024 or not raw or not n: raise ValueError("AZO 块越界")
        data=take(n)
        if n!=raw:
            out=C.create_string_buffer(raw)
            if lib.azo_block(data,n,out,raw): raise ValueError("AZO 压缩数据异常")
            data=out.raw
        if flags&1:
            data=bytearray(data)
            i=0
            while i+4<len(data):
                if data[i] in (232,233):
                    if data[i+4] in (0,255):
                        val=(int.from_bytes(data[i+1:i+5],'little')-i)&0xffffffff
                        val=(val&0xffffff)|(0xff000000 if val&(1<<24) else 0)
                        data[i+1:i+5]=val.to_bytes(4,'little')
                    i+=5
                else: i+=1
        emit(data)

class BZStream(C.Structure):
    _fields_=[('next_in',C.c_void_p),('avail_in',C.c_uint),('total_in_lo',C.c_uint),('total_in_hi',C.c_uint),
              ('next_out',C.c_void_p),('avail_out',C.c_uint),('total_out_lo',C.c_uint),('total_out_hi',C.c_uint),
              ('state',C.c_void_p),('alloc',C.c_void_p),('free',C.c_void_p),('opaque',C.c_void_p)]

def alz_bzip(f,packed,transform,emit):
    lib=C.CDLL(str(BASE/'bin/alzbzip.dylib')); s=BZStream()
    if lib.BZ2_bzDecompressInit(C.byref(s),0,0): raise ValueError("ALZ bzip2 初始化失败")
    out=C.create_string_buffer(262144)
    try:
        while True:
            if not s.avail_in and packed:
                n=min(packed,262144); packed-=n
                inp=C.create_string_buffer(transform(exact(f,n)));s.next_in=C.addressof(inp);s.avail_in=n
            before=s.avail_in;s.next_out=C.addressof(out);s.avail_out=len(out)
            result=lib.BZ2_bzDecompress(C.byref(s)); n=len(out)-s.avail_out
            if n: emit(out.raw[:n])
            if result==4:
                if packed or s.avail_in: raise ValueError("ALZ bzip2 尾部异常")
                return
            if result or (before==s.avail_in and not n): raise ValueError("ALZ bzip2 数据不完整")
    finally: lib.BZ2_bzDecompressEnd(C.byref(s))
