#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$(mktemp -d /private/tmp/LaunchIcon-BackgroundValidation.XXXXXX)"
trap 'rm -rf "$DERIVED_DATA"' EXIT

"$ROOT_DIR/script/check_no_network_apis.sh"
python3 "$ROOT_DIR/script/test_folder_landing_timing.py"
python3 "$ROOT_DIR/script/test_launcher_presence_from_presentation.py"
python3 "$ROOT_DIR/script/test_launcher_presence_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_search_grid_crossfade_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_dissolved_grid_fade_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_folder_backdrop_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_folder_chrome_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_folder_created_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_merge_reduced_fade_snap.py"
python3 "$ROOT_DIR/script/test_launch_press_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_page_button_hover_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_reorder_slide_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_drag_lift_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_drop_landing_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_dissolve_scatter_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_folder_preview_glyph_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_folder_incoming_preview_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_folder_merge_preview_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_footer_chrome_visibility_reduced_motion_snap.py"
python3 "$ROOT_DIR/script/test_settings_message_fade.py"
python3 "$ROOT_DIR/script/test_toast_fade_parity.py"
python3 "$ROOT_DIR/script/test_settings_presence_fade.py"
python3 "$ROOT_DIR/script/test_search_adjacent_chrome_restore.py"
python3 "$ROOT_DIR/script/test_settings_launcher_restore.py"
python3 "$ROOT_DIR/script/test_escape_clear_search_focus.py"
python3 "$ROOT_DIR/script/test_folder_flight_cleanup.py"
python3 "$ROOT_DIR/script/test_folder_title_readiness.py"
python3 "$ROOT_DIR/script/test_page_host_geometry.py"
python3 "$ROOT_DIR/script/test_paging_input.py"
python3 "$ROOT_DIR/script/test_uninstall_process_wait.py"
python3 "$ROOT_DIR/script/test_uninstall_trash_off_main.py"
python3 "$ROOT_DIR/script/test_uninstall_related_default_off.py"
python3 "$ROOT_DIR/script/test_hide_application_feedback.py"
python3 "$ROOT_DIR/script/test_multi_select_selection.py"
python3 "$ROOT_DIR/script/test_uninstall_coordinator_extract.py"
python3 "$ROOT_DIR/script/test_settings_leftovers_ux.py"
python3 "$ROOT_DIR/script/test_settings_layout_sections.py"
python3 "$ROOT_DIR/script/test_grid_rearrange.py"
python3 "$ROOT_DIR/script/test_layout_backup_restore.py"
python3 "$ROOT_DIR/script/test_hot_corner.py"
python3 "$ROOT_DIR/script/test_status_item_toggle_title.py"
python3 "$ROOT_DIR/script/test_search_folder_member_chrome.py"
python3 "$ROOT_DIR/script/test_search_empty_chrome.py"
python3 "$ROOT_DIR/script/test_search_rank_toplevel.py"
python3 "$ROOT_DIR/script/test_search_keyboard_highlight.py"
python3 "$ROOT_DIR/script/test_incomplete_scan_readonly_ax.py"
python3 "$ROOT_DIR/script/test_folder_empty_focus.py"
python3 "$ROOT_DIR/script/test_folder_close_focus_restore.py"
python3 "$ROOT_DIR/script/test_folder_member_focus_ring.py"
TMPDIR=/private/tmp "$ROOT_DIR/script/test_core.sh"

for scheme in LaunchIconDirect LaunchIconStoreSpike; do
  xcodebuild -quiet \
    -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA/$scheme" \
    CODE_SIGNING_ALLOWED=NO \
    analyze
done

# Compile XCTest code without starting the app, UI Runner, or an automation session.
xcodebuild -quiet \
  -project "$ROOT_DIR/LaunchIcon.xcodeproj" \
  -scheme LaunchIconUITests \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA/LaunchIconUITests" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

echo "Background validation passed; no app or UI Runner was launched."
