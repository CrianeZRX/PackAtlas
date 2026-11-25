"""Isolated worker for legacy formats. Only this module creates output names."""
import os
import sys
from pathlib import Path
BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE))
import binascii
import bz2
import ctypes as C
import hashlib
import hmac
import json
import lzma
import struct
import subprocess
import zlib
from contextlib import nullcontext

CHUNK = 256 * 1024
END = 0x08e28222
class Unsupported(ValueError): pass
class Password(ValueError): pass
class BadPassword(ValueError): pass

def exact(f, n):
    if not 0 <= n <= 32 * 1024 * 1024:
        raise ValueError("记录尺寸超出支持范围")
    data = f.read(n)
    if len(data) != n:
        raise ValueError("文件提前结束")
    return data

def integer(f,n):
    return int.from_bytes(exact(f,n),'little')

def blocks(f,n):
    while n:
        data=exact(f,min(n,CHUNK))
        n-=len(data)
        yield data

def safe(name):
    name=name.replace("\\","/").rstrip("/")
    parts=name.split("/")
    if not name or len(name)>8192 or any(p in ("",".","..") or ":" in p or any(ord(c)<32 for c in p) for p in parts):
        raise ValueError("不安全的成员路径")
    return name

class Job:
    def __init__(self, req):
        self.req=req
        self.items=[]
        self.files=self.size=self.count=0
        self.paths=set()
        self.selection=req.get("selected",[])
        self.mode=req["mode"]
        self.folder=Path(req["folder"]) if req.get("folder") else None
    def member(self,name,size,directory=False):
        name=safe(name)
        if name in self.paths or self.count>=200000:
            raise ValueError("条目重复或数量超出范围")
        self.paths.add(name)
        self.count+=1
        if len(self.items)<self.req.get("limit",10000):
            self.items.append(dict(path=name,size=max(size,0),directory=directory))
        if self.mode=="list": return False
        parts=name.split("/")
        if self.req.get("ignoreMac") and any(p=="__MACOSX" or p.startswith("._") or p==".DS_Store" for p in parts): return False
        if self.selection and not any(name==s or name.startswith(s+"/") for s in self.selection): return False
        if directory:
            if self.folder: (self.folder/name).mkdir(parents=True,exist_ok=True,mode=0o700)
            return False
        self.files+=1
        return True
    def output(self,name):
        if not self.folder: return nullcontext(None)
        target=self.folder/safe(name)
        target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        return target.open('xb')
    def put(self,out,data):
        if out: out.write(data)
        self.size+=len(data)

