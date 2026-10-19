# CamForgeDylib — 独立 .dylib 版虚拟相机注入插件（clean-room 自研）

> 参考 `libCoreMediaAssist-v4.7`（真身 `yimi-v13`）的**注入方式逻辑**设计，
> 不继承其任何授权 / 反调试 / 水印 / 假服务器代码或数据。
> 目标进程默认抖音（`com.ss.iphone.ugc.Aweme`），改 `CFHooks.m` 里 `kTargetBundleID` 即可换目标。

---

## 1. 这个工程是什么

一个标准的 MobileSubstrate/Cydia 独立 dylib：`libCamForge.dylib` + 同名 filter plist，
产物后缀与原版一致（`.dylib`），放进 `/Library/MobileSubstrate/DynamicLibraries/` 即被注入目标进程。

核心能力：

- Hook `AVCaptureVideoDataOutput/AVCaptureAudioDataOutput` 的 `setSampleBufferDelegate:queue:`
- Hook `AVCaptureSession startRunning` 做补扫
- 委托代理换帧（`CFCaptureProxy`），帧经 `CFPixelConverter`（BGRA→目标格式）→ `CFJitterBuffer` 抖动缓冲 → `CMSampleBuffer` 回填
- 帧源三种 + 直连对照：合成图案 / 本地视频（AVAssetReader）/ 网络流（HLS·mp4）/ 直连透传
- 画面变换：旋转（0/90/180/270）、水平镜像、填充/适应
- 440Hz 正弦标记音（`CFManager` 的 audio 分支），用于肉眼/仪器确认注入
- 悬浮面板 `CFMenu`：直播模式分段 / 拉流地址 / 粘贴-加载-停止 / 8 格功能矩阵 / 离线话术 / 诊断
- 诊断埋点 `CFLogger`：计数器 + 事件流水，实验判读全靠它

## 1.1 面板功能对照（v0.3.0）

面板层级对齐参考实现的 UI：标题栏 → 提示 → 直播模式 → 拉流地址 → 操作行 → 功能矩阵 → 底部两项。

| 控件 | 实际行为（都是本地实现，零联网） |
|---|---|
| 视频 / 网络 / 直连 | 本地视频文件 / http(s)·HLS·mp4 / 相机原样透传（A/B 对照） |
| 📋 粘贴 | 读系统剪贴板填进地址栏 |
| ⬇ 加载 | 校验地址 → 切源 → 开始注入 |
| ⏹ 停止 | 停注入，恢复真实相机 |
| 应用替屏 | 等价「加载 + 开始」，注入中则变成停止 |
| 网络模式「⬇ 预览」 | 先弹预览窗解码看画面（10fps），确认后点「替换相机」才注入 |
| 旋转 | 0°→90°→180°→270° 顺时针，走 CIImage 变换 |
| 画面镜像 | 水平翻转 |
| 内容 | 填充（裁切铺满）/ 适应（留黑边） |
| 透明 | 面板自身透明度 100/80/60/40% |
| 画面去重 | 逐帧内容摘要（FNV 抽样），相同则不重复注入 |
| 音频去重 | 原音频为静音段时不注入，避免标记音连成嗡声 |
| 音频注入 | 440Hz 标记音开关（默认关） |
| AI 话术 | 内置 8 条离线话术轮播，**不联网、不调模型** |
| 更新&反馈 | 版本/架构/宿主信息，纯本地弹层 |
| ⓘ / 状态行 | 诊断信息（计数 + 最近 12 条事件） |
| ✕ | 收起成右下角「CF」小气泡，点气泡再展开；标题栏可拖拽 |

> 说明：参考实现里的「AI 话术」是真接了模型/接口的；本工程刻意不联网，所以这里是**离线内置话术轮播**，功能形态一致但不含任何网络调用。

## 1.2 体积构成（v0.4 内置 FFmpeg 后）

| 版本 | dylib | 说明 |
|---|---|---|
| v0.3（无 FFmpeg） | 567 KB | 只支持 AVFoundation 能解的 http(s)/HLS/mp4 |
| **v0.4（含 FFmpeg）** | **9.78 MB** | 双架构各 ~4.9 MB，多了 RTSP/RTMP/HTTP-FLV 软解 |

FFmpeg 是 CI 里交叉编译的**静态库**（arm64 + arm64e 各编一遍再 lipo 合成 fat），只开了必要组件：
rtsp/rtmp/http/hls 协议 + flv/mpegts/mp4 解封装 + h264/hevc/aac 解码 + swscale。
没开 GPL 组件（不含 x264/x265），许可证是 LGPL-2.1+。

