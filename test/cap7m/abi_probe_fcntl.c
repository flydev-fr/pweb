/*
 * C side of the paired fcntl probe (CAP-7M0, extended by CAP-7M1).
 *
 * Prints what <fcntl.h> and <limits.h> ACTUALLY define on the runner's SDK,
 * and what the kernel ACTUALLY answers for an open descriptor. The Pascal
 * side (test/cap7m/abi_probe_fcntl.pas) prints the same facts measured from
 * src/assets/pweb.assets.folder.pas - its declared constants and its
 * PRODUCTION path-resolution routine. check_abi.sh compares the two line by
 * line and permits ZERO delta: unlike the core webview probe pair, which has
 * two documented signedness lines, there is no legitimate difference here.
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
 * WHAT CAP-7M1 ADDED, AND WHY IT IS A ROUND TRIP RATHER THAN A CONSTANT.
 * macOS has no /proc, so the folder store's open-descriptor confinement
 * re-proof is fcntl(fd, F_GETPATH, buf) rather than
 * readlink("/proc/self/fd/N"). F_GETPATH and the PATH_MAX-sized buffer bound
 * are constants and are compared as such - but the call itself is VARIADIC in
 * C, and Apple's arm64 ABI passes variadic arguments on the stack where its
 * x86_64 ABI passes them in registers. A declaration that is right on one
 * architecture can therefore be wrong on the other, which no constant
 * comparison would ever reveal. So the last fact is the resolved path of a
 * real descriptor, taken on both sides, on each architecture separately.
 *
 * Deliberately NOT compiled with -std=c99 or any strict-ISO mode: that sets
 * __STRICT_ANSI__, which lowers __DARWIN_C_LEVEL and can hide O_NOFOLLOW
 * behind its _DARWIN_C_SOURCE guard. A missing macro is a hard #error below
 * rather than a silently absent line, because a probe that prints fewer
 * facts than its partner would otherwise look like a diff instead of a
 * broken measurement.
 *
 * Usage: abi_probe_fcntl <an existing readable file>
 */

#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef O_DIRECTORY
#error "O_DIRECTORY is not visible in this translation unit -- the probe would measure nothing"
#endif
#ifndef O_NOFOLLOW
#error "O_NOFOLLOW is not visible in this translation unit -- the probe would measure nothing"
#endif
#ifndef O_RDONLY
#error "O_RDONLY is not visible in this translation unit"
#endif
#ifndef F_GETPATH
#error "F_GETPATH is not visible in this translation unit -- the folder store cannot re-prove confinement without it"
#endif
#ifndef PATH_MAX
#error "PATH_MAX is not visible in this translation unit -- F_GETPATH needs a MAXPATHLEN-sized buffer"
#endif

int main(int argc, char **argv) {
  char buffer[PATH_MAX];
  int fd;

  if (argc != 2) {
    fprintf(stderr, "usage: abi_probe_fcntl <existing file>\n");
    return 2;
  }

  /* Printed as unsigned decimal, the same shape the Pascal side emits, so a
     plain line-by-line comparison is meaningful. EMISSION ORDER IS FIXED and
     must match abi_probe_fcntl.pas exactly. */
  printf("fcntl.O_RDONLY=%u\n", (unsigned)O_RDONLY);
  printf("fcntl.O_NOFOLLOW=%u\n", (unsigned)O_NOFOLLOW);
  printf("fcntl.O_DIRECTORY=%u\n", (unsigned)O_DIRECTORY);
  printf("fcntl.F_GETPATH=%u\n", (unsigned)F_GETPATH);
  printf("fcntl.PATH_BOUND=%u\n", (unsigned)PATH_MAX);

  memset(buffer, 0, sizeof(buffer));
  fd = open(argv[1], O_RDONLY);
  if (fd < 0) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 1;
  }
  if (fcntl(fd, F_GETPATH, buffer) != 0) {
    close(fd);
    fprintf(stderr, "fcntl(F_GETPATH) failed for %s\n", argv[1]);
    return 1;
  }
  close(fd);
  printf("fcntl.F_GETPATH_ROUNDTRIP=%s\n", buffer);
  return 0;
}
