// ui.zig — thin re-export shim.
// All implementation lives in src/ui/*.zig sub-modules.
//
// IMPORTANT: The canonical mutable `ui_state` global lives in ui/state.zig.
// Callers that need to mutate it must import ui/state.zig directly, because
// Zig cannot alias a mutable var across module boundaries.
// main.zig does: const ui_state_mod = @import("ui/state.zig");

const root_mod = @import("ui/root.zig");
const state_mod = @import("ui/state.zig");
const clicks_mod = @import("ui/clicks.zig");

// ── Types ──────────────────────────────────────────────────────────────
pub const Tab = state_mod.Tab;
pub const ActiveField = state_mod.ActiveField;
pub const UiState = state_mod.UiState;

// ── Layout ────────────────────────────────────────────────────────────
pub const layoutRoot = root_mod.layoutRoot;

// ── Click handling ────────────────────────────────────────────────────
pub const handleClick = clicks_mod.handleClick;

// ── Input handlers ────────────────────────────────────────────────────
pub const handleTextInput = state_mod.handleTextInput;
pub const handleBackspace = state_mod.handleBackspace;
pub const handleDelete = state_mod.handleDelete;
pub const handleLeftArrow = state_mod.handleLeftArrow;
pub const handleRightArrow = state_mod.handleRightArrow;
pub const handleReturn = state_mod.handleReturn;
pub const handleTab = state_mod.handleTab;