原版 6.3 MB 是**单架构**；我们是双架构 fat，所以更大。要缩体积可以：
- 只留 arm64（改 Makefile 的 `ARCHS`）→ 约 5 MB
- 再砍 hevc/mp3 解码 → 约 4 MB

## 1.3 五路视频源

| 源 | 实现 | 依赖 |
|---|---|---|
| 合成图案 | CoreGraphics 逐帧绘制（帧号烧录） | 无 |
| 本地视频 | AVAssetReader 循环播放 | 系统 |
| 相册最新 | PHAsset → AVAsset → AVAssetReader | 相册权限（用宿主 App 的） |
| 网络流 · RTSP/RTMP/HTTP-FLV | **FFmpeg** 软解 → BGRA | 内置 FFmpeg |
| 网络流 · http(s)/HLS/mp4 | AVFoundation | 系统 |
| **直连（USB 数据线）** | 手机监听 TCP，PC 经 **usbmuxd** 推 JPEG 帧 | PC 端 `iproxy` + `tools/cf-push.py` |
| 相机透传 | 不注入，原样交给 App（A/B 对照） | 无 |

> ⚠️ 关于「USB 直连」的真相：原版**不是**越狱层 USB 协议栈。它的字符串写着
> `direct-connect: listening on port %u (pc pushes via usbmuxd)`——就是手机侧开个 TCP
> 端口、PC 通过 usbmuxd（iTunes 那套端口转发）推流。我们复刻的就是这条通道，
> 只是帧协议自己定（JPEG 逐帧，避开 H.264 参数集对齐的坑）。

### 直连怎么用

```bash
# 1) 电脑上装 libimobiledevice（macOS: brew install libimobiledevice）
# 2) 转发端口（保持运行）
iproxy 9527 9527

# 3) 推视频文件（二选一）
python tools/cf-push.py /path/to/video.mp4
# 推电脑的 USB 摄像头
python tools/cf-push.py --camera 0

# 带宽紧张时降规格
python tools/cf-push.py video.mp4 --fps 15 --width 960 --height 540 --quality 60
```

手机上：面板切到「直连」→「加载」，状态行显示「已监听 9527」，PC 连上后变「已出帧」。

**音频**：脚本会把输入文件的音轨转成 s16le / 44.1k / 2ch 一起推（20ms 一包）。
手机侧用 libswresample 重采样到目标 App 实际要的采样率/声道数再喂进去；推流音频没到时
自动回落到 440Hz 标记音。诊断面板里 `directAudio(推流音频帧)` 就是走推流音频的次数。
不想推音频加 `--no-audio`（省带宽）。

PC 端依赖：优先 OpenCV（`pip install opencv-python`），没有就自动退回调用 `ffmpeg` CLI；
音频必须有 `ffmpeg`（OpenCV 不处理音轨）。

### 帧协议（自己写发送端时看这里）

```
header 12B: magic "CFRM"(LE u32 0x4D524643) | version 0x01 | type | resv 2B | length u32 LE
type 0x01 = JPEG 视频整帧
type 0x02 = PCM 音频（s16le 交错，44100Hz / 2ch / 每包 20ms = 1764B）
```

> 这是**我们自己的**帧格式，不与原版 PC 端工具线格式兼容——原版 magic/type 值没公开，
> 我们没有去逆向它的私有协议。用 `tools/cf-push.py` 或按上表自己写发送端都行。

## 2. 与 tweak 版（CamForge/）的差异

| | tweak 版（CamForge） | **本工程（CamForgeDylib）** |
|---|---|---|
| 入口 | `Tweak.xm`，Logos `%hook` | `CFHooks.m`，显式 `MSHookMessageEx` |
| 构建产物 | `.deb`（Substrate 依赖由包管理器解析） | `.dylib`（后缀与原版一致） |
| Makefile | `tweak.mk` | `library.mk` |
| 加载器耦合 | 只适配 Substrate | 任意加载器（Substrate / insert_dylib / DYLD） |
| 进程 guard | 靠 Substrate filter | filter plist **+ 构造器 bundleID 检查双兜底**（`CFHooks.m` `cf_load`） |

源码除入口外完全共用（CFManager / CFCaptureProxy / CFSyntheticSource / CFAssetSource /
CFPixelConverter / CFJitterBuffer / CFLogger / CFMenu）。

## 3. 文件清单

