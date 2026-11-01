// BandSync's background renders on a Mac (GPL-3.0-or-later): bandsync-launch <library> <program> [args...] starts the
// program with the library loaded into it. It exists because a variable set for it in a script doesn't arrive: macOS
// removes DYLD_ variables whenever a protected program (sh, nohup, env) starts anything. Build: tools/mac/build.sh
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <library> <program> [args...]\n", argv[0]);
    return 2;
  }
  setenv("DYLD_INSERT_LIBRARIES", argv[1], 1);
  execv(argv[2], argv + 2);
  perror(argv[2]);
  return 127;
}
