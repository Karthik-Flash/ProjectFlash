# paper/ — FLASH V1 conference paper

IEEE conference format (`IEEEtran`, two-column), written from
[`../PROJECT_FLASH_REPORT.md`](../PROJECT_FLASH_REPORT.md). Every number in it
also appears in the report or in a repository file the report cites.

| File | What it is |
|---|---|
| `flash_v1.tex` | The paper. The system diagram is TikZ, inside the source. |
| `refs.bib` | 30 references, each checked against its DOI record, arXiv entry or issuing body's page on 2026-10-11. |
| `figures/` | Plots as PDF, written by `python tools/make_report_figures.py` (the same run that writes the report's PNGs), plus the two board-output PNGs from the executed demo. |

Build, from this folder:

```
pdflatex flash_v1
bibtex flash_v1
pdflatex flash_v1
pdflatex flash_v1
```

It needs a TeX distribution with `IEEEtran`, `tikz`, `booktabs`, `cite` and
`hyperref` (TeX Live or MiKTeX). None was installed on the development PC, so
this source has been checked statically (braces, environments, labels,
citations, table columns, ASCII only) but **not yet compiled**. The target is
7–8 pages including references; confirm the page count on the first build.