```
CamForgeDylib/
├── CFHooks.m              # ★ dylib 入口：进程 guard + 3 处 MSHookMessageEx
├── Makefile               # library.mk，ARCHS=arm64 arm64e，TARGET iOS 15.0+
├── build.sh               # make → 拷出 libCamForge.dylib → ldid/codesign 签名
├── libCamForge.plist      # Substrate filter（Bundles: 抖音包名）
├── CFManager.h/.m         # 中枢：30fps 渲染定时器、换帧、源切换、rescan
├── CFCaptureProxy.h/.m    # 委托代理（幂等包装，didOutputSampleBuffer 换帧）
├── CFSyntheticSource.h/.m # 合成图案源（渐变+移动色块+帧号烧录）
├── CFAssetSource.h/.m     # AVAssetReader 本地/网络视频源（EOF 循环）
├── CFAlbumSource.h/.m     # 相册最新视频（PHAsset → AVAsset）
├── CFMovieSource.h/.m     # FFmpeg 拉流：RTSP/RTMP/HTTP-FLV（软解 → BGRA）
├── CFDirectSource.h/.m    # 直连：监听 TCP，收 PC 经 usbmuxd 推来的 JPEG 帧
├── CFExternalSource.h/.m  # 备用：iOS 17+ 外部摄像头（AVCaptureDeviceTypeExternal）
├── tools/cf-push.py       # PC 端推送脚本（视频文件 / USB 摄像头）
├── vendor/build-ffmpeg.sh # CI 里交叉编译 FFmpeg 静态库
├── CFPixelConverter.h/.m  # CIContext render → NV12 CVPixelBufferPool
├── CFJitterBuffer.h/.m    # 4 槽环形抖动缓冲（os_unfair_lock）
├── CFLogger.h/.m          # 诊断埋点：6 计数器 + 50 条事件流水
├── CFMenu.h/.m            # 悬浮面板 UIWindow
└── README.md
```

## 4. 构建

> ⚠️ **Windows 原生编不了 iOS arm64。** 下面四条编译路径按你的环境选，产物都是同一个 `libCamForge.dylib`。

### A. 越狱设备本地编译（最推荐，10 分钟）

```sh
# 设备上（加 theos 源，一次性的）：
echo 'deb https://apt.theos.dev/ ./' > /etc/apt/sources.list.d/theos.list
apt update && apt install theos ldid

# 每次编译：
cd CamForgeDylib
chmod +x build.sh
./build.sh
# 产物：./libCamForge.dylib（已用 ldid 签名）
```

坑：装完 theos 重开终端再 make（`$THEOS` 要新 shell 生效）；报 `common.mk not found` 就 `dpkg -L theos | grep common.mk` 反推路径后 `export THEOS=<路径>`。

### B. macOS / Linux 原生编译

`$THEOS` 指向 theos 安装目录 + `$THEOS/sdks` 里有 iOS SDK，然后同样 `./build.sh`。

### C. Windows + WSL2 本地编译

```powershell
# 管理员 PowerShell：
wsl --install -d Ubuntu
```

```sh
# WSL Ubuntu 里：
sudo apt update
sudo apt install -y build-essential clang perl xz-utils curl git fakeroot
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS   # 直连不通就换 gh-proxy.com 镜像
# 从 github.com/theos/sdks/releases 下 iPhoneOS16.x sdk 解压到 $THEOS/sdks
# ldid：从 ProcursusTeam/ldid releases 下 linux 二进制装到 /usr/local/bin

# 工程在 E 盘，WSL 里直接 /mnt/e/... 访问，无需拷贝：
cd /mnt/e/WorkBuddy/2026-10-17-16-34-44/CamForgeDylib
./build.sh
```

### D. GitHub Actions 远程编译（PC 用户零搭建，推荐）

工程自带 `.github/workflows/build.yml`（位于仓库根，不在本目录内）：

```powershell
# 一次性准备（仓库根执行）：
git init
git add .
git commit -m "CamForgeDylib initial"

# 在 GitHub 建好空仓库后：
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git branch -M main
git push -u origin main
```

push 后自动触发编译；也可以进仓库 **Actions → Build libCamForge.dylib → Run workflow** 手动触发。
编完在 run 页面底部 **Artifacts** 下载 `libCamForge.zip`，里面就是 `libCamForge.dylib` + `libCamForge.plist`，拷到设备 `/Library/MobileSubstrate/DynamicLibraries/` 即用。

