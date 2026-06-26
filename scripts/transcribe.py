#!/usr/bin/env python3
"""AudioTranscriber 本地 ASR 转写脚本。

使用 sherpa-onnx SenseVoice 模型进行离线语音转文字。
输出 JSON 行到 stdout，每行一条消息：
  {"type": "progress", "value": 50}
  {"type": "segment",  "index": 3, "text": "...", "total": 12}  # 每段完成后立即输出
  {"type": "result", "text": "转写内容..."}
  {"type": "error", "message": "错误描述"}

用法：
  python3 transcribe.py <audio_wav> [title]
                       [--start-frame N] [--end-frame N]
                       [--partial-file PATH] [--resume-from-segment N]

参数：
  --start-frame  从原始 wav 的第 N 帧开始读（基于 wav 实际采样率，非 16k）
  --end-frame    读到原始 wav 的第 N 帧为止（不含），N=0 或省略 → 读到文件结尾
  指定 start/end 时，脚本进入"滑窗模式"：只对该区间转写，作为整段单次喂给 SenseVoice。
  适合实时流式滑窗场景，窗口长度建议 ≤25s。

  --partial-file        每段 chunk 完成后立即将文本追加到该文件（断点续转的 sidecar）
  --resume-from-segment 从第 N 段（含）开始转写，前面的段直接跳过文件读取（断点续转用）

依赖：sherpa-onnx, numpy
模型：~/.cache/sherpa-onnx-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/
"""

import json
import sys
import wave
from datetime import datetime
from pathlib import Path

import numpy as np
import sherpa_onnx

MODEL_DIR = (
    Path.home()
    / ".cache"
    / "sherpa-onnx-models"
    / "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
)

CHUNK_SEC = 20  # SenseVoice 每段最多 ~30s，留余量
NUM_THREADS = 4
TARGET_SR = 16000  # SenseVoice 训练采样率


