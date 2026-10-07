# docs/archive

Superseded material, kept as evidence. Nothing here is current. Moved, never
deleted.

| File | Why it is here | Replaced by |
|---|---|---|
| `V1_synth_timing_v1_2_v1_1mem_superseded.rpt` | Timing report of the first "V1.2" synthesis (commit `78d9e58`). That run loaded the **v1_1** `weights.mem`, `bias.mem` and `layer_table.mem` through `top_v1.v`'s parameter defaults. | `docs/V1_synth_timing_v1_2.rpt` |
| `V1_synth_util_v1_2_v1_1mem_superseded.rpt` | Utilization report of the same run. | `docs/V1_synth_util_v1_2.rpt` |

Notes:

- A byte-identical copy of the superseded timing report lay untracked at the
  repository root (`timing_v1_2.rpt`). It was moved to the gitignored
  `verilog/stray/root_timing_v1_2.rpt`, not into this folder, to avoid a
  second copy in git.
- No older handoff (`HANDOFF_v1_impl.md`) exists in the repository, so none is
  archived. `docs/HANDOFF_v1_impl_v2.md` is the current one.
- The `.docx` copy of the project brief that was at the repository root was no
  longer on disk on 2026-10-07, so it could not be archived. The `.md` brief in
  `docs/` is the kept version.
