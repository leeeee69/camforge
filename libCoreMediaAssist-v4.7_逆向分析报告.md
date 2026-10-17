# libCoreMediaAssist-v4.7(1).dylib 逆向分析报告

> 分析方式说明：本机 REA MCP 本会话未连接，且 REA 原生引擎（Ghidra/Hopper/IDA）在 Windows 上均不可用
> （Windows Ghidra P0 只收 PE、不收 Mach-O；Hopper 仅 macOS；IDA 未配置）。
> 因此本报告为**本地静态结构解析**结果（lief 解析 Mach-O + 字符串/符号/选择器挖掘），
> **未做反编译**，没有伪代码和控制流证据。所有结论分「观察」和「推断」两栏标注。

---

## 一句话结论

文件名是伪装。它的真身是 **`yimi-v13.dylib`（bundle id: `com.VcamTang.yimi-v13`）**——
一个 iOS 越狱插件（Cydia Substrate），俗称 **VCam 虚拟摄像头**：hook 系统相机/音频链路，
把网络流（RTSP/HLS）、本地视频、相册、USB 推流伪造成"真实摄像头"，带**卡密授权、反调试、
反篡改、假服务器检测、隐形音频水印**全套商业级保护。字符串里明确出现抖音包名
`com.ss.iphone.ugc.Aweme`。

---

## 文件身份卡

| 项 | 值 | 来源 |
|---|---|---|
| 真名 | `/Library/MobileSubstrate/DynamicLibraries/yimi-v13.dylib` | LC_ID_DYLIB（观察） |
| Bundle ID | `com.VcamTang.yimi-v13` | __cstring（观察） |
| 格式 | Mach-O 64-bit，arm64，DYLIB，41 条 load command | 头部（观察） |
| 平台 | iOS，minos 16.0，SDK 16.4 | BUILD_VERSION（观察） |
| 大小 | 6,284,992 字节（~6.3MB） | 文件（观察） |
| 函数数 | 1,772（LC_FUNCTION_STARTS） | 观察 |
| 符号数 | 1,096（437 导出 / 658 导入 / 1 本地——本地符号已剥） | SYMTAB（观察） |
| SHA-256 | `b436268a4b5a7d91112823c82206ccc1cc4ef822131a04e627dfe65de76a055c` | 计算（观察） |
| 加密状态 | crypt_id=0，**未加密（已解密）** | ENCRYPTION_INFO_64（观察） |
| Substrate 依赖 | `/Library/Frameworks/CydiaSubstrate.framework` | LOAD_DYLIB（观察） |
| 线程/队列名 | com.yimi.* / com.yimilive.* 共 18 个 GCD 队列 | __cstring（观察） |

---

## 功能架构（按证据拼图）

### 1. 相机替换主链路（VCamHookManager）
- Hook 点选择器（观察，__objc_methname）：`installHooks` / `hookAVCaptureSession` /
  `hookPreviewLayer` / `hookSetSampleBufferDelegate` / `hookUIWindow` / `hookAudioDelegate:` /
  `swizzleDelegateClass:video:audio:` / `swizzleOutput:` / `reswizzleActiveSessions`
- 导入 `_MSHookFunction` + `_MSHookMessageEx`（Substrate 双 hook 手段，观察）
- 帧注入核心：`_deepCopyRealCamFrame:`、`_renderIntoCameraBufferImpl:mirror:token:`、
  `_copyNV12FromBuffer:toBuffer:`、`_readyNV12PixelBuffer` / `_readyBGRAPixelBuffer`
- **推断**：同时 hook 视频委托和音频委托，对目标 App 的 AVCaptureSession 输出做
  "偷梁换柱"——把假画面塞进真实 session 的 sample buffer 回调里。

### 2. 视频来源（五路）
| 来源 | 证据 | 状态 |
|---|---|---|
| 网络 URL（RTSP/HLS/RTMP/HTTP） | `_ffRTSPHost`、`_rtspTCPMode`、`_rtspLiveDropMode`、`_rtspTrimPendingToKeyframe`、`_networkURLField`、`_reportRTSPURL:` | 观察 |
| 本地文件 | `_readLoopAVFoundationImpl:`（AVFoundation 路）+ `VCamFFPlayer`（FFmpeg 路）双回路 | 观察 |
| 相册 | PHPickerViewController / PHAsset / PHImageManager 导入 | 观察 |
| 磁盘 | `_loadedVideoPath`、`_savedSourceType` | 观察 |
| USB（桌面伴侣 App 推流） | `VCamUSBPuller` 类 + `com.yimi.vcam.usb.io` 队列 | 观察 |
| 真实摄像头直通 | `VCamPassthroughView`/`VCamDirectPreviewView` 系列 | 观察 |

