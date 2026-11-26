<#
.SYNOPSIS
    videojoin1.ps1 - join cleaned clips into one lossless video with smooth crossfades.

.DESCRIPTION
    Picks the clips, picks the best version of each, crossfades picture and sound, and
    writes a lossless master that is also a top-quality upload file.

    Which clips:
      - No arguments: every clip in -Path.
      - Arguments: file names, paths or wildcards (e.g. 1* 2*), joined in the order given.
        Within one wildcard, clips are in natural order (2 before 10).
    Which version of each clip (automatic):
      _master (lossless) > _clean > original. _processed files and earlier joined_* outputs
      are never used. -Clean prefers _clean over _master.

    Joins:
      - Default: 0.5 s crossfade of picture (dissolve) and sound. Your prompts keep narration
        between 0.5 s and 9 s of each 10 s clip, so the overlap lands in the quiet margins.
      - -Crossfade 0: hard cut, with 5 ms fades on each clip's audio edges to stop clicks.
      Each clip's audio is first padded/trimmed to its video's exact length, so sync can't drift.
      Every crossfade shortens the result by its own length (the clips overlap).

    Output: joined_<N>clips_<timestamp>.mov (or -Output). Video x264 CRF 0 (lossless),
    audio 24-bit PCM, colour tags copied from the first clip. YouTube accepts it directly.
    Plays in VLC/ffplay/editors; the Windows default player may not open lossless H.264.

.PARAMETER Files
    Optional. Clips to join, in order. Names, paths or wildcards. Positional; several allowed.
.PARAMETER Path
    Folder to scan when no files are given, and base for relative arguments. Default: current folder.
.PARAMETER Crossfade
    Crossfade length in seconds. Default 0.5. 0 = hard cut.
.PARAMETER Clean
    Prefer _clean over _master when both exist.
.PARAMETER Output
    Output file name/path. Default: joined_<N>clips_<yyyyMMdd-HHmmss>.mov in -Path.

.EXAMPLE
    .\videojoin1.ps1                     # all clips in the folder, best version of each
.EXAMPLE
    .\videojoin1.ps1 1* 2*               # clip 1 then clip 2
.EXAMPLE
    .\videojoin1.ps1 *pinhole* *god* -Crossfade 1
.EXAMPLE
    .\videojoin1.ps1 -Crossfade 0 -Output final.mov
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Files,
    [string]$Path = '.',
    [ValidateRange(0, 10)][double]$Crossfade = 0.5,
    [switch]$Clean,
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
if (-not $Output) { $Output = "joined_$($parts.Count)clips_$(Get-Date -Format 'yyyyMMdd-HHmmss').mov" }
if (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $Path $Output }

$total = ($infos | Measure-Object Duration -Sum).Sum - $Crossfade * ($parts.Count - 1)
Write-Host "Joining $($parts.Count) clips ($(if ($Crossfade -gt 0) { "$Crossfade s crossfade" } else { 'hard cut' })):"
for ($i = 0; $i -lt $parts.Count; $i++) {
    $note = if ($infos[$i].HasAudio) { '' } else { '  (no audio - silence)' }
    Write-Host ("  {0,2}. {1}  {2:0.00} s{3}" -f ($i + 1), $parts[$i].Name, $infos[$i].Duration, $note)
}
Write-Host ("  -> {0}  (~{1:0.00} s)" -f (Split-Path $Output -Leaf), $total)

& ffmpeg -hide_banner -loglevel error -stats -y @inputs `
    -filter_complex $fc `
    -map "[$vOut]" -map "[$aOut]" `
    -c:v libx264 -preset slow -crf 0 `
    @colorArgs `
    -c:a pcm_s24le `
    $Output
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Output)) { throw 'ffmpeg failed' }

$o = Get-Item -LiteralPath $Output
Write-Host ("[OK] {0}  ({1:0.0} MB)" -f $o.Name, ($o.Length / 1MB))
