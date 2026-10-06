/*
 * FreeCamHelp -- draws the FreeCam control list over the game.
 *
 * Why this is native and not Lua: overlay_text is an OPTIONAL tail extension of
 * WmlApi that the loader does NOT expose to Lua. The Lua table has no drawing
 * call at all, so a script calling it raises, every frame,
 *
 *   attempt to call a nil value (field 'overlay_text')
 *
 * The Speedometer hit exactly this and is a DLL for the same reason. So the Lua
 * half of FreeCam (the camera itself) writes the control list to help.txt when
 * the free camera is switched on and empties it when it is switched off, and
 * this displays whatever that file says.
 *
 * The file, not a mirrored keypress, is the channel on purpose. KeyPressed() is
 * a pure read (mod_loader.cpp:597, no consume), so this could watch the same
 * key and stay in step -- but then two copies of the toggle would have to agree
 * forever, and if the Lua half were ever removed the help would sit on screen
 * for a camera that is not there. Reading the file cannot desync, and a missing
 * file simply draws nothing.
 *
 * Reading it every frame is one fopen of a ~300 byte local file; the text only
 * changes on a toggle, but polling is cheaper than tracking the write.
 */
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "wml.h"

static const WmlApi* api = NULL;
static const WmlMod* self = NULL;

/* The last thing we handed the overlay, so we only touch it when it changes.
 * overlay_text logs "Mod text shown/hidden" and wakes the overlay device on a
 * visibility edge, so calling it with the same string every frame is wasted
 * work and log noise. */
static char shown[512];
static int have_shown = 0;

static void draw(const char* text) {
  if (have_shown && strcmp(shown, text) == 0) return;
  snprintf(shown, sizeof(shown), "%s", text);
  have_shown = 1;
  api->overlay_text(text);
}

static void frame(void* user) {
  char path[512];
  char buf[sizeof(shown)];
  size_t n = 0;

  snprintf(path, sizeof(path), "%s/help.txt", self ? self->folder : ".");
  FILE* f = fopen(path, "r");
  if (f) {
    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
  }
  /* Trim the trailing newline the Lua half writes, and anything after a NUL. */
  while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) n--;
  buf[n] = '\0';
  /* A stray NUL inside the file would make overlay_text stop early anyway, but
   * dropping the tail here keeps what we compare against honest. */
  buf[strnlen(buf, sizeof(buf) - 1)] = '\0';

  draw(buf);
}

extern "C" WML_EXPORT int wml_mod_init(const WmlApi* loader, const WmlMod* mod) {
  if (!loader || loader->version != WML_API_VERSION || loader->size < sizeof(WmlApi))
    return 1;
  /* overlay_text is an OPTIONAL tail extension. Without it this mod cannot draw
   * anything, so refuse loudly instead of running silently forever. The camera
   * in main.lua keeps working either way. */
  if (!loader->overlay_text) return 3;
  api = loader;
  self = mod;
  api->on_frame(frame, NULL);
  api->log(self, "FreeCamHelp: ready, overlay_text confirmed present. "
                 "Displays help.txt from the FreeCam folder.");
  return 0;
}