### 3. 解码管线
- 硬解：`VCamVTDecoder`（VideoToolbox，导入 CMVideoFormatDescription*/VT 系符号）
- 软解：内置**整套 FFmpeg**——导出符号 437 个里绝大多数是 `_ff_h264_*_neon` /
  `_ff_hevc_*_neon` / swscale NEON SIMD（H.264 qpel/idct/loop filter、HEVC idct/epel/qpel/sao）
- 抖动缓冲：`VCamFFJitterBuffer` / `VCamFFGOPPacket` / `VCamFFJitterPacket`，配
  `_monLeadFrames` / `_monLeadClampCount` / `_ffOpenDeadline` / `_ffHWProbationStart`
  （硬解可行性“缓刑期”探测——打不开就退软解，推断）
- 像素转换：`VCamPixelConvert` + CoreImage（CIContext）做 BGRA↔NV12 缩放，
  `_networkBGRAAttempts/Successes/Misses` 一堆统计字段说明转换失败重试逻辑很重

### 4. 音频链路
- `VCamAUInject` / `VCamTapInject*` / `VCamAudioCaptureProxy` / `VCamAudioRouter`——
  经 AVCaptureAudioDataOutput hook 注入替代音频（观察）
- `_speakerPumpQueue/_speakerPumpTimer/_startSpeakerPump`——扬声器回泵（内录+外放，推断）
- 中文串（观察，__ustring）：`内录`、`定时插话`、`动态音量微调`、`-60dB白噪声`
- `hissTraceBase64Tail` 选择器 + `-60dB白噪声`——**在音频里叠一层人耳不可闻的噪声尾迹，
  可事后提取追溯泄露源**（推断，防泄露水印）
- 讯飞语音克隆端点（观察，__cstring）：`wss://cn-huabei-1.xf-yun.com/v1/private/voice_clone`

### 5. 授权系统（VTLicense* + VTAuth*）
- `activateWithCardKey:completion:`、`_checkIntegrity:expireAt:serial:storedMAC:`、
  `saveCardKey:expireAt:deviceSerial:`、`requestAuthorizationShutdown`、`onAuthExpired`、
  `isLocallyActivated`、`restoreActivation`、`requireActivationForFeature:`（观察）
- 卡密状态机中文串（观察）：`卡密验证成功` / `卡密已过期` / `卡密已被服务端封禁` /
  `卡密绑定的设备数已达上限` / `卡密与当前设备不匹配` / `卡密不存在或已失效`
- 信任窗口 + 本地封禁标记 + 机器码拉黑（观察）：`信任窗口`、`到期时间`、
  `如果服务器侧也拉黑了该机器码`、`已清除本地封禁标记`

### 6. 反逆向/反篡改（VCamAntiDetect / VCamGuard）
| 手段 | 证据 |
|---|---|
| 反调试 | 导入 `_sysctl`/`_sysctlbyname`；字符串 `/tmp/debugserver.pid`、`/var/run/debugserver.pid`、`反调试定时器`、`反调试检测到可疑`、`com.vcam.antidebug.bg` 队列 |
| 反篡改 | `_NSFileModificationDate` 导入；`完整性校验失败`、`备份完整性校验失败`、`可能被篡改`、`二进制被` |
| 响应验签 | 导入 `_SecKeyVerifySignature` + ECDSA/RSA SHA256 算法常量；`响应无签名`、`响应签名无效`、`双签`、`客户端签名` |
| 假服务器检测 | `registerServerHashes:`、`setServerTemplates:`、`apiBase`、`serverURL`；`可能是假服务器`、`假服务器` |
| 自研 TLS | 直连 SecureTransport（`_SSLHandshake/_SSLRead/_SSLWrite/_SSLCopyPeerTrust...`）+ `credentialForTrust:`——证书锁定（推断） |
| 压缩载荷 | `_BZ2_bzDecompress*`（bzip2 解授权/配置数据，推断） |

