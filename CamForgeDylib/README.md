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
- 委托代理换帧（`CFCaptureProxy`），帧经 `CFPixelConverter`（BGRA→NV12）→ `CFJitterBuffer` 抖动缓冲 → `CMSampleBuffer` 回填
- 三种视频源：合成图案 / 本地视频（AVAssetReader）/ 网络流（同一入口，URL 传入即可）
- 440Hz 正弦标记音（`CFManager` 的 audio 分支），用于肉眼/仪器确认注入
- 悬浮面板 `CFMenu`：切换源 / 开关音频 / 诊断 / 隐藏 / 拖拽
- 诊断埋点 `CFLogger`：计数器 + 事件流水，实验判读全靠它

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

- workflow 在 `macos-14` runner 上跑：自动装 ldid → clone theos → 按 latest tag 下载 `iPhoneOS16.5.sdk` → `./build.sh`
- 换 SDK 版本：改 workflow 里 `iPhoneOS16.5.sdk.tar.xz` 的文件名
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

- 只注入抖音，其他进程即使扫到该目录也不会加载（filter plist + 构造器双兜底）。
- 卸载：删这两个文件 + 重启 SpringBoard。
- **sileo/依赖**：无需装任何依赖 deb，dylib 直接生效（这就是独立 dylib 相对 tweak deb 的优势）。

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