- workflow 在 `macos-14` runner 上跑：自动装 ldid → clone theos → **固定 tag `master-146e41f`** 下载 `iPhoneOS16.5.sdk` → `./build.sh`
- SDK tag 故意固定不死抓 latest：runner 共享 IP，未认证 GitHub API 有 60 次/时限流，动态解析会拿到 `null` tag 下载到 404 页面（2026-10-17 实测）；theos/sdks 的 release 资产永久保留，固定 tag 不会失效
- 换 SDK 版本：改 workflow 里 `iPhoneOS16.5.sdk.tar.xz` 的文件名和对应 tag
- workflow 带 **FFmpeg 静态库缓存**（`actions/cache`，key 含 `build-ffmpeg.sh` 哈希）：首次冷构建约 3 分钟，命中缓存约 1 分钟
- `build.sh` 的产物挑选按 Mach-O 头筛选（fat 合并产物优先，排除 dSYM 里的 DWARF 文件——dsymutil 会把调试信息也命名成 `CamForge.dylib`，`find | head -1` 随机抓中过，交付物直接废掉）
- ⚠️ `.gitignore` 已排除原版二进制（`target.dylib`）和逆向证据（`macho_*.txt`）——**这些绝不能进公开仓库**
- 公开仓库 = 代码公开，介意者用私有仓库（Actions 对私有仓库同样免费）

## 5. 部署（三选一）

### A. Substrate 目录部署（主推，与原版同机制）

```sh
# 设备上：
mkdir -p /Library/MobileSubstrate/DynamicLibraries
cp libCamForge.dylib /Library/MobileSubstrate/DynamicLibraries/
cp libCamForge.plist /Library/MobileSubstrate/DynamicLibraries/   # 文件名必须与 dylib 主名一致
killall -9 SpringBoard      # 或 killall -9 Aweme 让抖音重启后加载
```

- 默认注入 **抖音 + 微信** 两个宿主；其他进程即使扫到该目录也不会加载（filter plist + 构造器双兜底）。
- **加宿主要改两处**：`libCamForge.plist` 的 `Filter/Bundles` 和 `CFHooks.m` 的 `cf_targetBundleIDs()`。只改 plist 会出现「dylib 加载了但没面板」——因为构造器 guard 先 return 了。
- 卸载：删这两个文件 + 重启 SpringBoard。
- **sileo/依赖**：无需装任何依赖 deb，dylib 直接生效（这就是独立 dylib 相对 tweak deb 的优势）。

### A2. 微信里没有面板？（v0.3.0 已修）

旧版 plist 只写了 `com.ss.iphone.ugc.Aweme`，所以微信进程根本不会加载 dylib。现在两个都列上了，重启微信即可看到面板。

边界提醒：微信里这个面板只用于**预览对照**，不要用在视频通话/直播/外发场景（见第 7 节）。

### B. insert_dylib 注入（非越狱/自签 IPA 路线）

```sh
# Mac 上：
insert_dylib --all-yes libCamForge.dylib Aweme.app/Aweme -o Aweme_patched
# 然后需要开发者证书重签整个 IPA/App 才能装回设备
```

- 此路线 plist 不参与，进程 guard 在 `CFHooks.m` 兜底（非抖音进程直接 inert）。
- 重签 + 安装流程较长，且自签 App 在 iOS 上可能触发 AMFI 限制；适合没有越狱但想验证注入机制的场景。

### C. DYLD_INSERT_LIBRARIES（仅调试）

```sh
# 越狱设备 + debugserver/LLDB 启动抖音时：
DYLD_INSERT_LIBRARIES=/path/libCamForge.dylib /var/containers/Bundle/Application/*/Aweme.app/Aweme
```

- 非越狱设备基本被 AMFI 拦截；越狱设备上也只建议临时调试用，面板和日志配合 `idevicesyslog | grep CF` 看。

## 6. 抖音实验判读表

打开抖音 → 拍摄页，看 CFLogger 诊断（面板「诊断」页 / syslog `grep CF`）：

| 现象 | 判读 |
|---|---|
| `videoHookHits` 持续增长 | hook 命中，抖音拍摄走 AVCaptureVideoDataOutput，注入生效 |
| `injectedFrames` 与 `videoHookHits` 同步涨 | 帧替换在跑，画面应看到合成图案/你的源 |
| `videoHookHits` 恒 0 | 抖音新版可能换管线（如 Metal/ImageBuffer 直排），属**预期未知**，见下 |
| `sessionsSeen` 有值但 hooks 未装 | 启动时序问题，重启抖音复测 |
| 合成画面出现且帧号在跳 | 端到端确认成功；切「源」可换本地视频 |

