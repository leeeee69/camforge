# CamForge — 自研虚拟相机研究插件

Clean-room 复刻的 iOS 越狱虚拟相机（virtual camera）**研究**实现：hook `AVCaptureSession`
输出链路，把自建视频源的帧注入到 App 的相机回调里。代码全部自研，不含任何第三方二进制；
**无卡密/授权模块**（自研工具不需要），**刻意不含**反调试、反篡改、隐形水印等反规避设计。

> ⚠️ 用途限定：逆向工程学习、自有设备上的安全研究。请勿用于突破第三方平台风控、
> 直播/视频通话造假等场景——那不只是道德问题，是平台违规和民事风险。

---

## 1. 架构

```
App 相机链路                     CamForge 注入点
─────────────                   ─────────────────
AVCaptureSession
   └─ AVCaptureVideoDataOutput
   │     └─ setSampleBufferDelegate: ──hook──▶ CFCaptureProxy(记住真 delegate)
   │                                            │
   │   真回调 didOutputSampleBuffer: ◀──────────┘ 换成我们的帧
   │
   └─ AVCaptureAudioDataOutput
         └─ setSampleBufferDelegate: ──hook──▶ CFCaptureProxy(音频同理)

渲染线程(30fps timer)              CFManager 管线
────────────────────              ──────────────────────────────
id<CFFrameSource> nextPixelBuffer  ──▶ CFPixelConverter(BGRA→NV12)
  · CFSyntheticSource 合成图案           │
  · CFAssetSource 文件/网络(循环播放)    ▼
                                    CFJitterBuffer(4帧环形)
                                            │
                            相机回调线程 popRetained ──▶ 交给 App 真 delegate

UI：CFMenu 悬浮窗（UIWindow，可拖拽）——开始/停止、切源、音频注入开关
```

## 2. 与原版工具（yimi-v13.dylib）的设计对照

分析原版后做的工程取舍——哪些抄思路、哪些刻意不抄：

| 原版观察（静态分析结论） | CamForge 实现 | 取舍理由 |
|---|---|---|
| hook `setSampleBufferDelegate:queue:` + `startRunning` 补扫 | 同策略（Tweak.xm） | 标准技术族，公开知识 |
| BGRA↔NV12 转换 + CoreImage | 同（CIContext render 到 NV12 pool） | 省去手写色彩矩阵的坑 |
| 双解码：VideoToolbox 硬解 + FFmpeg 软解 + 硬解"缓刑"探测 | AVAssetReader（内部自动选硬/软解） | 免 FFmpeg 依赖，构建从 6MB 降到 ~200KB；RTSP 留扩展点 |
| 抖动缓冲：jitter buffer + lead frames + 统计字段 | 4 帧环形缓冲 + 满则丢旧 | 等价解决速率失配，60 行搞定 |
| 音频注入：AUInject / TapInject / speaker pump | 输出侧替换：440Hz 正弦标记音 | 研究验证足够；AU 级注入是扩展点 |
| 悬浮菜单：迷你图标 + 公告 + 品牌图标热更 | 4 按钮 + 状态行，无网络依赖 | 研究工具不做运营功能 |
| 卡密授权 / 设备绑定 / 信任窗口 | **无** | 自研无授权，这是与"破解"的本质区别 |
| 反调试 / 反篡核 / 双签 / 假服务器检测 / -60dB 水印 | **无（刻意）** | 反规避技术不对外提供；自研工具也不怕泄露 |

## 3. 目录

```
CamForge/
├── control                 # deb 包元数据
├── Makefile                # theos 构建（arm64 / arm64e）
├── camforge.plist          # 注入过滤器（目标 App bundle id）
├── Tweak.xm                # 入口 + AVCapture hook
├── CFManager.h/.m          # 中枢：渲染定时器、源切换、取样、补挂 hook
├── CFCaptureProxy.h/.m     # 委托代理：换帧 + 转发真 delegate
├── CFFrameSource 协议        # (CFManager.h 内) 帧源统一 BGRA 输出契约
├── CFSyntheticSource.h/.m  # 合成测试图案源（默认，帧号烧录）
├── CFAssetSource.h/.m      # AVAssetReader 源（本地文件 / HTTP-HLS，循环播放）
├── CFPixelConverter.h/.m   # BGRA→NV12（CIContext + buffer pool）
├── CFJitterBuffer.h/.m     # 4 帧环形缓冲（os_unfair_lock）
└── CFMenu.h/.m             # 悬浮控制面板
```

## 4. 构建（需要 theos；Windows 编不了 iOS arm64）

