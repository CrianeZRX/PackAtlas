# 轻解 2.3 旧格式支持

| 格式 | 解码与验证范围 |
| --- | --- |
| EGG | Store、Deflate、BZip2、LZMA、AZO。密码走标准输入。已实测 ZipCrypto、AES-256、LEA 兼容加密档案、固实数据和三卷 Store 样本。固实 EGG 可解出单个加密成员、块边界与加密成员对齐的多文件，以及跨成员的 Store 块。密码状态贯穿该成员的多个块，输出核对块 CRC，AES/LEA 同时验证成员 HMAC。带有独立密钥信息的多个成员共用同一非 Store 压缩块时仍无法确定密文边界。加密目录或文件名仍有限制。分卷按卷头直接定位，并支持带扩展字段的固实分卷。保留同组卷名，并将所有卷放在同一目录。旧档案的文件名支持 CP936、CP950、GB18030 和 CP1252，且可在浏览器切换旧编码。 |
| ALZ | Store、Deflate、ALZ 修改版 BZip2（DLZ）、ZipCrypto。已测三卷 Store 和密码样本。 |
| ACE | acefile 读取 ACE 1.x、2.x。用公开的 CP437 文件名样本核对输出。 |
| PMA | Lhasa 解码 PMarc。PM2 实档验证 CRC-16 和 18,176 字节输出。 |
| ZPAQ | 原生 ARM64 解码，无 JIT，单线程。测试当前备份版本的文件、校验和与路径映射。选择性提取仍会先还原固实块，临时空间使用随档案变化。 |
| BH | Store、Deflate、BZip2；已用真实 BlakHole Deflate 样本验证。新增兼容传统 ZipCrypto 流的加密条目（加密标志位、12 字节密码校验头和成员 CRC）。以外部 Info-ZIP 密文和 BH 测试封装验证 Deflate 路径，尚缺 ZipTV 原版写出的加密样本。方法 3（Fuse）可列目录和跳过未选条目，内置引擎尚未解码。 |
| AES Crypt | 流格式 0–3。官方 v3 样本解出原文并验证 HMAC；v1/v2 密钥派生与 v3 不同。 |
| ISZ | 单卷与同目录分卷均可恢复为 ISO。分卷支持 SDT 索引及无分卷表布局、跨卷块、.isz/.i01 和 .part01.isz 命名。新分卷路径用按规格构造的原样块与 zlib 样本逐字节核对过。旧式密码标记 1 未接入。 |
| Brotli / LZFSE / LZ4 / Lzip | Brotli 和 LZFSE 走系统 Compression；标准 LZ4 帧、Lzip 走归档库或 7-Zip。Brotli 无固定魔数，使用 .br 后缀。 |
| UUencode / XXencode | 还原带 begin/end 和文件名的文本编码。XXencode 使用 .xxe 后缀协助区分。 |

兼容性按照真实格式、压缩方法和变体分别判断。EGG、ALZ 和 ISZ 在源分卷之间切换，浏览及解码均无需先在临时目录拼接整个归档。尚未逐一验证所有加密、分卷和损坏组合。系统运行负载随文件内容、存储介质及后台任务变化。

## 参考实现与样本

- [acefile](https://github.com/droe/acefile) 与 [ACE 样本](https://github.com/droe/acefile-testdata)
- [PMarc/Lhasa](https://github.com/fragglet/lhasa) 与 [ZPAQ](https://github.com/zpaq/zpaq)
- [EGG/ALZ 格式说明](https://github.com/alkegi/docs)、[AZO 解码](https://github.com/alkegi/libazo)、[ALZ BZip2 变体](https://github.com/kippler/unalz)
- [EGG 样本](https://github.com/alkegi/unegg)、[ALZ 样本](https://github.com/alkegi/unalz) 与 [早期压缩、加密样本](https://github.com/blurfx/unegg)
- [ISZ 发布方分卷规格](https://www.ezbsystems.com/isz/iszspec.txt)、[ISZ 参考读者](https://github.com/cdemu/cdemu/tree/master/libmirage/filters/filter-isz)、[BlakHole 参考与样本](https://github.com/PascalVault/Lazarus_Unpacker)
- [AES Crypt 流格式与测试向量](https://www.aescrypt.com/aes_stream_format.html)

## 2.3 验证与资料

EGG 固实部分使用独立 OpenSSL 密文构造多成员与多块样本，并把公开的普通 EGG 密文记录置于单成员固实布局中交叉核对。该组合测试与原版 ALZip 生成的加密固实归档有区别。ESTsoft 原始规范第 10 页给出成员加密头，第 16–17 页给出跨文件固实块布局。公开的 unEGG 分支在普通成员路径执行解密，其固实路径没有对应的密码调用。

- [ESTsoft 规范与 unEGG 参考实现](https://github.com/dterracino/UnEgg)
- [Bandisoft Ark 的 BH 编解码范围](https://kr.bandisoft.com/ark/) 与 [SDK 使用条款](https://kr.bandisoft.com/ark/download/)
- [PascalVault 的 BH 头结构](https://github.com/PascalVault/Lazarus_Packer/blob/main/PV_BH.pas) 和 [UniversalEditor 的方法 3 分支](https://github.com/alcexhim/UniversalEditor/blob/master/Plugins/UniversalEditor.Plugins.FileSystem/DataFormats/FileSystem/ZipTV/BlakHole/BHDataFormat.cs)