def resample_linear(samples: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    """线性插值重采样（SenseVoice 需要 16k）"""
    if src_sr == dst_sr:
        return samples
    src_len = len(samples)
    dst_len = int(src_len * dst_sr / src_sr)
    if dst_len <= 0:
        return samples
    x_src = np.linspace(0, 1, src_len, endpoint=False, dtype=np.float64)
    x_dst = np.linspace(0, 1, dst_len, endpoint=False, dtype=np.float64)
    return np.interp(x_dst, x_src, samples).astype(np.float32)


def log_json(msg_type: str, **kwargs):
    """输出 JSON 行到 stdout"""
    obj = {"type": msg_type, **kwargs}
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def _samples_from_bytes(frames: bytes, sample_width: int) -> np.ndarray:
    if sample_width == 4:
        return np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
    if sample_width == 2:
        return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    return np.frombuffer(frames, dtype=np.uint8).astype(np.float32) / 128.0 - 1.0


def _transcribe_window(
    f, recognizer, window_frames: int, bytes_per_frame: int,
    sample_width: int, num_channels: int, sr: int,
) -> str:
    """滑窗模式：把整个窗口当一段送给 SenseVoice，返回单段文本"""
    frames = f.read(window_frames * bytes_per_frame)
    if not frames:
        return ""
    samples = _samples_from_bytes(frames, sample_width)
    if num_channels > 1:
        samples = samples.reshape(-1, num_channels).mean(axis=1)
    samples_16k = resample_linear(samples, sr, TARGET_SR)

    seg_rms = float(np.sqrt(np.mean(samples_16k * samples_16k))) if len(samples_16k) else 0.0
    seg_peak = float(np.max(np.abs(samples_16k))) if len(samples_16k) else 0.0
    if seg_rms < 0.003 and seg_peak < 0.02:
        log_json("progress", value=100)
        return ""

    stream = recognizer.create_stream()
    stream.accept_waveform(TARGET_SR, samples_16k.tolist())
    recognizer.decode_stream(stream)
    text = stream.result.text.strip()
    log_json("progress", value=100)

    if not text or text == ".":
        return ""
    has_real = any('\u4e00' <= c <= '\u9fff' or c.isalpha() for c in text)
    if not has_real or len(text) < 2:
        return ""
    return text


def _append_partial(partial_file: Path | None, seg_idx: int, text: str):
    """把单段文本以「索引\\t文本」的格式追加到 sidecar 文件，fsync 保证落盘"""
    if partial_file is None or not text:
        return
    try:
        partial_file.parent.mkdir(parents=True, exist_ok=True)
        with open(partial_file, "a", encoding="utf-8") as pf:
            pf.write(f"{seg_idx}\t{text}\n")
            pf.flush()
            import os
            os.fsync(pf.fileno())
    except Exception as e:
        # 不阻塞主流程，只记一行 stderr
        print(f"[transcribe.py] partial flush failed: {e}", file=sys.stderr, flush=True)


def transcribe(
    audio_path: Path,
    start_frame: int = 0,
    end_frame: int = 0,
    partial_file: Path | None = None,
    resume_from_segment: int = 0,
) -> str:
    """转写音频文件，返回完整文本

    start_frame/end_frame > 0 时进入滑窗模式：只对该帧区间做一次性转写（不分 chunk）
    partial_file: 每段完成立即追加到该 sidecar
    resume_from_segment: 从第 N 段（含）开始；前面的段直接 seek 跳过
    """

    if not audio_path.exists():
        log_json("error", message=f"文件不存在: {audio_path}")
        return ""

    if not MODEL_DIR.exists():
        log_json("error", message=f"SenseVoice 模型未安装: {MODEL_DIR}")
        return ""

    try:
        recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(MODEL_DIR / "model.int8.onnx"),
            tokens=str(MODEL_DIR / "tokens.txt"),
            use_itn=True,
            language="auto",
            num_threads=NUM_THREADS,
        )
    except Exception as e:
        log_json("error", message=f"模型加载失败: {e}")
        return ""

    # 读取音频（手动解析 WAV 头，绕开 wave 模块对 dataSize 字段的强依赖
    # —— 录制中 header dataSize=0，但实际数据已写入；按文件实际大小计算 frames）
    try:
        with open(audio_path, "rb") as f:
            header = f.read(44)
            if len(header) < 44 or header[:4] != b"RIFF" or header[8:12] != b"WAVE":
                log_json("error", message="非 WAV 文件或文件头不完整")
                return ""

            # fmt chunk 关键字段
            sr = int.from_bytes(header[24:28], "little")
            num_channels = int.from_bytes(header[22:24], "little")
            bits_per_sample = int.from_bytes(header[34:36], "little")
            sample_width = bits_per_sample // 8

            # 直接按文件大小推算数据长度，忽略 header 中的 dataSize（录制中可能为 0）
            file_size = audio_path.stat().st_size
            data_bytes = max(0, file_size - 44)
            bytes_per_frame = sample_width * num_channels
            total_frames = data_bytes // bytes_per_frame if bytes_per_frame > 0 else 0

            if sr == 0 or total_frames == 0:
                log_json("error", message=f"音频文件无有效数据: sr={sr}, frames={total_frames}")
                return ""

            # 滑窗模式：只读 [start_frame, end_frame) 区间
            window_mode = start_frame > 0 or end_frame > 0
            if window_mode:
                eff_start = max(0, start_frame)
                eff_end = end_frame if end_frame > 0 else total_frames
                eff_end = min(eff_end, total_frames)
                if eff_end <= eff_start:
                    log_json("error", message=f"无效窗口: [{eff_start}, {eff_end})")
                    return ""
                f.seek(44 + eff_start * bytes_per_frame)
                window_frames = eff_end - eff_start
                return _transcribe_window(
                    f, recognizer, window_frames, bytes_per_frame,
                    sample_width, num_channels, sr,
                )

            chunk_frames = sr * CHUNK_SEC
            chunk_bytes = chunk_frames * bytes_per_frame
            total_segments = (total_frames + chunk_frames - 1) // chunk_frames

            # 断点续转：跳过前 resume_from_segment 段
            resume_idx = max(0, resume_from_segment)
            if resume_idx > 0:
                skip_frames = min(total_frames, resume_idx * chunk_frames)
                f.seek(44 + skip_frames * bytes_per_frame)
                pos = skip_frames
                seg_idx = resume_idx
                log_json(
                    "progress",
                    value=min(99, int(pos / total_frames * 100)) if total_frames > 0 else 0,
                )
            else:
                f.seek(44)
                pos = 0
                seg_idx = 0

            all_text: list[str] = []
            while pos < total_frames:
                n = min(chunk_frames, total_frames - pos)
                frames = f.read(n * bytes_per_frame)
                if not frames:
                    break

                # 根据位深归一化
                if sample_width == 4:
                    samples = (
                        np.frombuffer(frames, dtype=np.int32).astype(np.float32)
                        / 2147483648.0
                    )
                elif sample_width == 2:
                    samples = (
                        np.frombuffer(frames, dtype=np.int16).astype(np.float32)
                        / 32768.0
                    )
                else:
                    samples = (
                        np.frombuffer(frames, dtype=np.uint8).astype(np.float32)
                        / 128.0
                        - 1.0
                    )

                # 多声道下混为单声道
                if num_channels > 1:
                    samples = samples.reshape(-1, num_channels).mean(axis=1)

                # 重采样到 16k（SenseVoice 训练采样率）
                samples_16k = resample_linear(samples, sr, TARGET_SR)

                # 段级 VAD：能量过低直接跳过，避免模型产生幻觉
                seg_rms = float(np.sqrt(np.mean(samples_16k * samples_16k))) if len(samples_16k) else 0.0
                seg_peak = float(np.max(np.abs(samples_16k))) if len(samples_16k) else 0.0
                if seg_rms < 0.003 and seg_peak < 0.02:
                    # 静音段也要标记为已完成，避免下次又从这里开始
                    _append_partial(partial_file, seg_idx, "")
                    log_json("segment", index=seg_idx, text="", total=total_segments)
                    pos += n
                    seg_idx += 1
                    continue

                stream = recognizer.create_stream()
                stream.accept_waveform(TARGET_SR, samples_16k.tolist())
                recognizer.decode_stream(stream)
                text = stream.result.text.strip()

                # 过滤幻觉：纯标点、过短、无中英文字符
                seg_text = ""
                if text and text != ".":
                    has_real = any('\u4e00' <= c <= '\u9fff' or c.isalpha() for c in text)
                    if has_real and len(text) >= 2:
                        seg_text = text
                        all_text.append(text)

                # 段完成 → 立即落盘 + 输出 segment 事件
                _append_partial(partial_file, seg_idx, seg_text)
                log_json("segment", index=seg_idx, text=seg_text, total=total_segments)

                pos += n
                seg_idx += 1

                # 每段都报告一次进度（chunk 粒度足够稀疏，不会刷屏）
                pct = min(99, int(pos / total_frames * 100))
                log_json("progress", value=pct)

            if not all_text and resume_idx == 0:
                log_json("error", message="转写结果为空，音频可能无有效语音内容")
                return ""

            transcript = "\n".join(all_text)
            log_json("progress", value=100)
            return transcript

    except Exception as e:
        log_json("error", message=f"转写异常: {e}")
        return ""


