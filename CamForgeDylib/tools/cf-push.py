#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cf-push.py — 把电脑上的视频/摄像头实时推给手机上的 CamForge「直连」模式

传输通道和原版一致：usbmuxd（iTunes/Apple Mobile Device 那套端口转发）。
手机侧插件监听 127.0.0.1:9527，本脚本在电脑侧连到转发的本地端口，逐帧推 JPEG。

用法（先装 libimobiledevice：macOS `brew install libimobiledevice`，
Windows 用 iProxy.exe / 爱思助手的端口转发，或 `pip install pymobiledevice3`）：

  1) 转发端口（另开一个终端，保持运行）：
       iproxy 9527 9527
  2) 推视频文件：
       python cf-push.py video.mp4
     推电脑摄像头（USB 摄像头也算）：
       python cf-push.py --camera 0
     限帧率 / 降画质（带宽紧张时）：
       python cf-push.py video.mp4 --fps 15 --quality 60

帧格式（小端）：
  magic   4B  "CFRM"
  version 1B  0x01
  type    1B  0x01 = JPEG
  resv    2B  0
  length  4B  负载长度
  payload  N  JPEG 数据

依赖：优先用 OpenCV（pip install opencv-python）；没有 cv2 时退回调用系统 ffmpeg。
"""

import argparse
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

MAGIC = 0x4D524643          # "CFRM" little-endian
VERSION = 0x01
TYPE_JPEG = 0x01
TYPE_PCM = 0x02
HEADER = struct.Struct("<IBBH I")   # magic, version, type, resv, length

AUDIO_RATE = 44100
AUDIO_CH = 2
AUDIO_CHUNK = int(AUDIO_RATE * AUDIO_CH * 2 * 0.02)   # 20ms = 1764 字节


def log(msg):
    print(f"[cf-push] {msg}", flush=True)


def connect(host, port, retries=20, delay=0.5):
    for i in range(retries):
        try:
            s = socket.create_connection((host, port), timeout=5)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            log(f"已连接 {host}:{port}")
            return s
        except OSError as e:
            if i == 0:
                log(f"连接失败（{e}），重试中… 确认已运行 `iproxy {port} {port}`")
            time.sleep(delay)
    log("连不上，退出")
    sys.exit(1)


def send_packet(sock, pkt: bytes):
    sock.sendall(pkt)


def make_packet(ptype: int, payload: bytes) -> bytes:
    return HEADER.pack(MAGIC, VERSION, ptype, 0, len(payload)) + payload


# ── 帧源：OpenCV ────────────────────────────────────────────────────────────
def frames_cv2(src, camera, width, height, fps, quality):
    import cv2  # noqa

    cap = cv2.VideoCapture(camera if camera is not None else src)
    if not cap.isOpened():
        raise RuntimeError(f"打不开输入源: {src or camera}")
    if width:
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    if height:
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)

    native_fps = cap.get(cv2.CAP_PROP_FPS) or fps
    step = max(1, round(native_fps / fps)) if fps else 1
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            if camera is not None:
                break
            cap.set(cv2.CAP_PROP_POS_FRAMES, 0)   # 文件循环
            idx = 0
            continue
        idx += 1
        if step > 1 and idx % step != 0:
            continue
        ok, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
        if not ok:
            continue
        yield buf.tobytes()


# ── 帧源：ffmpeg（无 cv2 时） ───────────────────────────────────────────────
def frames_ffmpeg(src, camera, width, height, fps, quality):
    if not shutil.which("ffmpeg"):
        log("既没有 cv2 也没有 ffmpeg，先装一个：pip install opencv-python 或 apt/brew install ffmpeg")
        sys.exit(1)

    q = max(2, min(31, 32 - int(quality * 31 / 100)))
    args = ["ffmpeg", "-loglevel", "error", "-re"]
    args += ["-f", "avfoundation", "-i", str(camera)] if camera is not None else ["-stream_loop", "-1", "-i", src]
    if fps:
        args += ["-r", str(fps)]
    if width and height:
        args += ["-vf", f"scale={width}:{height}"]
    args += ["-f", "mjpeg", "-q:v", str(q), "-"]

    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    buf = bytearray()
    try:
        while True:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            buf.extend(chunk)
            # 按 SOI/EOI 切 JPEG
            while True:
                start = buf.find(b"\xff\xd8")
                if start < 0:
                    break
                end = buf.find(b"\xff\xd9", start + 2)
                if end < 0:
                    break
                yield bytes(buf[start:end + 2])
                del buf[:end + 2]
    finally:
        proc.kill()


def read_exact(stream, n):
    buf = b""
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return buf or None
        buf += chunk
    return buf


def audio_worker(sock, lock, path, stop_evt, loop=True):
    """把输入文件的音轨转成 s16le/44.1k/2ch，按 20ms 一包推给手机"""
    if not shutil.which("ffmpeg"):
        log("没有 ffmpeg，跳过音频推送")
        return
    while not stop_evt.is_set():
        proc = subprocess.Popen(
            ["ffmpeg", "-loglevel", "error", "-i", path, "-vn",
             "-ac", str(AUDIO_CH), "-ar", str(AUDIO_RATE), "-f", "s16le", "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        next_t = time.monotonic()
        try:
            while not stop_evt.is_set():
                data = read_exact(proc.stdout, AUDIO_CHUNK)
                if not data:
                    break
                with lock:
                    send_packet(sock, make_packet(TYPE_PCM, data))
                next_t += 0.02
                dt = next_t - time.monotonic()
                if dt > 0:
                    time.sleep(dt)
                else:
                    next_t = time.monotonic()
        except (BrokenPipeError, ConnectionResetError):
            stop_evt.set()
        finally:
            try:
                proc.kill()
            except Exception:
                pass
        if not loop or stop_evt.is_set():
            break
        time.sleep(0.2)


def main():
    ap = argparse.ArgumentParser(description="CamForge 直连推流（usbmuxd 通道）")
    ap.add_argument("source", nargs="?", help="视频文件路径（省略时配合 --camera）")
    ap.add_argument("--camera", type=int, default=None, help="摄像头序号，如 0（PC 的 USB 摄像头）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9527)
    ap.add_argument("--fps", type=float, default=30)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--quality", type=int, default=75, help="JPEG 质量 1-100")
    ap.add_argument("--no-audio", action="store_true", help="不推音频（只推画面）")
    args = ap.parse_args()

    if not args.source and args.camera is None:
        ap.print_help()
        sys.exit(2)

    try:
        import cv2  # noqa
        has_cv2 = True
    except Exception:
        has_cv2 = False

    log(f"帧源: {'OpenCV' if has_cv2 else 'ffmpeg'} | {args.width}x{args.height}@{args.fps} q={args.quality}")

    sock = connect(args.host, args.port)
    gen = (frames_cv2 if has_cv2 else frames_ffmpeg)(
        args.source, args.camera, args.width, args.height, args.fps, args.quality)

    sent = 0
    interval = 1.0 / args.fps if args.fps else 1 / 30
    t0 = time.time()
    send_lock = threading.Lock()
    stop_evt = threading.Event()

    # 音频线程：只在推文件且没关音频时启动（摄像头模式没有音轨）
    if args.source and not args.no_audio:
        threading.Thread(target=audio_worker,
                         args=(sock, send_lock, args.source, stop_evt),
                         daemon=True).start()

    try:
        for jpeg in gen:
            with send_lock:
                send_packet(sock, make_packet(TYPE_JPEG, jpeg))
            sent += 1
            if sent % 30 == 0:
                dt = time.time() - t0
                log(f"已推 {sent} 帧  {sent / dt:.1f} fps  {len(jpeg) / 1024:.0f} KB/帧")
            # 简单节流：OpenCV 路径读文件会冲得很快
            target = t0 + sent * interval
            now = time.time()
            if now < target:
                time.sleep(target - now)
    except (BrokenPipeError, ConnectionResetError):
        log("手机侧断开（关掉重连即可）")
    except KeyboardInterrupt:
        log(f"手动停止，共推 {sent} 帧")
    finally:
        stop_evt.set()
        sock.close()


if __name__ == "__main__":
    main()
