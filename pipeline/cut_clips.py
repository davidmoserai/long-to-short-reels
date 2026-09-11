"""Cut the selected highlights out of the source video into standalone clip files."""

import argparse
import json
import subprocess
from pathlib import Path

FFMPEG = "/opt/homebrew/bin/ffmpeg"
PAD_SECONDS = 0.3  # small breathing room so cuts don't feel abrupt


def cut_clip(source: Path, start: float, end: float, output: Path):
    start_padded = max(0.0, start - PAD_SECONDS)
    duration = (end - start) + 2 * PAD_SECONDS

    subprocess.run(
        [
            FFMPEG, "-y",
            "-ss", f"{start_padded:.3f}",
            "-i", str(source),
            "-t", f"{duration:.3f}",
            "-c:v", "libx264", "-preset", "fast", "-crf", "18",
            "-c:a", "aac", "-b:a", "192k",
            str(output),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source_video", type=Path)
    parser.add_argument("highlights_path", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()

    highlights = json.loads(args.highlights_path.read_text())
    args.output_dir.mkdir(parents=True, exist_ok=True)

    for i, h in enumerate(highlights, start=1):
        filename = f"{i:02d}_{h['id']}_{h['momentType']}_score{h['score']}.mp4"
        output_path = args.output_dir / filename
        print(f"Cutting {filename} ({h['start']:.1f}-{h['end']:.1f}s, {h['durationSeconds']:.0f}s)...")
        cut_clip(args.source_video, h["start"], h["end"], output_path)

    print(f"\nWrote {len(highlights)} clips to {args.output_dir}")


if __name__ == "__main__":
    main()
