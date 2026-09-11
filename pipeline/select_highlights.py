"""Finalize highlight selection: enforce length bounds, dedupe overlaps,
rank by score, and cut at the natural elbow in the score distribution.

No hardcoded clip count. No hardcoded clip length beyond the platform
ceiling. The number of clips we end up with is whatever clears the bar.
"""

import argparse
import json
from pathlib import Path

MIN_CLIP_SECONDS = 20
MAX_CLIP_SECONDS = 180
OVERLAP_MERGE_THRESHOLD = 0.5  # fraction of the shorter clip that must overlap to count as duplicate


def extend_to_min_length(candidate: dict, words: list[dict]) -> dict:
    """If a clip is shorter than MIN_CLIP_SECONDS, extend its end forward to the
    next sentence-ending punctuation, capped at MAX_CLIP_SECONDS."""
    if candidate["durationSeconds"] >= MIN_CLIP_SECONDS:
        return candidate

    end_idx = candidate["endWordIdx"]
    start_time = candidate["start"]

    for i in range(end_idx + 1, len(words)):
        w = words[i]
        duration = w["end"] - start_time
        if duration > MAX_CLIP_SECONDS:
            break
        ends_sentence = w["text"].rstrip().endswith((".", "?", "!"))
        if ends_sentence and duration >= MIN_CLIP_SECONDS:
            end_idx = i
            break
        end_idx = i

    new_end = words[end_idx]["end"]
    return {
        **candidate,
        "endWordIdx": end_idx,
        "end": new_end,
        "durationSeconds": new_end - start_time,
        "extended": True,
    }


def trim_to_max_length(candidate: dict) -> dict:
    if candidate["durationSeconds"] <= MAX_CLIP_SECONDS:
        return candidate
    return {**candidate, "flaggedOverLength": True}


def overlap_fraction(a: dict, b: dict) -> float:
    latest_start = max(a["start"], b["start"])
    earliest_end = min(a["end"], b["end"])
    overlap = max(0.0, earliest_end - latest_start)
    shorter = min(a["durationSeconds"], b["durationSeconds"])
    return overlap / shorter if shorter > 0 else 0.0


def dedupe(candidates: list[dict]) -> list[dict]:
    """Keep the higher-scoring candidate whenever two overlap significantly."""
    kept: list[dict] = []
    for c in sorted(candidates, key=lambda x: -x["score"]):
        if any(overlap_fraction(c, k) > OVERLAP_MERGE_THRESHOLD for k in kept):
            continue
        kept.append(c)
    return kept


def elbow_cutoff(candidates: list[dict]) -> list[dict]:
    """Sort by score descending, keep everything up to the biggest score gap."""
    ranked = sorted(candidates, key=lambda x: -x["score"])
    if len(ranked) <= 1:
        return ranked

    gaps = [(ranked[i]["score"] - ranked[i + 1]["score"], i) for i in range(len(ranked) - 1)]
    biggest_gap, cut_idx = max(gaps, key=lambda g: g[0])

    return ranked[: cut_idx + 1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript_path", type=Path)
    parser.add_argument("resolved_candidates_path", type=Path)
    parser.add_argument("output_path", type=Path)
    args = parser.parse_args()

    transcript = json.loads(args.transcript_path.read_text())
    words = transcript["words"]
    candidates = json.loads(args.resolved_candidates_path.read_text())

    resolved = [c for c in candidates if c.get("resolved")]

    extended = [extend_to_min_length(c, words) for c in resolved]
    bounded = [trim_to_max_length(c) for c in extended]
    valid = [c for c in bounded if not c.get("flaggedOverLength")]

    deduped = dedupe(valid)
    selected = elbow_cutoff(deduped)
    selected.sort(key=lambda x: x["start"])

    args.output_path.write_text(json.dumps(selected, indent=2))

    print(f"{len(resolved)} resolved -> {len(deduped)} after dedupe -> {len(selected)} selected (elbow cutoff)")
    for c in selected:
        ext = " (extended)" if c.get("extended") else ""
        print(
            f"  {c['id']} [{c['momentType']}] score={c['score']} "
            f"{c['start']/60:.2f}-{c['end']/60:.2f} min ({c['durationSeconds']:.0f}s){ext}"
        )


if __name__ == "__main__":
    main()
