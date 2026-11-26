# videojoin

Join short video clips into one file with smooth crossfades, automatically, from PowerShell.

Video is re-encoded losslessly (x264 CRF 0) and audio is written as 24-bit PCM, so the joined
file loses nothing compared with its parts. It works as an editing master and as a top-quality
upload (YouTube accepts it directly).

## Requirements

- PowerShell 7+
- `ffmpeg` and `ffprobe` on `PATH`

## Usage

```powershell
.\videojoin2.ps1                      # every clip in the current folder, in natural name order
.\videojoin2.ps1 1* 2*                # these clips, in this order
.\videojoin2.ps1 intro.mp4 main.mp4 -Crossfade 1
.\videojoin2.ps1 -Crossfade 0 -Output final.mov    # hard cuts
```

| Parameter | Default | Meaning |
|---|---|---|
| *(files)* | all clips in folder | Names, paths or wildcards, joined in the order given |
| `-Path` | current folder | Folder to scan; base for relative names |
| `-Crossfade` | `0.5` | Dissolve + audio crossfade length in seconds; `0` = hard cut |
| `-Clean` | off | Prefer `_clean` over `_master` versions (see below) |
| `-Output` | `joined_<N>clips_<timestamp>.mov` | Output file |

## What it does automatically

- **Picks one version per clip.** If a clip exists as `name_master`, `name_clean` and `name`,
  the best one is used (`_master` > `_clean` > original). Files ending in `_processed`,
  and earlier `joined_*` outputs, are ignored.
- **Natural order.** `clip2` comes before `clip10`.
- **Keeps sync.** Each clip's audio is padded or trimmed to its video's exact length before
  joining, so audio can't drift across many clips. Clips without audio get silence.
- **No clicks.** Audio is joined as decoded samples with crossfades (or 5 ms edge fades on
  hard cuts), avoiding the gaps and clicks of joining compressed AAC directly.
- **Safety checks.** Refuses clips with different resolution or frame rate, and crossfades
  too long for the shortest clip.

Each crossfade overlaps two clips, so the result is shorter than the sum of its parts by
the crossfade length per join.

## Notes

- Output is `.mov` because MP4 handles PCM audio poorly.
- Lossless H.264 uses the High 4:4:4 Predictive profile. VLC, ffplay, editors and YouTube
  handle it; some phone and built-in players do not.

## Licence

[AGPL-3.0](LICENSE)
