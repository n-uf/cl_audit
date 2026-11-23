# Sourced by build.sh and the check scripts (needs $repo): the shared modules cl_audit compiles from source, ProfileCore <- Runs
# <- ClaudeAuth (with ClaudeSignIn and Auth/Keychain.swift), and AddressPrivacy (how an account address is hidden on screen:
# Privacy/, standalone) with MenuRows over it and ProfileCore (MenuRows/: a menu's account row), from the tagged release of n-uf/cl_kit vendored in Vendor/cl_kit-<tag>/ (Vendor/CL_KIT names it;
# scripts/vendor.sh copies a tag). The build recipe is cl_kit's own (its scripts/modules.sh); this file only points it at the
# vendored copy.
#
#   build_modules OUT keychain|no-keychain [swiftc flags...]   builds the three into OUT
#   build_privacy OUT [swiftc flags...]                        builds AddressPrivacy into OUT (the app links it)
#   modules_link OUT                                           prints the flags that link the three
#   privacy_link OUT                                           prints the flags that link AddressPrivacy (with its frameworks)
#   build_menurows OUT [swiftc flags...]                       builds MenuRows (MenuRows/: the menu bar menu's account rows)
#                                                              into OUT, after build_modules and build_privacy into it
#   menurows_link OUT                                          prints the flags that link MenuRows: put them before
#                                                              privacy_link's and ProfileCore's
#   module_sources Core|Run|Auth|Privacy|MenuRows [left-out names...]   a module's vendored sources, one path per line
#   modules_kit, modules_tag                                   the vendored copy's folder and its tag

[ -f "$repo/Vendor/CL_KIT" ] || { echo "no Vendor/CL_KIT: run scripts/vendor.sh <tag>" >&2; return 1; }
read -r modules_tag _ < "$repo/Vendor/CL_KIT"
modules_kit="$repo/Vendor/cl_kit-$modules_tag"
[ -f "$modules_kit/scripts/modules.sh" ] || { echo "no $modules_kit: run scripts/vendor.sh $modules_tag" >&2; return 1; }
kit_root="$modules_kit"
. "$modules_kit/scripts/modules.sh"

build_modules() { kit_build "$@"; }
build_privacy() { kit_build_privacy "$@"; }
modules_link() { kit_link "$1"; }
privacy_link() { kit_privacy_link "$1"; }
build_menurows() { kit_build_menurows "$@"; }
menurows_link() { kit_menurows_link "$1"; }
module_sources() { kit_sources "$@"; }
