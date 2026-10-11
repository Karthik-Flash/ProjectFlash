# paper/: FLASH V1 conference paper

IEEE conference format (`IEEEtran`, two-column), written from
[`../PROJECT_FLASH_REPORT.md`](../PROJECT_FLASH_REPORT.md). Every number in it
also appears in the report or in a repository file the report cites.

| File | What it is |
|---|---|
| `flash_v1.tex` | The paper. The system diagram (Fig. 1) is TikZ, inside the source. |
| `refs.bib` | 32 references, each checked against its DOI record, arXiv entry or issuing body's page on 2026-10-11. |
| `figures/` | Vector PDF plots (serif text, sized for a 3.5 in column or the 7.16 in page), written by `python tools/make_report_figures.py`, the same run that writes the report's PNGs. |
| `flash_v1.pdf` | The compiled paper: 8 pages including references. |

Build, from this folder:

```
pdflatex flash_v1
bibtex flash_v1
pdflatex flash_v1
pdflatex flash_v1
```

Built with MiKTeX 25.12 (pdfTeX, BibTeX, `IEEEtran.bst` 1.14): no undefined
references or citations, no overfull boxes. Citations show as `[?]` if
`bibtex` is skipped or `refs.bib` is not next to the `.tex`; on Overleaf,
upload `flash_v1.tex`, `refs.bib` and the `figures/` folder together.
