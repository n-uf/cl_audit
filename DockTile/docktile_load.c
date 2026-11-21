// The Dock tile plug-in's load-time function: runs when the Dock loads a copy, before macOS asks the copy for its principal
// class, and hands the copy's own executable path to DockTile/Plugin.swift (cl_audit_docktile_loaded), which registers
// the class that copy's Info.plist names. Linked into the plug-in only, never into UsageDock.
#include <dlfcn.h>

extern void cl_audit_docktile_loaded(const char *image);

__attribute__((constructor)) static void cl_audit_docktile_init(void) {
    Dl_info info;
    if (dladdr((const void *)&cl_audit_docktile_init, &info) && info.dli_fname) cl_audit_docktile_loaded(info.dli_fname);
}
