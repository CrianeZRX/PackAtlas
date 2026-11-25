import ctypes as C
import hmac
from zipfile import _ZipDecrypter
from __main__ import Password,BadPassword,Unsupported

def decryptor(info,password):
    if password is None: raise Password()
    if not info: raise ValueError("EGG 加密头无效")
    method=info[0]; info=info[1:]; password=password.encode('utf8')
    if method==0:
        if len(info)!=16: raise ValueError("EGG ZipCrypto 头部异常")
        update=_ZipDecrypter(password)
        if update(info[:12])[-1]!=info[-1]: raise BadPassword()
        return update,lambda:None
    if method not in (1,2,5,6): raise Unsupported("此 EGG 加密算法尚不支持")
    from aes_stream import cc
    keysize=16 if method in (1,5) else 32
    saltlen=keysize//2
    if len(info)!=saltlen+12: raise ValueError("EGG AES 头部异常")
    derived=C.create_string_buffer(keysize*2+2)
    if cc.CCKeyDerivationPBKDF(2,password,len(password),info[:saltlen],saltlen,1,1000,derived,len(derived)): raise ValueError("密钥派生失败")
    keys=derived.raw
    if not hmac.compare_digest(keys[-2:],info[saltlen:saltlen+2]): raise BadPassword()
    mac=hmac.new(keys[keysize:-2],digestmod='sha1')
    lea=lea_encryptor(keys[:keysize]) if method in (5,6) else None
    count=0 if lea else 1; leftover=b''
    def update(data):
        nonlocal count,leftover
        mac.update(data)
        needed=(max(len(data)-len(leftover),0)+15)//16
        counters=b''.join(i.to_bytes(16,'big' if lea else 'little') for i in range(count,count+needed))
        count+=needed
        if counters and lea: leftover+=lea(counters)
        elif counters:
            buf=C.create_string_buffer(len(counters)+16); n=C.c_size_t()
            if cc.CCCrypt(0,0,2,keys[:keysize],keysize,None,counters,len(counters),buf,len(buf),C.byref(n)): raise ValueError("AES CTR 解码失败")
            leftover+=buf.raw[:n.value]
        result=bytes(a^b for a,b in zip(data,leftover))
        leftover=leftover[len(data):]
        return result
    def finish():
        if not hmac.compare_digest(mac.digest()[:10],info[-10:]): raise ValueError("EGG HMAC 校验失败")
    return update,finish

def lea_encryptor(key):
    import struct
    mask=0xffffffff
    def rol(x,n):
        n%=32;x&=mask
        return ((x<<n)|(x>>((32-n)%32)))&mask
    delta=(0xc3efe9db,0x44626b02,0x79e27c8a,0x78df30ec,0x715ea49e,0xc785da0a,0xe04ef22a,0xe5c40957)
    t=list(struct.unpack('<'+'I'*(len(key)//4),key));schedule=[]
    for i in range(24 if len(t)==4 else 32):
        d=delta[i%len(t)]
        if len(t)==4:
            for j,n in enumerate((1,3,6,11)): t[j]=rol(t[j]+rol(d,i+j),n)
            schedule.append((t[0],t[1],t[2],t[1],t[3],t[1]))
        else:
            idx=[(6*i+j)%8 for j in range(6)]
            for j,n in enumerate((1,3,6,11,13,17)): t[idx[j]]=rol(t[idx[j]]+rol(d,i+j),n)
            schedule.append(tuple(t[k] for k in idx))
    def encrypt(data):
        result=bytearray()
        for x in struct.iter_unpack('<4I',data):
            a,b,c,d=x
            for k in schedule:
                a,b,c,d=rol((a^k[0])+(b^k[1]),9),rol((b^k[2])+(c^k[3]),27),rol((c^k[4])+(d^k[5]),29),a
            result.extend(struct.pack('<4I',a,b,c,d))
        return result
    return encrypt