def main():
    if len(sys.argv) < 2:
        log_json("error", message=f"用法: {sys.argv[0]} <audio_wav> [title] [--start-frame N] [--end-frame N] [--partial-file PATH] [--resume-from-segment N]")
        sys.exit(1)

    # 解析参数
    args = sys.argv[1:]
    audio_path = Path(args[0])
    start_frame = 0
    end_frame = 0
    partial_file: Path | None = None
    resume_from_segment = 0
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--start-frame" and i + 1 < len(args):
            try: start_frame = int(args[i + 1])
            except ValueError: pass
            i += 2
        elif a == "--end-frame" and i + 1 < len(args):
            try: end_frame = int(args[i + 1])
            except ValueError: pass
            i += 2
        elif a == "--partial-file" and i + 1 < len(args):
            partial_file = Path(args[i + 1])
            i += 2
        elif a == "--resume-from-segment" and i + 1 < len(args):
            try: resume_from_segment = int(args[i + 1])
            except ValueError: pass
            i += 2
        else:
            i += 1

    result = transcribe(
        audio_path,
        start_frame=start_frame,
        end_frame=end_frame,
        partial_file=partial_file,
        resume_from_segment=resume_from_segment,
    )

    if result:
        log_json("result", text=result)


if __name__ == "__main__":
    main()
