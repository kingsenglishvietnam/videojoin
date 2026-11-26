<#
.SYNOPSIS
    videojoin3.ps1 - join video clips into one lossless video with smooth crossfades.

.DESCRIPTION
    Picks the clips, picks the best version of each, crossfades picture and sound, and
    writes a lossless master that is also a top-quality upload file.

    Which clips:
      - No arguments: every clip in -Path.
      - Arguments: file names, paths or wildcards (e.g. 1* 2*), joined in the order given.
        Within one wildcard, clips are in natural order (2 before 10).
    Which version of each clip (automatic):
      If a clip exists in several versions - name_master.mp4 (lossless), name_clean.mp4 and
      plain name.mp4 - the best one is used: _master > _clean > original. Files ending in
      _processed (intermediates) and earlier joined_* outputs are never used.
      -Clean prefers _clean over _master.

    Joins:
      - Default: 0.5 s crossfade of picture (dissolve) and sound. Keep speech or key sounds
        out of the first and last half-second of each clip and the overlap won't touch them.
      - -Crossfade 0: hard cut, with 5 ms fades on each clip's audio edges to stop clicks.
      Each clip's audio is first padded/trimmed to its video's exact length, so sync can't drift.
      Every crossfade shortens the result by its own length (the clips overlap).

    Output: joined_<N>clips_<timestamp>.mp4 (or .mov with -Audio pcm; or -Output).
    Video: x264 CRF 0 (lossless), kept at 4:2:0 like the source, colour tags copied from the
    first clip. Audio: lossless, 24-bit - FLAC (default), ALAC or PCM. YouTube accepts all three.
    Metadata from the source clips (titles, comments) is not carried over.
    Lossless H.264 uses the High 4:4:4 Predictive profile, so VLC, ffplay, editors and YouTube
    play it, but many built-in players (Windows Films & TV, QuickTime, phones) do not.

    Changes since v2:
      - Video kept at 4:2:0 (v2 let the crossfade upsample it to 4:4:4: bigger file, and the
        chroma no longer matched the source exactly).
      - Source metadata dropped (v2 copied the first clip's title/comment into the join).
      - -Audio flac|alac|pcm. Default FLAC in .mp4 (same sound as PCM, about half the size);
        ALAC in .mp4 for Apple-centric workflows; PCM in .mov is the v2 behaviour.

    Changes in v2: wording only (generic descriptions for the public repo).

.PARAMETER Files
    Optional. Clips to join, in order. Names, paths or wildcards. Positional; several allowed.
.PARAMETER Path
    Folder to scan when no files are given, and base for relative arguments. Default: current folder.
.PARAMETER Crossfade
    Crossfade length in seconds. Default 0.5. 0 = hard cut.
.PARAMETER Clean
    Prefer _clean over _master when both exist.
.PARAMETER Audio
    Lossless audio format: flac (default, .mp4), alac (Apple Lossless, .mp4) or pcm (.mov).
.PARAMETER Output
    Output file name/path. Default: joined_<N>clips_<yyyyMMdd-HHmmss>.mp4 (.mov for pcm) in -Path.

.EXAMPLE
    .\videojoin3.ps1                     # all clips in the folder, best version of each
.EXAMPLE
    .\videojoin3.ps1 1* 2*               # clip 1 then clip 2
.EXAMPLE
    .\videojoin3.ps1 intro.mp4 main.mp4 -Crossfade 1
.EXAMPLE
    .\videojoin3.ps1 -Crossfade 0 -Output final.mp4
.EXAMPLE
    .\videojoin3.ps1 -Audio alac                    # Apple Lossless audio
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Files,
    [string]$Path = '.',
    [ValidateRange(0, 10)][double]$Crossfade = 0.5,
    [switch]$Clean,
    [ValidateSet('flac', 'alac', 'pcm')][string]$Audio = 'flac',
    [string]$Output
)

$videoExt = '.mp4', '.m4v', '.mov', '.mkv', '.webm'
$inv = [Globalization.CultureInfo]::InvariantCulture

foreach ($t in 'ffmpeg', 'ffprobe') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t not found on PATH" }
}
$Path = (Resolve-Path -LiteralPath $Path).Path

