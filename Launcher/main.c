// cl_audit agent launcher: the program launchd starts for the cl_audit agent (Sources/Agent.swift). It only hands
// over to the agent inside the same cl_audit.app. Its bytes don't change between releases, so macOS keeps
// accepting it after an update (an ad hoc signed program is known by its exact hash) and no new
// "background item added" notice appears; the agent it starts is the one the update brought.
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    char path[PATH_MAX], real[PATH_MAX], target[PATH_MAX];
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0 || realpath(path, real) == NULL) return 78;
    char *slash = strrchr(real, '/');          // <app>/Contents/Helpers/cl_audit-agent
    if (slash == NULL) return 78;
    *slash = '\0';
    snprintf(target, sizeof target, "%s/../Library/LoginItems/cl_audit Agent.app/Contents/MacOS/UsageDock", real);
    argv[0] = target;
    execv(target, argv);
    perror("cl_audit-agent");
    return 78;                                 // EX_CONFIG: launchd tries again later
}
