# make_board_bundle.ps1 -- assemble board_bundle/ for the PYNQ-Z2 (V1.2 / V1.2.1).
#
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File v1\board\make_board_bundle.ps1
# Output: <repo>\board_bundle\ (gitignored, rebuilt from scratch each run). Copy
# the whole folder to the board, to \\192.168.2.99\xilinx\jupyter_notebooks\flash_v1_2\ .
#
#   board_bundle\
#     flash_hp64.bit, flash_hp64.hwh    V1.2.1 overlay, HP0 64-bit (notebook default)
#     flash_hp32.bit, flash_hp32.hwh    V1.2 overlay, HP0 32-bit (AFI confirmation test)
#     flash_v1_2_board.ipynb            board notebook (BIT selects the overlay)
#     tools\flash_preprocess.py         DICOM -> uint8 preprocessing contract
#     vectors\img_0..243.mem            244 verification images (224x224 uint8)
#     vectors\exp_*.mem, gt_label.mem   golden-model expectations + labels

$ErrorActionPreference = 'Stop'
$repo   = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$board  = Join-Path $repo 'v1\board'
$export = Join-Path $repo 'v1\mem\v1_2\flash_v1_2'
$out    = Join-Path $repo 'board_bundle'
$files  = 'flash_hp64.bit', 'flash_hp64.hwh', 'flash_hp32.bit', 'flash_hp32.hwh', 'flash_v1_2_board.ipynb'

foreach ($f in $files) {
    if (-not (Test-Path (Join-Path $board $f))) { throw "missing v1\board\$f" }
}
$imgs = Get-ChildItem (Join-Path $export 'vectors') -Filter 'img_*.mem'
if ($imgs.Count -ne 244) { throw "expected 244 img_*.mem in $export\vectors, found $($imgs.Count)" }

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out, "$out\tools", "$out\vectors" | Out-Null
$files | ForEach-Object { Copy-Item (Join-Path $board $_) $out -Force }
Copy-Item (Join-Path $export 'tools\flash_preprocess.py') "$out\tools" -Force
$imgs | Copy-Item -Destination "$out\vectors" -Force
foreach ($f in 'exp_logit0.mem', 'exp_logit1.mem', 'exp_margin.mem', 'exp_decision.mem', 'gt_label.mem') {
    Copy-Item (Join-Path $export "vectors\$f") "$out\vectors" -Force
}

$n = (Get-ChildItem $out -Recurse -File).Count
$mb = [math]::Round(((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Output "board_bundle ready: $out ($n files, $mb MB)"
