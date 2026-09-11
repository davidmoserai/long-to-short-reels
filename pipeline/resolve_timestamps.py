"""Recover exact word-level start/end timestamps for LLM-proposed candidates.

The model never sets timing directly -- it proposes verbatim quote anchors
(first few words, last few words of the moment) and we search the known
transcript for the best-matching word sequence. This is deterministic and
never trusts the model for numbers.
"""

import argparse
import json
import re
from difflib import SequenceMatcher
from pathlib import Path

MAX_CLIP_SECONDS = 180
SEARCH_WINDOW_WORDS = 1200  # generous cap on how far quoteEnd can be from quoteStart


def normalize(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", text.lower())


def tokenize(text: str) -> list[str]:
    return normalize(text).split()


def find_best_match(query_tokens: list[str], word_tokens: list[str], search_from: int, search_to: int):
    """Slide a window the length of query_tokens across word_tokens[search_from:search_to]
    and return (best_start_idx, best_ratio)."""
    n = len(query_tokens)
    if n == 0:
        return None, 0.0

    query_str = " ".join(query_tokens)
    best_idx = None
    best_ratio = 0.0

    search_to = min(search_to, len(word_tokens))
    for i in range(search_from, max(search_from, search_to - n + 1)):
        window = " ".join(word_tokens[i : i + n])
        ratio = SequenceMatcher(None, query_str, window).ratio()
        if ratio > best_ratio:
            best_ratio = ratio
            best_idx = i
        if ratio > 0.995:
            break

    return best_idx, best_ratio


def resolve_candidate(candidate: dict, word_tokens: list[str], words: list[dict]) -> dict:
    start_query = tokenize(candidate["quoteStart"])
    end_query = tokenize(candidate["quoteEnd"])

    start_idx, start_ratio = find_best_match(start_query, word_tokens, 0, len(word_tokens))
    if start_idx is None:
        return {**candidate, "resolved": False, "error": "quoteStart not found"}

    end_search_to = start_idx + SEARCH_WINDOW_WORDS
    end_idx, end_ratio = find_best_match(end_query, word_tokens, start_idx, end_search_to)
    if end_idx is None:
        return {**candidate, "resolved": False, "error": "quoteEnd not found"}

    end_word_idx = min(end_idx + len(end_query) - 1, len(words) - 1)
    start_time = words[start_idx]["start"]
    end_time = words[end_word_idx]["end"]
    duration = end_time - start_time

    confidence = min(start_ratio, end_ratio)

    return {
        **candidate,
        "resolved": True,
        "startWordIdx": start_idx,
        "endWordIdx": end_word_idx,
        "start": start_time,
        "end": end_time,
        "durationSeconds": duration,
        "matchConfidence": round(confidence, 3),
        "exceedsMaxLength": duration > MAX_CLIP_SECONDS,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript_path", type=Path)
    parser.add_argument("candidates_path", type=Path)
    parser.add_argument("output_path", type=Path)
    args = parser.parse_args()

    transcript = json.loads(args.transcript_path.read_text())
    candidates = json.loads(args.candidates_path.read_text())
    words = transcript["words"]
    word_tokens = [normalize(w["text"]) for w in words]

    resolved = [resolve_candidate(c, word_tokens, words) for c in candidates]

    args.output_path.write_text(json.dumps(resolved, indent=2))

    print(f"Resolved {sum(1 for r in resolved if r['resolved'])}/{len(resolved)} candidates")
    for r in resolved:
        if not r["resolved"]:
            print(f"  FAILED {r['id']}: {r.get('error')}")
        else:
            flag = " ⚠️  LOW CONFIDENCE" if r["matchConfidence"] < 0.85 else ""
            over = " ⚠️  OVER MAX LENGTH" if r["exceedsMaxLength"] else ""
            print(
                f"  {r['id']}: {r['start']/60:.2f}-{r['end']/60:.2f} min "
                f"({r['durationSeconds']:.1f}s) score={r['score']} conf={r['matchConfidence']}{flag}{over}"
            )


if __name__ == "__main__":
    main()