# --- clip selection --------------------------------------------------------
function Get-NaturalKey([string]$Name) {
    [regex]::Replace($Name, '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}

function Get-ClipKey([IO.FileInfo]$F) {
    # base name without our suffixes -> groups original/_clean/_master of the same clip
    $F.BaseName -replace '_(master|clean\w*|processed|sigma\d+)$', ''
}

function Get-Rank([IO.FileInfo]$F) {
    $b = $F.BaseName
    if ($b -match '_processed$|_sigma\d+$') { return -1 }
    if ($b -match '_master$') { if ($Clean) { return 2 } else { return 3 } }
    if ($b -match '_clean$')  { if ($Clean) { return 3 } else { return 2 } }
    if ($b -match '_clean\w+$') { return -1 }        # test variants (_clean2, _clean_quarterbox)
    1                                                # original
}

function Select-Best([IO.FileInfo[]]$Candidates) {
    # one file per clip, best version, natural order
    $Candidates |
        Where-Object { $_.Extension.ToLower() -in $videoExt -and $_.Name -notmatch '^joined_' } |
        Where-Object { (Get-Rank $_) -ge 0 } |
        Group-Object { Get-ClipKey $_ } |
        ForEach-Object { $_.Group | Sort-Object { Get-Rank $_ } -Descending | Select-Object -First 1 } |
        Sort-Object { Get-NaturalKey $_.Name }
}

$parts = [Collections.Generic.List[IO.FileInfo]]::new()
$seen = @{}
if (-not $Files) {
    foreach ($f in (Select-Best @(Get-ChildItem -LiteralPath $Path -File))) { $parts.Add($f) }
} else {
    foreach ($item in $Files) {
        $full = if ([IO.Path]::IsPathRooted($item)) { $item } else { Join-Path $Path $item }
        $cands = if (Test-Path -LiteralPath $full -PathType Leaf) {
            @(Get-Item -LiteralPath $full)
        } else {
            @(Get-ChildItem -Path $full -File -ErrorAction SilentlyContinue)
        }
        $best = @(Select-Best $cands)
        if ($best.Count -eq 0) { Write-Warning "no usable clips match: $item"; continue }
        foreach ($f in $best) {
            $k = Get-ClipKey $f
            if ($seen.ContainsKey($k)) { Write-Warning "clip already included, skipping repeat: $($f.Name)"; continue }
            $seen[$k] = $true
            $parts.Add($f)
        }
    }
}
if ($parts.Count -lt 2) { throw "Need at least 2 clips to join, found $($parts.Count)." }

# --- probe -----------------------------------------------------------------
function Get-ClipInfo([string]$File) {
    $j = & ffprobe -v error `
        -show_entries stream=codec_type,width,height,r_frame_rate,duration,color_space,color_primaries,color_transfer,color_range:format=duration `
        -of json $File | Out-String | ConvertFrom-Json
    $v = $j.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
    $a = $j.streams | Where-Object codec_type -eq 'audio' | Select-Object -First 1
    [pscustomobject]@{
        Width    = [int]$v.width
        Height   = [int]$v.height
        Fps      = $v.r_frame_rate
        Duration = $(if ($v.duration -and $v.duration -ne 'N/A') { [double]::Parse($v.duration, $inv) }
                     else { [double]::Parse($j.format.duration, $inv) })
        HasAudio = [bool]$a
        Stream   = $v
    }
}

$infos = foreach ($p in $parts) { Get-ClipInfo $p.FullName }
$ref = $infos[0]
for ($i = 1; $i -lt $infos.Count; $i++) {
    $c = $infos[$i]
    if ($c.Width -ne $ref.Width -or $c.Height -ne $ref.Height -or $c.Fps -ne $ref.Fps) {
        throw "Clips differ: $($parts[0].Name) is $($ref.Width)x$($ref.Height)@$($ref.Fps), " +
              "$($parts[$i].Name) is $($c.Width)x$($c.Height)@$($c.Fps). Join needs matching size and frame rate."
    }
}
$minDur = ($infos | Measure-Object Duration -Minimum).Minimum
if ($Crossfade -gt 0 -and $Crossfade -ge $minDur / 2) {
    throw "Crossfade $Crossfade s is too long for the shortest clip ($([math]::Round($minDur, 2)) s)."
}

$colorArgs = @()
$cmap = [ordered]@{ color_space = '-colorspace'; color_primaries = '-color_primaries'; color_transfer = '-color_trc'; color_range = '-color_range' }
foreach ($k in $cmap.Keys) {
    $val = $ref.Stream.$k
    if ($val -and $val -notin 'unknown', 'reserved', 'unspecified') { $colorArgs += $cmap[$k], $val }
}

# --- filter graph ----------------------------------------------------------
$edge = if ($Crossfade -gt 0) { '' } else { ',afade=t=in:d=0.005,areverse,afade=t=in:d=0.005,areverse' }
$inputs = @(); $chains = @()
for ($i = 0; $i -lt $parts.Count; $i++) {
    $inputs += '-i', $parts[$i].FullName
    $dur = $infos[$i].Duration.ToString($inv)
    $chains += "[${i}:v]settb=AVTB,setsar=1,format=yuv420p[v$i]"
    $aSrc = if ($infos[$i].HasAudio) { "[${i}:a]" } else { 'anullsrc=r=48000:cl=stereo,' }
    $chains += "${aSrc}aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=0:$dur,asetpts=N/SR/TB$edge[a$i]"
}

if ($Crossfade -gt 0) {
    $d = $Crossfade.ToString($inv)
    $vPrev = 'v0'; $aPrev = 'a0'; $offset = 0.0
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $offset += $infos[$i - 1].Duration - $Crossfade
        $chains += "[$vPrev][v$i]xfade=transition=fade:duration=${d}:offset=$($offset.ToString($inv))[vx$i]"
        $chains += "[$aPrev][a$i]acrossfade=d=${d}[ax$i]"
        $vPrev = "vx$i"; $aPrev = "ax$i"
    }
    $vOut = $vPrev; $aOut = $aPrev
} else {
    $pairs = (0..($parts.Count - 1) | ForEach-Object { "[v$_][a$_]" }) -join ''
    $chains += "${pairs}concat=n=$($parts.Count):v=1:a=1[vout][aout]"
    $vOut = 'vout'; $aOut = 'aout'
}
$fc = $chains -join ';'

# --- output ----------------------------------------------------------------
$ext = if ($Audio -eq 'pcm') { '.mov' } else { '.mp4' }
$audioArgs = switch ($Audio) {
    'flac' { @('-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24') }
    'alac' { @('-c:a', 'alac', '-sample_fmt', 's32p', '-bits_per_raw_sample', '24') }
    'pcm'  { @('-c:a', 'pcm_s24le') }
}
if (-not $Output) { $Output = "joined_$($parts.Count)clips_$(Get-Date -Format 'yyyyMMdd-HHmmss')$ext" }
if (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $Path $Output }
if ([IO.Path]::GetExtension($Output).ToLower() -ne $ext) {
    Write-Warning "-Audio $Audio is meant for $ext; '$(Split-Path $Output -Leaf)' may not mux. Use a $ext name."
}
$muxArgs = if ($ext -eq '.mp4') { @('-movflags', '+faststart') } else { @() }

$total = ($infos | Measure-Object Duration -Sum).Sum - $Crossfade * ($parts.Count - 1)
Write-Host "Joining $($parts.Count) clips ($(if ($Crossfade -gt 0) { "$Crossfade s crossfade" } else { 'hard cut' })):"
for ($i = 0; $i -lt $parts.Count; $i++) {
    $note = if ($infos[$i].HasAudio) { '' } else { '  (no audio - silence)' }
    Write-Host ("  {0,2}. {1}  {2:0.00} s{3}" -f ($i + 1), $parts[$i].Name, $infos[$i].Duration, $note)
}
Write-Host ("  -> {0}  (~{1:0.00} s, lossless video, {2} audio)" -f (Split-Path $Output -Leaf), $total, $Audio.ToUpper())

& ffmpeg -hide_banner -loglevel error -stats -y @inputs `
    -filter_complex $fc `
    -map "[$vOut]" -map "[$aOut]" `
    -map_metadata -1 `
    -c:v libx264 -preset slow -crf 0 -pix_fmt yuv420p `
    @colorArgs `
    @audioArgs `
    @muxArgs `
    $Output
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Output)) { throw 'ffmpeg failed' }

$o = Get-Item -LiteralPath $Output
Write-Host ("[OK] {0}  ({1:0.0} MB)" -f $o.Name, ($o.Length / 1MB))
