// BandSync's background renders on a Mac (GPL-3.0-or-later). Loaded only into the private renderer copy of REAPER that
// lib/bgrender.lua makes, never the person's REAPER: every window of that process stays fully transparent and ignores
// the mouse. Windows still open, so REAPER's own render logic runs as normal; nothing is ever seen. No macOS setting
// does this: LSBackgroundOnly stops the focus change but REAPER still draws, and it pulls off-screen windows back.
// Build: tools/mac/build.sh
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <stdlib.h>

typedef id (*init_fn)(id, SEL, NSRect, NSUInteger, NSUInteger, BOOL);
typedef void (*alpha_fn)(id, SEL, CGFloat);
static init_fn real_init;
static alpha_fn real_alpha;

static id my_init(id self, SEL s, NSRect r, NSUInteger style, NSUInteger backing, BOOL defer) {
  id w = real_init(self, s, r, style, backing, defer);
  if (w) {
    real_alpha(w, @selector(setAlphaValue:), 0.0);
    [(NSWindow *)w setIgnoresMouseEvents:YES];
    [(NSWindow *)w setHasShadow:NO];
  }
  return w;
}
// (the render box fades itself in and out: still 0)
static void my_alpha(id self, SEL s, CGFloat a) { real_alpha(self, s, 0.0); }

__attribute__((constructor)) static void bandsync_hide_load(void) {
  unsetenv("DYLD_INSERT_LIBRARIES"); // (this process only, not whatever it starts: plug-in bridges, its scanner)
  Class c = [NSWindow class];
  Method i = class_getInstanceMethod(c, @selector(initWithContentRect:styleMask:backing:defer:));
  Method a = class_getInstanceMethod(c, @selector(setAlphaValue:));
  real_init = (init_fn)method_setImplementation(i, (IMP)my_init);
  real_alpha = (alpha_fn)method_setImplementation(a, (IMP)my_alpha);
}
