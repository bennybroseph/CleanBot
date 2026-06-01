-- ============================================================
-- CleanBotEquipData.lua  —  Static equipment slot definitions.
-- Each entry: id (inventory slot ID), name, tex (empty-slot
-- fallback texture), side ("left"|"right"|"bottom"), order
-- (1-based position within that side, top-to-bottom / left-to-right).
-- ============================================================
local NS = CleanBotNS

NS.EQUIP_SLOTS = {
    -- ── Left column (top → bottom) ────────────────────────────
    { id=1,  name="Head",      side="left",   order=1, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Head"          },
    { id=2,  name="Neck",      side="left",   order=2, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Neck"          },
    { id=3,  name="Shoulder",  side="left",   order=3, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder"      },
    { id=15, name="Back",      side="left",   order=4, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"         },
    { id=5,  name="Chest",     side="left",   order=5, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"         },
    { id=4,  name="Shirt",     side="left",   order=6, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"         },
    { id=19, name="Tabard",    side="left",   order=7, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"         },
    { id=9,  name="Wrist",     side="left",   order=8, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists"        },
    -- ── Right column (top → bottom) ───────────────────────────
    { id=10, name="Hands",     side="right",  order=1, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands"         },
    { id=6,  name="Waist",     side="right",  order=2, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist"         },
    { id=7,  name="Legs",      side="right",  order=3, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs"          },
    { id=8,  name="Feet",      side="right",  order=4, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet"          },
    { id=11, name="Finger 1",  side="right",  order=5, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"        },
    { id=12, name="Finger 2",  side="right",  order=6, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"        },
    { id=13, name="Trinket 1", side="right",  order=7, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"       },
    { id=14, name="Trinket 2", side="right",  order=8, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"       },
    -- ── Bottom row (left → right) ─────────────────────────────
    { id=16, name="Main Hand", side="bottom", order=1, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand"      },
    { id=17, name="Off Hand",  side="bottom", order=2, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand" },
    { id=18, name="Ranged",    side="bottom", order=3, tex="Interface\\PaperDoll\\UI-PaperDoll-Slot-Ranged"        },
}
