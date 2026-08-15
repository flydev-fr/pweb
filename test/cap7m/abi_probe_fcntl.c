/*
 * C side of the paired fcntl-constant probe (CAP-7M0).
 *
 * Prints the values <fcntl.h> ACTUALLY defines on the runner's SDK. The
 * Pascal side (test/cap7m/abi_probe_fcntl.pas) prints what
 * src/assets/pweb.assets.folder.pas declares for Darwin. check_abi.sh
 * compares the two line by line and permits ZERO delta - unlike the core
 * webview probe pair, which has two documented signedness lines, there is no
 * legitimate difference here.
 *
 * WHY THIS PAIR EXISTS AT ALL. FPC 3.2.2's Darwin BaseUnix declares neither
 * O_DIRECTORY nor O_NOFOLLOW, so the hardened POSIX branch of the folder
 * store has to declare them itself. Both are load-bearing:
 *
 *   O_DIRECTORY  refuses a FILE passed as the asset root, at construction;
 *   O_NOFOLLOW   refuses a symlink swapped in between the walk and the open.
 *
 * A wrong O_DIRECTORY fails loudly - the store stops constructing. A wrong
 * O_NOFOLLOW does NOT: the open simply stops refusing symlinks, and the
 * confinement guarantee quietly disappears while every test still passes.
 * That asymmetry is the whole justification for measuring rather than
 * trusting a transcribed constant.
 *
 * Deliberately NOT compiled with -std=c99 or any strict-ISO mode: that sets
 * __STRICT_ANSI__, which lowers __DARWIN_C_LEVEL and can hide O_NOFOLLOW
 * behind its _DARWIN_C_SOURCE guard. A missing macro is a hard #error below
 * rather than a silently absent line, because a probe that prints fewer
 * facts than its partner would otherwise look like a diff instead of a
 * broken measurement.
 */

#include <fcntl.h>
#include <stdio.h>

#ifndef O_DIRECTORY
#error "O_DIRECTORY is not visible in this translation unit -- the probe would measure nothing"
#endif
#ifndef O_NOFOLLOW
#error "O_NOFOLLOW is not visible in this translation unit -- the probe would measure nothing"
#endif
#ifndef O_RDONLY
#error "O_RDONLY is not visible in this translation unit"
#endif

int main(void) {
  /* Printed as unsigned decimal, the same shape the Pascal side emits, so a
     plain line-by-line comparison is meaningful. */
  printf("fcntl.O_RDONLY=%u\n", (unsigned)O_RDONLY);
  printf("fcntl.O_NOFOLLOW=%u\n", (unsigned)O_NOFOLLOW);
  printf("fcntl.O_DIRECTORY=%u\n", (unsigned)O_DIRECTORY);
  return 0;
}
