"""Split a word-level transcript into overlapping windows for highlight discovery.

Overlap is tied to MAX_CLIP_SECONDS so no candidate moment can straddle a
window boundary invisibly to both windows.
"""

import argparse
import json
from pathlib import Path

MAX_CLIP_SECONDS = 180  # platform ceiling (YouTube Shorts hard cap)
OVERLAP_SECONDS = MAX_CLIP_SECONDS
WINDOW_SECONDS = 600  # 10 min
STRIDE_SECONDS = WINDOW_SECONDS - OVERLAP_SECONDS  # 7 min


def format_window_text(words: list[dict]) -> str:
    lines = []
    current_speaker = None
    current_line: list[str] = []
    for w in words:
        if w["speaker"] != current_speaker:
            if current_line:
                lines.append(f"[Speaker {current_speaker}]: {' '.join(current_line)}")
            current_speaker = w["speaker"]
            current_line = []
        current_line.append(w["text"])
    if current_line:
        lines.append(f"[Speaker {current_speaker}]: {' '.join(current_line)}")
    return "\n".join(lines)


def build_windows(transcript: dict) -> list[dict]:
    words = transcript["words"]
    duration = transcript["durationSeconds"]

    windows = []
    window_start = 0.0
    window_id = 0
    while window_start < duration:
        window_end = min(window_start + WINDOW_SECONDS, duration)

        window_words = [
            (i, w)
            for i, w in enumerate(words)
            if w["start"] < window_end and w["end"] > window_start
        ]

        if window_words:
            first_idx = window_words[0][0]
            last_idx = window_words[-1][0]
            windows.append(
                {
                    "windowId": window_id,
                    "startTime": window_start,
                    "endTime": window_end,
                    "wordStartIdx": first_idx,
                    "wordEndIdx": last_idx,
                    "text": format_window_text([w for _, w in window_words]),
                }
            )
            window_id += 1

        if window_end >= duration:
            break
        window_start += STRIDE_SECONDS

    return windows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript_path", type=Path)
    parser.add_argument("output_path", type=Path)
    args = parser.parse_args()

    transcript = json.loads(args.transcript_path.read_text())
    windows = build_windows(transcript)

    args.output_path.write_text(json.dumps(windows, indent=2))
    print(f"Wrote {len(windows)} windows to {args.output_path}")
    for w in windows:
        print(
            f"  window {w['windowId']}: {w['startTime']/60:.1f}-{w['endTime']/60:.1f} min "
            f"({w['wordEndIdx']-w['wordStartIdx']+1} words)"
        )


if __name__ == "__main__":
    main()
