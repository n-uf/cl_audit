/* A stand-in `claude` for Checks/signin's environment branch: built ad hoc by Checks/signin.sh (not an Apple platform binary,
   so the kernel gives its environment, as it does for Claude Code's own program). It does nothing but wait to be ended. */
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
