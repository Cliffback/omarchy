#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"

log="$tmp_dir/log"
: >"$log"

# The installer and remover shell out to package, MIME, icon, and desktop
# helpers; the sandbox has none of them, and the real ones would touch the
# developer's own machine.
for command in omarchy-pkg-aur-add omarchy-pkg-drop update-mime-database update-desktop-database gtk-update-icon-cache; do
  cat >"$tmp_dir/bin/$command" <<'SCRIPT'
#!/bin/bash
printf '%s:%s\n' "${0##*/}" "$*" >>"$TEST_LOG"
SCRIPT
  chmod +x "$tmp_dir/bin/$command"
done

cat >"$tmp_dir/bin/xdg-mime" <<'SCRIPT'
#!/bin/bash
printf 'xdg-mime:%s\n' "$*" >>"$TEST_LOG"
SCRIPT
chmod +x "$tmp_dir/bin/xdg-mime"

# omarchy-cmd-present is a real Omarchy command, but the test's PATH does not
# include bin/; stub it to answer for omarchy-launch-affinity only.
cat >"$tmp_dir/bin/omarchy-cmd-present" <<'SCRIPT'
#!/bin/bash
[[ $1 == "omarchy-launch-affinity" ]]
SCRIPT
chmod +x "$tmp_dir/bin/omarchy-cmd-present"

cat >"$tmp_dir/bin/omarchy-launch-affinity" <<'SCRIPT'
#!/bin/bash
printf 'launch-affinity:%s\n' "$*" >>"$TEST_LOG"
SCRIPT
chmod +x "$tmp_dir/bin/omarchy-launch-affinity"

cat >"$tmp_dir/bin/pgrep" <<'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
chmod +x "$tmp_dir/bin/pgrep"

export TEST_LOG="$log"
export PATH="$tmp_dir/bin:$PATH"
export OMARCHY_PATH="$ROOT"

install_script="$ROOT/bin/omarchy-install-creative-affinity"
remove_script="$ROOT/bin/omarchy-remove-creative-affinity"

# The installer's metadata drives both the CLI router and the menu's sudo
# handoff; a missing summary fails test/cli, and a missing sudo flag would run
# the AUR install without a password prompt.
for script in "$install_script" "$remove_script"; do
  grep -q '^# omarchy:summary=' "$script" ||
    fail "${script##*/} declares a summary"
  grep -qx '# omarchy:requires-sudo=true' "$script" ||
    fail "${script##*/} declares it needs sudo"
done
pass "Affinity install and remove commands carry their metadata"

xml="$ROOT/default/applications/affinity-filetypes.xml"
xml_types=$(grep -c '<mime-type type=' "$xml" || true)
[[ $xml_types == 16 ]] ||
  fail "Affinity MIME definitions declare all 16 types" "$xml_types"
pass "Affinity MIME definitions declare all 16 types"

# The opener must still open a file on a machine where omarchy-launch-affinity
# is absent (a packaged install predating this command, or a partial setup):
# falling through to the AppImage is what keeps the association working.
opener="$ROOT/default/applications/affinity-open"
grep -q 'omarchy-cmd-present omarchy-launch-affinity' "$opener" ||
  fail "affinity-open checks for the Omarchy launcher before using it"
grep -q 'exec /usr/bin/affinity' "$opener" ||
  fail "affinity-open falls back to the AppImage without the Omarchy launcher"
pass "affinity-open falls back to the AppImage when the Omarchy launcher is missing"

fresh_home() {
  rm -rf "$tmp_dir/home"
  mkdir -p "$tmp_dir/home"
  export HOME="$tmp_dir/home"
}

# A file manager hands the opener a path; Wine needs it as a Z:\ path because
# the AppImage's prefix maps z: to /.
touch "$tmp_dir/artwork.afphoto"
: >"$log"
"$opener" "$tmp_dir/artwork.afphoto"
expected_launch="launch-affinity:Z:${tmp_dir//\//\\}\\artwork.afphoto"
grep -Fxq "$expected_launch" "$log" ||
  fail "affinity-open converts a Unix path to a Wine Z: path" "$(cat "$log")"
pass "affinity-open converts a Unix path to a Wine Z: path"

fresh_home
"$install_script" >/dev/null

[[ -x $HOME/.local/bin/affinity-open ]] ||
  fail "Affinity install lands the opener on PATH"
[[ -f $HOME/.local/share/mime/packages/affinity-filetypes.xml ]] ||
  fail "Affinity install lands the MIME definitions"
[[ -f $HOME/.local/share/applications/affinity.desktop ]] ||
  fail "Affinity install lands the desktop entry"
[[ -f $HOME/.local/share/icons/hicolor/512x512/apps/affinity.png ]] ||
  fail "Affinity install lands the icon the desktop entry names"
pass "Affinity install lands the opener, MIME definitions, desktop entry, and icon"

desktop="$HOME/.local/share/applications/affinity.desktop"
grep -qx 'Exec=affinity-open %F' "$desktop" ||
  fail "Affinity desktop entry opens files through the opener" "$(cat "$desktop")"
grep -qx 'Icon=affinity' "$desktop" ||
  fail "Affinity desktop entry names the packaged icon" "$(cat "$desktop")"
grep -q '^MimeType=application/af;.*application/afstyles;$' "$desktop" ||
  fail "Affinity desktop entry advertises every MIME type" "$(cat "$desktop")"
pass "Affinity desktop entry opens files and advertises their types"

grep -qx 'omarchy-pkg-aur-add:affinity-appimage-bin' "$log" ||
  fail "Affinity install adds the AUR package"
grep -q '^update-mime-database:' "$log" ||
  fail "Affinity install refreshes the MIME database"
(( $(grep -c '^xdg-mime:default affinity.desktop application/' "$log") == 16 )) ||
  fail "Affinity install sets the default handler for all 16 types" "$(cat "$log")"
pass "Affinity install registers the package and every default handler"

# The remover has to undo the defaults the installer wrote, or the types keep
# pointing at a desktop entry that no longer exists.
mkdir -p "$HOME/.config"
{
  printf '[Default Applications]\n'
  printf 'application/af=affinity.desktop\n'
  printf 'application/afphoto=affinity.desktop\n'
  printf 'text/plain=nvim.desktop\n'
} >"$HOME/.config/mimeapps.list"

: >"$log"
"$remove_script" >/dev/null

for gone in .local/bin/affinity-open \
  .local/share/mime/packages/affinity-filetypes.xml \
  .local/share/applications/affinity.desktop \
  .local/share/icons/hicolor/512x512/apps/affinity.png; do
  [[ ! -e $HOME/$gone ]] || fail "Affinity removal deletes the files it installed" "$gone"
done
pass "Affinity removal deletes the files it installed"

grep -qx 'omarchy-pkg-drop:affinity-appimage-bin' "$log" ||
  fail "Affinity removal drops the AUR package"
! grep -q '^application/af=affinity.desktop$' "$HOME/.config/mimeapps.list" ||
  fail "Affinity removal clears the default handlers it set"
grep -qx 'text/plain=nvim.desktop' "$HOME/.config/mimeapps.list" ||
  fail "Affinity removal leaves unrelated defaults alone"
pass "Affinity removal drops the package and clears only its own defaults"
