# build.ps1 -- build flash_v1.pdf with its references: pdflatex, bibtex, pdflatex, pdflatex.
#
#   powershell -ExecutionPolicy Bypass -File paper\build.ps1
#
# A pdflatex-only build (one run, no bibtex) prints every citation as [?] and no
# reference list, so always build with this script, latexmk (paper/latexmkrc) or
# the LaTeX Workshop recipe in .vscode/settings.json. Fails if a citation or
# reference is undefined or BibTeX warns; prints the page count.

$ErrorActionPreference = 'Continue'
Push-Location $PSScriptRoot
try {
    if (-not (Get-Command pdflatex -ErrorAction SilentlyContinue)) {
        $miktex = "$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64"
        if (Test-Path "$miktex\pdflatex.exe") { $env:Path = "$miktex;$env:Path" }
        else { throw 'pdflatex not found: install MiKTeX or TeX Live' }
    }
    function Invoke-Step($exe, [string[]]$argList, [int]$okMax) {
        & $exe @argList *> $null
        if ($LASTEXITCODE -gt $okMax) { throw "$exe $argList failed (exit $LASTEXITCODE); see flash_v1.log / flash_v1.blg" }
    }
    $tex = @('-interaction=nonstopmode', '-halt-on-error', '-file-line-error', 'flash_v1.tex')
    Invoke-Step pdflatex $tex 0
    Invoke-Step bibtex @('flash_v1') 1          # bibtex exits 1 on warnings; checked below
    Invoke-Step pdflatex $tex 0
    Invoke-Step pdflatex $tex 0

    $log = Get-Content flash_v1.log -Raw
    $blg = Get-Content flash_v1.blg -Raw
    $problems = @()
    if ($log -match "Citation `.*' (on page \d+ )?undefined") { $problems += 'undefined citation' }
    if ($log -match 'There were undefined references') { $problems += 'undefined reference' }
    if ($log -match 'Label\(s\) may have changed') { $problems += 'labels changed (rerun needed)' }
    if ($blg -match 'Warning--') { $problems += 'BibTeX warning' }
    $pages = [regex]::Match($log, 'Output written on flash_v1\.pdf \((\d+) pages').Groups[1].Value
    $entries = ([regex]::Matches((Get-Content flash_v1.bbl -Raw), '\\bibitem')).Count
    if ($problems) { throw "build finished with: $($problems -join ', ')" }
    Write-Output "flash_v1.pdf: $pages pages, $entries references, no undefined citations"
}
finally { Pop-Location }