def decode(f,n,method,want,crc,job,out,transform=lambda d:d):
    if method=='lzma':
        props=transform(exact(f,9))[4:]
        n-=9
        prop=props[0]
        dictionary=int.from_bytes(props[1:],'little')
        if prop>=225 or dictionary>128*1024*1024: raise ValueError("LZMA 字典无效或过大")
        decoder=lzma.LZMADecompressor(format=lzma.FORMAT_RAW,filters=[dict(id=lzma.FILTER_LZMA1,lc=prop%9,lp=(prop//9)%5,pb=prop//45,dict_size=max(dictionary,4096))])
    elif method in ('deflate','zlib'): decoder=zlib.decompressobj(-15 if method=='deflate' else 15)
    elif method=='bzip2': decoder=bz2.BZ2Decompressor()
    elif method not in ('store','azo','alzbzip'): raise Unsupported("此分支的压缩方法尚不支持")
    size=checksum=0
    def consume(data):
        nonlocal size,checksum
        size+=len(data)
        if size>want: raise ValueError("解码数据超过声明大小")
        checksum=zlib.crc32(data,checksum)
        job.put(out,data)
    if method in ('azo','alzbzip'):
        from extra_codecs import azo,alz_bzip
        if method=='azo': azo(f,n,want,transform,consume)
        else: alz_bzip(f,n,transform,consume)
        if size!=want or checksum!=crc: raise ValueError("CRC-32 或大小不匹配")
        return
    for part in blocks(f,n):
        part=transform(part)
        if method=='store': consume(part)
        elif method in ('deflate','zlib'):
            while part:
                consume(decoder.decompress(part,CHUNK))
                part=decoder.unconsumed_tail
                if decoder.unused_data: raise ValueError("压缩流尾部异常")
        else:
            while True:
                consume(decoder.decompress(part,max_length=CHUNK))
                if decoder.eof or decoder.needs_input: break
                part=b''
            if decoder.unused_data: raise ValueError("压缩流尾部异常")
    if size!=want or (crc is not None and checksum!=crc): raise ValueError("数据长度或 CRC-32 校验失败")
    if method not in ('store','lzma') and not decoder.eof: raise ValueError("压缩流提前结束")

def egg(f,j):
    end=f.seek(0,2); f.seek(0)
    if exact(f,6)!=b'EGGA\0\1': raise Unsupported("不支持的 EGG 版本")
    exact(f,8)
    def extra(tag=None):
        flags=integer(f,1);n=integer(f,4 if flags&1 else 2)
        if tag==0x08d1470f and n>0:
            start=f.tell()
            method=integer(f,1)
            valid={0:[17],1:[21,11],2:[29,19],5:[21,11],6:[29,19]}.get(method,[])
            for candidate in ([n] if n in valid else [])+valid:
                f.seek(start+candidate)
                if f.read(4)==struct.pack('<I',END): n=candidate;break
            f.seek(start)
        return flags,exact(f,n)
    def fields():
        while True:
            tag=integer(f,4)
            if tag==END: return
            flags,data=extra(tag)
            yield tag,flags,data
    solid=False; members=[]
    for tag,_,_ in fields():
        if tag==0x24e5a060: solid=True
        if tag==0x08d144a8: raise Unsupported("此 EGG 使用加密目录")
    paths={}
    tag=integer(f,4)
    while tag!=END:
        if tag in (0x04c63672,0x07463307): extra(); tag=integer(f,4); continue
        if tag!=0x0a8590e3: raise ValueError("EGG 文件头无效")
        idx=integer(f,4); size=integer(f,8)
        name=None; directory=False; enc=None
        for t,flags,data in fields():
            if t==0x0a8591ac:
                if flags&4: raise Unsupported("EGG 文件名加密")
                codec='utf-8'
                if flags&8:
                    if len(data)<2: raise ValueError("EGG 文件名编码字段不完整")
                    code=int.from_bytes(data[:2],"little"); data=data[2:]
                    codec=j.req.get('encoding') or {0:'cp949',932:'cp932',936:'gbk',949:'cp949',950:'cp950',1252:'cp1252',54936:'gb18030',65001:'utf8'}.get(code)
                    if not codec: raise Unsupported("EGG 文件名代码页")
                parent=''
                if flags&16:
                    pid=int.from_bytes(data[:4],"little"); data=data[4:]; parent=paths[pid]+'/'
                name=safe(parent+data.decode(codec))
            elif t==0x08d1470f: enc=data
            elif t==0x2c86950b:
                if len(data)!=9 or data[8]&8: raise Unsupported("EGG 特殊条目")
                directory=bool(data[8]&128)
            elif t==0x1ee922e5:
                mode=int.from_bytes(data[:4],'little')&0o170000
                if mode not in (0,0o040000,0o100000): raise Unsupported("EGG 特殊条目")
                directory=mode==0o040000
        if name is None or idx in paths: raise ValueError("EGG 文件目录无效")
        paths[idx]=name
        active=j.member(name,size,directory)
        transform=lambda data:data
        verify=lambda:None
        if not solid and active and enc is not None:
            from egg_crypto import decryptor
            transform,verify=decryptor(enc,j.req.get("password"))
        if solid:
            if not directory: members.append((name,size,active,enc))
            tag=integer(f,4)
            if tag!=0x02b50c13: continue
            from solid_egg import unpack
            unpack(f,j,members,tag,fields)
            return
        total=0
        with j.output(name) if active else nullcontext(None) as out:
            tag=integer(f,4)
            while tag==0x02b50c13:
                method,hint,raw,packed,crc=struct.unpack('<BBIII',exact(f,14))
                for _ in fields(): pass
                total+=raw
                if total>size or f.tell()+packed>end: raise ValueError("EGG 块越界")
                if active: decode(f,packed,{0:'store',1:'deflate',2:'bzip2',3:'azo',4:'lzma'}.get(method),raw,crc,j,out,transform)
                else: f.seek(packed,1)
                tag=integer(f,4)
        verify()
        if total!=size: raise ValueError("EGG 条目不完整")

    if solid:
        from solid_egg import unpack
        unpack(f,j,members,tag,fields)

def alz(f,j):
    end=f.seek(0,2); f.seek(8)
    while True:
        tag=integer(f,4)
        if tag in (0x015a4c43,0x025a4c43,0x015a4c45):
            f.seek(-4,2)
            if exact(f,4)!=b'CLZ\x02': raise Unsupported("ALZ 分卷或不完整的末卷")
            return
        if tag!=0x015a4c42: raise ValueError("ALZ 条目无效")
        n,attr,stamp,flags,_=struct.unpack('<HBIBB',exact(f,9))
        width=flags>>4
        if width not in (0,1,2,4,8): raise ValueError("ALZ 尺寸字段无效")
        method=crc=packed=size=0
        if width:
            method,_,crc=struct.unpack('<BBI',exact(f,6))
            packed=integer(f,width);size=integer(f,width)
        raw=exact(f,n)
        try: name=raw.decode('utf8')
        except UnicodeError: name=raw.decode(j.req.get("encoding") or "cp949")
        active=j.member(name,size,bool(attr&16))
        transform=lambda data:data
        if flags&1:
            header=exact(f,12)
            if active:
                password=j.req.get("password")
                if password is None: raise Password()
                from zipfile import _ZipDecrypter
                transform=_ZipDecrypter(password.encode())
                if transform(header)[-1]!=((stamp>>8 if flags&8 else crc>>24)&255): raise BadPassword()
        if f.tell()+packed>end: raise ValueError("ALZ 文件提前结束")
        if active:
            with j.output(name) as out: decode(f,packed,{0:'store',1:'alzbzip',2:'deflate'}.get(method),size,crc,j,out,transform)
        else: f.seek(packed,1)

def ace(path,j):
    import acefile
    with acefile.open(str(path),encoding=j.req.get("encoding") or "cp437") as archive:
        for m in archive.getmembers():
            name=m.raw_filename.decode(j.req.get("encoding") or "cp437")
            if not j.member(name,m.size,m.is_dir()): continue
            pwd=j.req.get("password")
            if m.is_enc() and pwd is None: raise Password()
            with j.output(name) as out:
                try:
                    for data in archive.readblocks(m,pwd=pwd): j.put(out,data)
                except acefile.EncryptedArchiveError as e: raise BadPassword() from e

def native():
    return C.CDLL(str(BASE/'bin/pma.dylib'))

def pma(path,j):
    lib=native()
    lib.pm_open.argtypes=[C.c_char_p]; lib.pm_open.restype=C.c_void_p
    lib.pm_close.argtypes=[C.c_void_p]
    lib.pm_next.argtypes=[C.c_void_p,C.POINTER(C.c_char_p),C.POINTER(C.c_char_p),C.POINTER(C.c_uint64),C.POINTER(C.c_uint16)]
    lib.pm_read.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t];lib.pm_read.restype=C.c_size_t
    h=lib.pm_open(os.fsencode(path))
    if not h: raise ValueError("无法打开 PMarc")
    table=[]
    for i in range(256):
        c=i
        for _ in range(8): c=(c>>1)^(0xa001 if c&1 else 0)
        table.append(c)
    try:
        while True:
            fn=C.c_char_p();folder=C.c_char_p();size=C.c_uint64();crc=C.c_uint16()
            kind=lib.pm_next(h,C.byref(folder),C.byref(fn),C.byref(size),C.byref(crc))
            if kind==0: break
            if kind<0: raise Unsupported("PMarc 特殊条目")
            name=((folder.value or b'')+(fn.value or b'')).decode(j.req.get("encoding") or 'cp437')
            if not j.member(name,size.value,kind==2): continue
            buf=C.create_string_buffer(CHUNK)
            with j.output(name) as out:
                checksum=total=0
                while True:
                    n=lib.pm_read(h,buf,CHUNK)
                    if not n: break
                    data=buf.raw[:n];total+=n
                    if total>size.value: raise ValueError("PMarc 大小异常")
                    for b in data: checksum=(checksum>>8)^table[(checksum^b)&255]
                    j.put(out,data)
                if total!=size.value or checksum!=crc.value: raise ValueError("PMarc CRC-16 校验失败")
        if not j.count: raise ValueError("无法读取 PMarc 目录")
    finally: lib.pm_close(h)

def zpaq(path,j):
    work=Path(j.req["scratch"])
    manifest=work/'zpaq-index'
    dest=work/'zpaq-flat'
    dest.mkdir()
    env=dict(os.environ,QZ_FLAT='1',QZ_INDEX=str(manifest))
    password=j.req.get("password")
    def invoke(cmd):
        args=[str(BASE/'bin/zpaq'),cmd,str(path),'-threads','1','-noattributes']
        if cmd=='x' and j.mode=='test': args.append('-test')
        if password is not None: args.append('-stdin-key')
        with (work/'zpaq-errors').open('wb+') as err:
            result=subprocess.run(args,input=(password or '').encode(),env=env,cwd=dest,stdout=subprocess.DEVNULL,stderr=err)
            if result.returncode:
                err.seek(0);detail=err.read(4096)
                if b'password' in detail.lower():
                    if password is None: raise Password()
                    raise BadPassword()
                raise ValueError('ZPAQ 校验失败或块不完整')
    invoke('l' if j.mode=='list' else 'x')
    with manifest.open('rb') as idx:
        for line in idx:
            slot,length,name=line.rstrip(b'\n').split(b'\t')
            if not slot.startswith(b'member-') or not slot[7:].isdigit(): raise ValueError("ZPAQ 索引无效")
            name=bytes.fromhex(name.decode('ascii')).decode('utf8')
            size=int(length)
            if not j.member(name,size,name.endswith('/')): continue
            if j.mode=='test': j.size+=max(size,0);continue
            payload=dest/slot.decode('ascii')
            if not payload.is_file() or (size>=0 and payload.stat().st_size!=size): raise ValueError("ZPAQ 输出不完整")
            target=j.folder/safe(name)
            target.parent.mkdir(parents=True,exist_ok=True)
            os.link(payload,target)
            j.size+=target.stat().st_size

def apple_stream(path,j,fmt):
    name=j.req["outputName"]
    if not j.member(name,0): return
    lib=native()
    lib.apple_stream.argtypes=[C.c_char_p,C.c_int,C.c_int,C.POINTER(C.c_uint64)]
    total=C.c_uint64()
    with j.output(name) as out:
        if lib.apple_stream(os.fsencode(path),out.fileno() if out else -1,0xb02 if fmt=='Brotli' else 0x801,C.byref(total)): raise ValueError('压缩流数据不完整')
    j.size+=total.value

def armoring(f,j,fmt):
    header=f.readline(8192).rstrip(b'\r\n')
    prefix,mode,name=header.split(b' ',2)
    if prefix!=b'begin' or len(mode)!=3 or any(c not in b'01234567' for c in mode): raise ValueError("编码文件头无效")
    name=name.decode('utf8'); active=j.member(name,0)
    if not active: return
    alphabet=b'+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    with j.output(name) as out:
        while True:
            line=f.readline(1024)
            if not line: raise ValueError("缺少 end 标记")
            line=line.rstrip(b'\r\n')
            if line==b'end': return
            if not line: continue
            if fmt=='XXencode':
                try: line=bytes(32+alphabet.index(c) for c in line)
                except ValueError: raise ValueError("XXencode 字符无效")
            j.put(out,binascii.a2b_uu(line))

def isz(f,j):
    h=exact(f,48);size=h[4]
    if size not in (48,64) or h[5]!=1: raise Unsupported("不支持的 ISZ 头部版本")
    sector,sectors,enc,segment,num,block,width,vol,table,segs,offset=struct.unpack_from('<HIBQIIBBIII',h,10)
    extended=exact(f,size-48)
    total=sector*sectors
    if vol: raise ValueError("找不到匹配的 ISZ 首卷，请将同组分卷放在同一目录")
    if not block or block>32*1024*1024 or num!=(total+block-1)//block or num>2000000 or width not in (1,2,3,4): raise ValueError("ISZ 块目录无效")
    name=j.req['outputName']+'.iso'
    active=j.member(name,total)
    key=None
    if enc and active:
        if enc not in (2,3,4): raise Unsupported("此 ISZ 加密类型尚不支持")
        password=j.req.get("password")
        if password is None: raise Password()
        keysize={2:16,3:24,4:32}[enc]
        key=password.encode("utf8")[:keysize].ljust(keysize,b'\0')
    from isz_volumes import open_parts, unmask
    chunks=None
    if table:
        f.seek(table)
        chunks=unmask(exact(f,num*width))
    bits=width*8-2
    mask=(1<<bits)-1
    def chunk(index):
        if chunks is None: return 1,min(block,total-index*block)
        entry=int.from_bytes(chunks[index*width:(index+1)*width],'little')
        kind,length=entry>>bits,entry&mask
        if length>block: raise ValueError("ISZ 压缩块尺寸无效")
        return kind,0 if kind==0 else length
    if segment or segs:
        stream=open_parts(Path(j.req['source']),h,f,segs,segment,num,lambda i:chunk(i)[1])
    else:
        f.seek(offset)
        stream=nullcontext(f)
    crc=0
    with stream as payload:
        if not active: return
        with j.output(name) as out:
            for i in range(num):
                want=min(block,total-i*block)
                typ,n=chunk(i)
                if typ==0: data=bytes(want)
                else:
                    data=exact(payload,n)
                    if key:
                        from aes_stream import cc
                        length=len(data)//16*16
                        if length:
                            buf=C.create_string_buffer(length+16);used=C.c_size_t()
                            if cc.CCCrypt(1,0,2,key,len(key),None,data,length,buf,len(buf),C.byref(used)): raise ValueError("ISZ AES 解码失败")
                            data=buf.raw[:used.value]+data[length:]
                    if typ in (2,3):
                        codec=zlib.decompressobj() if typ==2 else bz2.BZ2Decompressor()
                        if typ==3: data=b'BZh'+data[3:]
                        data=codec.decompress(data,want+1)
                        if not codec.eof or codec.unused_data: raise ValueError("ISZ 压缩块异常")
                if len(data)!=want: raise ValueError("ISZ 块长度异常")
                crc=zlib.crc32(data,crc);j.put(out,data)
    if extended and crc!=(int.from_bytes(extended[:4],'little')^0xffffffff): raise ValueError("ISZ CRC-32 校验失败")

def main():
    if os.getpgrp()!=os.getpid(): os.setpgrp()
    req=json.load(sys.stdin)
    path=Path(req['source'])
    j=Job(req); fmt=req['format']
    if fmt=='ACE': ace(path,j)
    elif fmt=='PMarc': pma(path,j)
    elif fmt=='ZPAQ': zpaq(path,j)
    elif fmt in ('Brotli','LZFSE'): apple_stream(path,j,fmt)
    else:
        from volumes import archive_stream
        with archive_stream(path,fmt) if fmt in ('ALZ','EGG') else path.open('rb') as f:
            if fmt=='BlakHole':
                from blakhole import extract
                extract(f,j)
            elif fmt=='ALZ': alz(f,j)
            elif fmt=='EGG': egg(f,j)
            elif fmt=='ISZ': isz(f,j)
            elif fmt=='AES Crypt':
                from aes_stream import decrypt
                decrypt(f,j)
            elif fmt in ('XXencode','UUencode'): armoring(f,j,fmt)
            else: raise Unsupported('缺少可用的 '+fmt+' 解码器')
    if j.selection and not j.files and j.mode!='list' and not any(j.folder.iterdir() if j.folder else []): raise ValueError("所选条目不存在")
    print(json.dumps(dict(items=j.items if j.mode=='list' else [],files=j.files,size=j.size,truncated=j.count>len(j.items)),ensure_ascii=True))

if __name__=='__main__':
    try: main()
    except Password: sys.exit(41)
    except BadPassword: sys.exit(42)
    except Exception as exc:
        print(str(exc)[:400] or type(exc).__name__,file=sys.stderr)
        sys.exit(2)
