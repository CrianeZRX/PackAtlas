"""AES Crypt stream versions 0–3, authenticated before publication."""
import ctypes as C
import hashlib
import hmac
import os
from __main__ import BadPassword, Password, Unsupported, blocks, exact

cc=C.CDLL('/usr/lib/system/libcommonCrypto.dylib')
cc.CCCrypt.argtypes=[C.c_int,C.c_int,C.c_int,C.c_void_p,C.c_size_t,C.c_void_p,C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)]
cc.CCKeyDerivationPBKDF.argtypes=[C.c_int,C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.c_int,C.c_uint32,C.c_void_p,C.c_size_t]

def cbc(key,iv,data):
    buf=C.create_string_buffer(len(data)+16); n=C.c_size_t()
    if cc.CCCrypt(1,0,0,key,32,iv,data,len(data),buf,len(buf),C.byref(n)) or n.value!=len(data):
        raise ValueError("AES-CBC 块无效")
    return buf.raw[:n.value]

def decrypt(f,j):
    magic=exact(f,3)
    version,mod=exact(f,2)
    if magic!=b'AES' or version>3 or (version!=0 and mod): raise ValueError("AES Crypt 文件头无效")
    if version>=2:
        while n:=int.from_bytes(exact(f,2),'big'): exact(f,n)
    rounds=int.from_bytes(exact(f,4),'big') if version==3 else 8192
    iv=exact(f,16)
    if not 1<=rounds<=10_000_000: raise Unsupported("AES Crypt 密钥迭代次数超出支持范围")
    name=j.req['outputName']
    if not j.member(name,0): return
    password=j.req.get('password')
    if password is None: raise Password()
    if version==3:
        secret=password.encode('utf8')
        buf=C.create_string_buffer(32)
        if cc.CCKeyDerivationPBKDF(2,secret,len(secret),iv,16,5,rounds,buf,32): raise ValueError("密钥派生失败")
        key=buf.raw
    else:
        secret=password.encode('utf-16le')
        key=iv+bytes(16)
        for _ in range(8192): key=hashlib.sha256(key+secret).digest()
    if version:
        wrapped=exact(f,48); proof=exact(f,32)
        if not hmac.compare_digest(hmac.digest(key,wrapped+(b'\3' if version==3 else b''),'sha256'),proof): raise BadPassword()
        clear=cbc(key,iv,wrapped); iv,key=clear[:16],clear[16:]
    begin=f.tell(); trailer=33 if version in (1,2) else 32
    length=os.fstat(f.fileno()).st_size-begin-trailer
    if length<0 or length%16 or (version==3 and length==0): raise ValueError("AES Crypt 密文大小无效")
    f.seek(begin+length)
    if version in (1,2): mod=exact(f,1)[0]
    if mod>15 or (not length and mod): raise ValueError("AES Crypt 填充长度无效")
    expected=exact(f,32);f.seek(begin)
    mac=hmac.new(key,digestmod='sha256')
    with j.output(name) as out:
        left=length
        for data in blocks(f,length):
            mac.update(data);left-=len(data)
            plain=cbc(key,iv,data);iv=data[-16:]
            if not left:
                if not hmac.compare_digest(mac.digest(),expected):
                    if version==0: raise BadPassword()
                    raise ValueError("AES Crypt HMAC 校验失败")
                if version==3:
                    pad=plain[-1]
                    if pad<1 or pad>16 or plain[-pad:]!=bytes([pad])*pad: raise ValueError("AES Crypt 填充无效")
                    plain=plain[:-pad]
                elif mod: plain=plain[:-(16-mod)]
            j.put(out,plain)
        if not length and not hmac.compare_digest(mac.digest(),expected): raise ValueError("AES Crypt HMAC 校验失败")