环境三选一：

1. **越狱设备端编译**（最省事）：设备加 Procursus 源，`apt install theos`，
   把整个 `CamForge/` 目录拷到设备，`cd CamForge && make package install`
2. **Mac/Linux**：按 theos.dev 官方文档装 toolchain + iOS SDK
3. **Docker**：社区镜像（如 `theos/theos`）

```bash
cd CamForge
make package          # 产出 .deb（.theos/ 下）
make install          # SSH 到设备时可用；否则 dpkg -i 后 respring/重启 App
```

注意 `camforge.plist` 里的 `com.example.targetapp` 换成你的目标 bundle id；
**研究建议先拿自建 demo App 试**，确认注入链路通了再换真目标。

## 5. 抖音实验指南（当前 plist 已指向 `com.ss.iphone.ugc.Aweme`）

**边界先说死**：自己设备 + 自己账号，只看拍摄/预览画面是否被替换。
不开播、不视频通话、不连麦、不外发——假画面一旦出现在别人眼前，
不管叫不叫实验，性质就变了。平台违规、封号、民事责任都是你自己的。

### 构建安装（越狱设备一条链）

```bash
# 1. 整个 CamForge/ 目录拷到设备（iFile/Filza/SCP 均可）
# 2. SSH 进设备：
apt install theos          # Procursus 源，已装则跳过
cd /var/mobile/CamForge    # 你拷贝的路径
make package               # 产出 .deb
dpkg -i .theos/*.deb       # 安装
killall -9 Aweme           # 冷启抖音（热启动不重载 tweak）
```

### 实验步骤与判读

1. 打开抖音 → 右上角出现 `CamForge (研究)` 悬浮面板
2. 进**拍摄页**（别开播！），点 **开始替换**
3. 看面板状态行/点 **诊断信息**，按计数判读：

| 诊断项 | 期望值 | 含义 |
|---|---|---|
| `sessionsSeen` | ≥1 | session 被 hook 到；抖音每切一个拍摄功能会 +1（补扫在工作） |
| `videoHookHits` | 持续增长 | **hook 命中了抖音的采集链路**——这是成败关键 |
| `injectedFrames` | 紧跟 videoHookHits | 帧真的换进去了，预览应显示渐变+帧号 |
| `passthroughFrames` | 0 | 没有透传帧漏过去 |
| `audioHookHits` | 视功能而定 | 视频通话类功能才有音频输出 |

4. **如果 `videoHookHits` 恒为 0**：抖音这块功能的采集没走 `AVCaptureVideoDataOutput`
   （可能包了自研抽象层或私有框架）——hook 没命中，换功能页面试，或回退到
   WebRTC 测试页（appr.tc）验证通用链路。这是预期内的未知，不是 bug。
5. 完事 **停止替换** 再退出抖音。

### 清理

```bash
dpkg -r com.camforge.research   # 卸载
killall -9 Aweme
```

### 回退到自建 demo App 验证

把 `camforge.plist` 里的 `com.ss.iphone.ugc.Aweme` 换成你的 bundle id，
重新 `make package && dpkg -i`。

## 6. 已知限制与扩展点

| 限制 | 原因 | 扩展方向 |
|---|---|---|
| 不支持 RTSP/RTP | AVFoundation 原生不解 RTSP | 链 FFmpeg `libavformat` 自写 `CFNetworkSource` 子类（原版走的就是这条路） |
| 固定 1280x720@30 | 简化 | 读 `session.sessionPreset` 动态设 `outputSize` |
| 单会话单源 | 简化 | per-session source map |
| UIWindow 无 scene 绑定 | iOS 13+ 多 scene App 下可能不显示 | 接 `UIWindowScene` |
| 无预览层替换 | 简化 | 另 hook `AVCaptureVideoPreviewLayer` 的 `session` 属性换 `AVSampleBufferDisplayLayer`（原版有 `VCamPreviewHook`） |

## 7. 验证清单（研究用）

- [ ] 合成图案注入成功（视觉确认帧号在跳）
- [ ] 停止替换后画面回真实相机（`stopReplacing` → jitter 排空）
- [ ] 切本地视频：循环播放无缝（EOF 重建 reader）
- [ ] 音频注入：440Hz 可闻；关闭后透传正常
- [ ] 杀 App 重进，hook 仍生效（Logos 构造器加载）
- [ ] delegate 在 session 运行中被更换（代理改指向，不崩）

---

*本项目为安全研究与教学用途的自研代码。使用产生的一切后果自行承担。*
