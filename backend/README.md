# AudioTranscriber Backend (Diarization MVP)

## Requisitos
- Python 3.11+
- FFmpeg instalado
- (Opcional, para diarização multi-locutor real) token Hugging Face com acesso a `pyannote/speaker-diarization-3.1`

## Setup
```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Variáveis
- `WHISPER_MODEL` (default: `small`)
- `HF_TOKEN` (opcional, ativa diarização real multi-locutor)

## Rodar
```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## Endpoint
`POST /diarize-transcribe`
- multipart `file`
- query opcional `language` (pt, en, es...)

Resposta:
```json
{
  "text": "[00:01] Locutor 1: ...",
  "segments": [
    {"start": 1.0, "end": 3.2, "speaker": "Locutor 1", "text": "..."}
  ]
}
```
