# build.ps1 -- build flash_v1.pdf: pdflatex twice (a third run if labels moved).
#
#   powershell -ExecutionPolicy Bypass -File paper\build.ps1
#
# The reference list is embedded in flash_v1.tex (thebibliography), so no BibTeX
# run is needed; the second pdflatex run resolves the citation numbers. Fails if
# a citation or reference is undefined; prints the page and reference counts.

$ErrorActionPreference = 'Continue'
Push-Location $PSScriptRoot
try {
    if (-not (Get-Command pdflatex -ErrorAction SilentlyContinue)) {
        $miktex = "$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64"
        if (Test-Path "$miktex\pdflatex.exe") { $env:Path = "$miktex;$env:Path" }
        else { throw 'pdflatex not found: install MiKTeX or TeX Live' }
    }
    $tex = @('-interaction=nonstopmode', '-halt-on-error', '-file-line-error', 'flash_v1.tex')
    foreach ($run in 1..3) {
        & pdflatex @tex *> $null
        if ($LASTEXITCODE) { throw "pdflatex failed (exit $LASTEXITCODE); see flash_v1.log" }
        $log = Get-Content flash_v1.log -Raw
        if ($run -ge 2 -and $log -notmatch 'Label\(s\) may have changed') { break }
    }
    $problems = @()
    if ($log -match "Citation `.*' (on page \d+ )?undefined") { $problems += 'undefined citation' }
    if ($log -match 'There were undefined references') { $problems += 'undefined reference' }
    if ($problems) { throw "build finished with: $($problems -join ', ')" }
    $pages = [regex]::Match($log, 'Output written on flash_v1\.pdf \((\d+) pages').Groups[1].Value
    $entries = ([regex]::Matches((Get-Content flash_v1.tex -Raw), '\\bibitem\{')).Count
    Write-Output "flash_v1.pdf: $pages pages, $entries references, no undefined citations"
}
finally { Pop-Location }
