# make_submission.ps1 -- build the paper, then pack flash_v1_submission.zip (gitignored)
# with flash_v1.tex, refs.bib, the generated flash_v1.bbl and figures/, ready for
# Overleaf or a conference portal. The .bbl lets the portal print the references
# even if it does not run BibTeX.
#
#   powershell -ExecutionPolicy Bypass -File paper\make_submission.ps1

Push-Location $PSScriptRoot
try {
    & "$PSScriptRoot\build.ps1"
    if (-not $?) { throw 'build failed; no zip written' }
    $zip = Join-Path $PSScriptRoot 'flash_v1_submission.zip'
    if (Test-Path $zip) { Remove-Item $zip }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $files = @('flash_v1.tex', 'refs.bib', 'flash_v1.bbl') + (Get-ChildItem figures -File | ForEach-Object { "figures/$($_.Name)" })
    $z = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        # forward-slash entry names: Windows Compress-Archive writes backslashes,
        # which Linux-based portals extract as literal file names
        foreach ($f in $files) {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, (Join-Path $PSScriptRoot $f), $f)
        }
    }
    finally { $z.Dispose() }
    Write-Output "$zip ($($files.Count) files, $([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
}
finally { Pop-Location }