抖音版本迭代快，拍摄管线可能变更。若恒 0，先用 `videoHookHits` 数据 + `strings`/classdump 对比新版
`Aweme` 的相机调用面，再决定 hook 点是否要跟着调——这是自研版最大的好处：一切可见、可改。

## 6.1 已知崩溃点与修复（v0.3.0）

上一版「一点开始替换就崩」是三处问题叠加，都已修：

| # | 崩溃点 | 原因 | 修法 |
|---|---|---|---|
| 1 | 合成源画帧时崩 | `CFSyntheticSource` 在后台渲染队列调用 `-[NSString drawAtPoint:withAttributes:]`。这套 UIKit 文字绘制依赖线程局部的 UIGraphics 上下文，后台队列上没有 → 抛异常 | 改 **CoreText**（`CTLineDraw`）直接画进 CGContext，任意线程安全 |
| 2 | 替换几帧后崩 | `CFPixelConverter` 的 format description 只在首次转换时创建，之后换分辨率/换格式都不重建；描述与 buffer 不匹配 | 按 `(尺寸, 像素格式)` 重建并判空；`formatDescription` 为 NULL 时不再调用 `CMSampleBufferCreateReadyWithImageBuffer` |
| 3 | 退出相机/切前后台时崩 | App 用 `setSampleBufferDelegate:nil queue:nil` 清输出，hook 仍把代理塞回去（queue=nil）→ AVFoundation 抛 `NSInvalidArgumentException` | delegate 或 queue 为 nil 时一律跳过包装；代理对原 delegate 改 **strong** 持有 |
| 4 | 下游解析崩 | 我们固定吐 NV12，而抖音/微信可能配的是 BGRA；App 按平面取 `GetBaseAddressOfPlane` 拿到 NULL | 读 `output.videoSettings` 跟随目标像素格式出帧（BGRA / 420v / 420f） |

另外加了两层兜底：注入帧被下游拒时回退真帧再喂一次；`CFAssetSource` 不再 `CVPixelBufferRetain(NULL)`，并对连续读取失败次数设上限（避免 30fps 疯狂重建 reader）。

排查手段：`idevicesyslog | grep CamForge`，面板 ⓘ 或点状态行也能看计数与最近事件。

## 7. 实验边界（再次明确）

- 仅**自己的设备 + 自己的账号**，只看拍摄预览与本地录制效果。
- **不开播、不视频通话、不连麦、不外发**含注入画面的内容。
- 合成源/本地视频/网络流都只是喂给自己的预览管线，不触碰任何第三方。
- 本工程不含任何授权绕过、反调试对抗、平台风控对抗代码，也不应被用于此类目的。

## 8. 原版防护层的取舍（问答）

原版 `yimi-v13` 的“伪装层”共 6 层：命名伪装 / 加载定向 / 反调试 / 反篡改双签 /
假服务器检测 / 隐形水印。本工程**只保留加载定向**（filter plist + 进程 guard，注入机制必需），
其余 5 层全部刻意不 port——它们服务的是卖家的商业保护而非注入功能本身，
且会显著增加实验版的崩溃面与维护面。详见工作区《逆向分析报告》第 5 节。

## 9. 服务端设施的取舍（问答）

原版配套的整套服务端设施同样**一概不 port**：

| 原版设施 | 用途 | 自研版 |
|---|---|---|
| PHP `/api/recover-card.php` | 卡密找回（授权体系一环） | ❌ 无授权体系，无需找回 |
| `%@?version=%@` 版本检查 + 公告/图标热更（`announcementLabel`/`brandingPath`） | 卖家版本控制与运营投放 | ❌ 不热更，改代码重新 `./build.sh` |
| `VCamLogger`/`VCamLogUploader`/`_logURL` 日志回传 | 卖家遥测 | ❌ 零遥测，CFLogger 只落本地 |
| 讯飞语音克隆 `wss://cn-huabei-1.xf-yun.com/v1/private/voice_clone` | 付费增值功能（需第三方 API 鉴权+计费） | ❌ 无语音克隆，不调第三方 API |

**本工程联网面为 0**：没有任何 `NSURLSession`/`WebSocket`/`wss` 调用，不连任何服务端。
唯一接触网络的路径是 `CFAssetSource` 播放**用户主动在网络流输入框里填的 URL**
（AVAssetReader 当视频源）——那是“输入源”不是“回连服务端”，不填就完全不触网。
换目标、换功能都改源码本地编译，不经任何热更通道——这正是“插件本身不需要联网”的设计。
