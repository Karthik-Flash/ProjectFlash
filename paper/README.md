# paper/: FLASH V1 conference paper

IEEE conference format (`IEEEtran`, two-column), written from
[`../PROJECT_FLASH_REPORT.md`](../PROJECT_FLASH_REPORT.md). Every number in it
also appears in the report or in a repository file the report cites.

| File | What it is |
|---|---|
| `flash_v1.tex` | The paper. The system diagram (Fig. 1) is TikZ, inside the source. |
| `refs.bib` | 32 references, each checked against its DOI record, arXiv entry or issuing body's page. |
| `figures/` | Vector PDF plots (serif text, sized for a 3.5 in column or the 7.16 in page), written by `python tools/make_report_figures.py`, the same run that writes the report's PNGs. |
| `flash_v1.pdf` | The compiled paper: 8 pages, 32 numbered references. |
| `build.ps1` | Builds the PDF with its references and checks the result. |
| `latexmkrc` | The same build for `latexmk` and for Overleaf. |
| `make_submission.ps1` | Builds, then packs `flash_v1_submission.zip` (gitignored): `.tex`, `.bib`, the generated `.bbl` and `figures/`. |

## Building

The references need BibTeX between two pdflatex runs. **A single pdflatex run
prints every citation as `[?]` and no reference list**, which is what an editor
preview that only runs pdflatex shows. Build one of these ways:

- **Command line:** `powershell -ExecutionPolicy Bypass -File paper\build.ps1`.
  It runs pdflatex, bibtex, pdflatex, pdflatex and fails if any citation or
  reference is undefined or BibTeX warns. It prints the page and reference
  counts.
- **VS Code:** install the LaTeX Workshop extension. The repository's
  `.vscode/settings.json` makes its only recipe pdflatex, bibtex, pdflatex,
  pdflatex, run on every save.
- **latexmk** (needs Perl) or **Overleaf:** both read `latexmkrc`. On Overleaf,
  upload the contents of `flash_v1_submission.zip`; the `.bbl` in it prints the
  references even if BibTeX is not run.

Build artefacts (`*.aux`, `*.bbl`, `*.blg`, `*.log`, `*.out`, `*.synctex.gz`,
`*.fls`, `*.fdb_latexmk`) are gitignored. Last built with MiKTeX 25.12: no
undefined citations or references, no overfull boxes.
