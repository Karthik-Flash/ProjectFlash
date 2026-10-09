# docs/archive

Superseded material, kept as evidence. Nothing here describes the current
state of the project; paths and statuses inside these files are as they were
when written. Files are moved here, never deleted.

| File | Why it is here | Replaced by |
|---|---|---|
| `V1_synth_timing_v1_2_v1_1mem_superseded.rpt` | Timing report of the first "V1.2" synthesis (commit `78d9e58`). That run loaded the **v1_1** `weights.mem`, `bias.mem` and `layer_table.mem` through `top_v1.v`'s parameter defaults. | `docs/reports/synth/V1_synth_timing_v1_2.rpt` |
| `V1_synth_util_v1_2_v1_1mem_superseded.rpt` | Utilization report of the same run. | `docs/reports/synth/V1_synth_util_v1_2.rpt` |
| `HANDOFF_v1_impl_v2.md` | The bring-up handoff of 2026-10-07 (wrapper, block design, board plan). Every task in it is done; parts of its plan were overtaken by events (single start pulse, 66.67 MHz, HP0 64-bit). Archived 2026-10-09. | `docs/BRINGUP_STATUS.md`, `docs/V1_board_results_v1_2.md`, `PROJECT_FLASH_REPORT.md` |
| `Project_FLASH_brief_longform_2026-09-29.md` | The long-form brief and research roadmap of 2026-09-29 (originally `Project FLASH - Project Brief, Technical Framework & Research Roadmap.md`). Its status statements predate the board run (16/16 in simulation, 75 MHz, power and board "pending"). It is still the source for the hackathon history (H-V0…H-V4), the external statistics it cites, the related-work table and the claim-corrections table. Archived 2026-10-09. | `docs/Project_FLASH_brief.pdf` (condensed brief) and `PROJECT_FLASH_REPORT.md` |

Notes:

- A byte-identical copy of the superseded timing report lay untracked at the
  repository root (`timing_v1_2.rpt`). It was moved to the gitignored
  `verilog/stray/root_timing_v1_2.rpt`, not into this folder, to avoid a
  second copy in git.
- `v1/board/flash.bit` and `flash.hwh` were deleted on 2026-10-09, not
  archived: they were byte-identical to `v1/board/flash_hp32.bit` and
  `flash_hp32.hwh` (SHA-256 `396a219b10690f26` / `5f8c18af7bdf3650`), which
  remain.
- The `.docx` copy of the project brief that was at the repository root was
  no longer on disk on 2026-10-07, so it could not be archived.
