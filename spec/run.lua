-- ============================================================
-- spec/run.lua  —  Test entry point. Run from the addon root:
--   luajit spec/run.lua
-- Loads the WoW mock + harness, then each spec, then prints a summary and exits
-- non-zero on any failure (for CI).
-- ============================================================

dofile("spec/wow_mock.lua")
dofile("spec/framework.lua")

-- Spec files (add new ones here).
dofile("spec/events_spec.lua")
dofile("spec/inventory_spec.lua")
dofile("spec/bridge_spec.lua")
dofile("spec/strategies_spec.lua")
dofile("spec/overhear_spec.lua")
dofile("spec/overhear_appliers_spec.lua")
dofile("spec/layout_spec.lua")

_RUN_FINISH()
