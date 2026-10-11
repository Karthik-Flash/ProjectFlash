# paper/: FLASH V1 conference paper

IEEE conference format (`IEEEtran`, two-column), written from
[`../PROJECT_FLASH_REPORT.md`](../PROJECT_FLASH_REPORT.md). Every number in it
also appears in the report or in a repository file the report cites.

| File | What it is |
|---|---|
| `flash_v1.tex` | The paper, self-contained: the system diagram (Fig. 1) is TikZ and the 32 references are embedded as `thebibliography`, in citation order. |
| `refs.bib` | The same 32 references as BibTeX records, each checked against its DOI record, arXiv entry or issuing body's page. The embedded list was generated from it with `IEEEtran.bst`. |
| `figures/` | Vector PDF plots (serif text, sized for a 3.5 in column or the 7.16 in page), written by `python tools/make_report_figures.py`, the same run that writes the report's PNGs. |
| `flash_v1.pdf` | The compiled paper: 8 pages, 32 numbered references. |
| `build.ps1` | Builds the PDF and checks it. |
| `latexmkrc` | The same build for `latexmk` and for Overleaf. |
| `make_submission.ps1` | Builds, then packs `flash_v1_submission.zip` (gitignored): `flash_v1.tex` and `figures/`. |

## Building

Because the references are embedded, no BibTeX run is needed: pdflatex twice
resolves every citation number.

- **Command line:** `powershell -ExecutionPolicy Bypass -File paper\build.ps1`.
  It fails if any citation or reference is undefined and prints the page and
  reference counts.
- **VS Code:** with the LaTeX Workshop extension, the repository's
  `.vscode/settings.json` rebuilds on every save (pdflatex twice).
- **latexmk** (needs Perl) or **Overleaf:** both read `latexmkrc`. On Overleaf,
  upload the contents of `flash_v1_submission.zip`.

To change a reference, edit `refs.bib`, temporarily replace the
`thebibliography` block with `\bibliographystyle{IEEEtran}` and
`\bibliography{refs}`, run pdflatex, bibtex, pdflatex, pdflatex, and paste the
new `flash_v1.bbl` back in.

Build artefacts (`*.aux`, `*.bbl`, `*.blg`, `*.log`, `*.out`, `*.synctex.gz`,
`*.fls`, `*.fdb_latexmk`) are gitignored. Last built with MiKTeX 25.12: no
undefined citations or references, no overfull boxes.
