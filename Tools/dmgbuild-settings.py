# The installer window: what Finder shows when the DMG opens. Read by dmgbuild
# (pinned in release.sh), which writes Finder's .DS_Store itself instead of
# scripting Finder through AppleScript — so it needs no logged-in Finder, no
# Automation permission, and comes out the same on a CI runner as on a Mac.
#
# release.sh passes, with -D:
#   app         the signed, stapled Pitwall.app
#   background  a TIFF holding the 1x and 2x renders of
#               Tools/RenderDMGBackground.swift
#   icon        the volume icon (the app's own AppIcon.icns)
#
# The icon positions are the centres RenderDMGBackground.swift draws its wells
# and name plates around. Change one, change both.

import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

icon = defines["icon"]
background = defines["background"]

# The background is 660x400 points; the window's content area matches it.
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 200),
    "Applications": (490, 200),
}
