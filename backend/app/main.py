from __future__ import annotations

import os
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, File, HTTPException, UploadFile
from pydantic import BaseModel

app = FastAPI(title="AudioTranscriber Diarization API", version="0.1.0")


class SegmentOut(BaseModel):
    start: float
    end: float
    speaker: str
    text: str


class DiarizeResponse(BaseModel):
    text: str
    segments: List[SegmentOut]


@dataclass
class _DiarSegment:
    start: float
    end: float
    speaker: str


_whisper_model = None
_pyannote_pipeline = None


def _load_whisper():
    global _whisper_model
    if _whisper_model is None:
        from faster_whisper import WhisperModel

        model_name = os.getenv("WHISPER_MODEL", "small")
        _whisper_model = WhisperModel(model_name, device="cpu", compute_type="int8")
    return _whisper_model


def _load_pyannote():
    global _pyannote_pipeline
    if _pyannote_pipeline is None:
        token = os.getenv("HF_TOKEN")
        if not token:
            return None
        from pyannote.audio import Pipeline

        _pyannote_pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1", use_auth_token=token
        )
    return _pyannote_pipeline


def _transcribe(path: str, language: Optional[str]) -> List[dict]:
    model = _load_whisper()
    segments, _ = model.transcribe(path, language=language, vad_filter=True)
    out = []
    for s in segments:
        text = (s.text or "").strip()
        if not text:
            continue
        out.append({"start": float(s.start), "end": float(s.end), "text": text})
    return out


def _diarize(path: str) -> List[_DiarSegment]:
    pipeline = _load_pyannote()
    if pipeline is None:
        return []

    diarization = pipeline(path)
    out: List[_DiarSegment] = []
    speaker_map: dict[str, int] = {}
    next_id = 1

    for turn, _, speaker in diarization.itertracks(yield_label=True):
        if speaker not in speaker_map:
            speaker_map[speaker] = next_id
            next_id += 1
        out.append(
            _DiarSegment(
                start=float(turn.start),
                end=float(turn.end),
                speaker=f"Locutor {speaker_map[speaker]}",
            )
        )
    return out


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _assign_speaker(seg: dict, diar: List[_DiarSegment]) -> str:
    best = "Locutor 1"
    best_ol = 0.0
    for d in diar:
        ol = _overlap(seg["start"], seg["end"], d.start, d.end)
        if ol > best_ol:
            best_ol = ol
            best = d.speaker
    return best


def _format_ts(seconds: float) -> str:
    sec = int(round(seconds))
    return f"{sec // 60:02d}:{sec % 60:02d}"


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/diarize-transcribe", response_model=DiarizeResponse)
async def diarize_transcribe(file: UploadFile = File(...), language: Optional[str] = None):
    suffix = Path(file.filename or "audio.m4a").suffix or ".m4a"
    temp_dir = tempfile.mkdtemp(prefix="audiotranscriber_")
    temp_path = Path(temp_dir) / f"input{suffix}"

    try:
        with temp_path.open("wb") as f:
            content = await file.read()
            if not content:
                raise HTTPException(status_code=400, detail="Arquivo vazio")
            f.write(content)

        asr_segments = _transcribe(str(temp_path), language)
        if not asr_segments:
            raise HTTPException(status_code=422, detail="Sem fala detectada")

        diar_segments = _diarize(str(temp_path))
        out_segments: List[SegmentOut] = []

        for seg in asr_segments:
            speaker = _assign_speaker(seg, diar_segments) if diar_segments else "Locutor 1"
            out_segments.append(
                SegmentOut(
                    start=seg["start"],
                    end=seg["end"],
                    speaker=speaker,
                    text=seg["text"],
                )
            )

        merged_lines = [
            f"[{_format_ts(s.start)}] {s.speaker}: {s.text}" for s in out_segments
        ]
        return DiarizeResponse(text="\n".join(merged_lines), segments=out_segments)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