### 7. 服务端与运营
- PHP 后端接口（观察）：`/api/recover-card.php`（卡密找回），`%@?version=%@`（版本参数模板）
- 服务器推送（观察）：`_loadBrandingAnnouncement`、`_fetchBrandingThenUpdateIcon:`、
  `announcementLabel`、`brandingPath/brandingFullURL`——公告+图标热更新
- 日志回传（观察）：`VCamLogger` / `VCamLogUploader` / `_logURL` / `反馈上传`
- 封禁 UI（观察）：`_showBanOverlay`、`_banRetryTapped:`、`_banOverlayLongPress:`
- 更新检查（观察）：`发现新版本`、`已是最新版本`

### 8. 目标 App（观察）
- `com.ss.iphone.ugc.Aweme`（抖音）——唯一出现的第三方 App 包名
- hook 面覆盖 `AVCaptureSession`/`AVCaptureVideoPreviewLayer`/sample buffer delegate/`UIWindow`，
  **推断**任何用系统相机的 App 都能被替换，抖音是显式适配对象
- `VCamAIBreakIn` + `com.yimi.aibreakin` 队列 + `aiBreakTapped`——菜单里有"AI Break"按钮，
  具体行为未逆到（未知）

---

## 证据分级

**观察（直接来自二进制）**：install name、bundle id、依赖库、导入符号（MSHook/SecKey/SSL/BZ2/sysctl）、
类名、选择器、队列名、中文字符串、RTSP 字段、讯飞端点、卡密文案、加密状态。

**推断（基于证据的合理推测）**：偷梁换柱式帧注入机制、SSL pinning、hiss 噪声=隐形泄露水印、
硬解缓刑探测、USB=桌面伴侣推流、抖音为显式适配目标、bzip2=授权数据压缩。

**未知（本次没搞出来的）**：
1. 无反编译——没有伪代码/控制流，方法级逻辑是黑盒（引擎不可用，见下）
2. 授权服务器域名未硬编码（运行时 `apiBase`/`serverTemplates` 配置，需动态抓包）
3. 卡密算法（VTLicenseCrypto 内部：签名方案、设备码生成）未逆
4. CFString 指针未解出（chained fixups 编码，脚本按裸指针解失败了）
5. 每类 App 的具体 hook 方法清单未到方法级
6. "AI Break" 功能实际行为未明

---

## 想要真反编译（伪代码级）的路

本机现状（`rea doctor` 实测）：
- REA CLI 6.5.0 在线，MCP 注册存在但**本会话没加载工具**——重启会话可拿 REA MCP 工具
- 但引擎全缺：Ghidra 未装且 Windows P0 版只收 PE 不收 Mach-O；Hopper 仅 macOS；IDA 未配

可选路径（按推荐排序）：
1. **装完整 Ghidra 12.1.x + Java 21**，设 `GHIDRA_INSTALL_DIR`，REA 即可在 Windows 上跑 Mach-O 反编译
2. 配 **IDA Pro + IDA MCP**（`REA_IDA_MCP_CONFIG`）
3. 拿一台 Mac 装 **Hopper**，本地直接逆
4. 不装引擎也行——我可以基于现有符号/字符串清单，先圈定**优先逆的函数名单**（如
   `_checkIntegrity:expireAt:serial:storedMAC:`、`activateWithCardKey:completion:`、
   `VCamAIBreakIn`、`_renderIntoCameraBufferImpl:mirror:token:`），用 Ghidra headless 脚本逐个 dump

---

## 风险提示（ blunt ）

这玩意是**付费黑产向工具**：设备码绑定 + 服务端拉黑 + 隐形水印 + 反调试，说明卖家本身就在防泄露。
用它做直播/视频伪摄像头，平台侧（尤其抖音）风控对上就是封号；卡密是和设备+服务器绑定的，
转卖、共享、扒码都会被服务端识破。你自己就是做电商带货的，账号资产比这点工具值钱，想清楚再用。

---

## 附件（工作区文件）
- `macho_structure.txt` — 完整结构解析（段/符号/依赖/函数表）
- `macho_strings.txt` — 类名/选择器/中英文串/导入符号全量
- `macho_cfstring_sig.txt` — CFString 尝试 + 代码签名 + 选择器主题扫描
- `analyze_macho.py` / `extract_strings.py` / `extract_cfstring.py` — 分析脚本（可复跑）
