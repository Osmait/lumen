/*
** io.open and io.tmpfile for extensions (Lumen), through the public Lua
** API: files are opened close-on-exec, so programs that lumen.exec starts
** do not inherit them, and counted per state (luart_file_opened, in
** src/luart/lua.zig), so an extension cannot use up the daemon's
** descriptors. The handles are ordinary Lua files (LUA_FILEHANDLE): every
** method works on them, and closing or collecting one gives its slot back.
*/

#include <fcntl.h>
#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* In src/luart/lua.zig: take a slot (0 when none is left) and give it back. */
int luart_file_opened (lua_State *L);
void luart_file_closed (lua_State *L);

/* What liolib's 'l_checkmode' accepts: [rwa]%+?b* */
static int valid_mode (const char *mode) {
  if (*mode == '\0' || strchr("rwa", *mode) == NULL) return 0;
  mode++;
  if (*mode == '+') mode++;
  return strspn(mode, "b") == strlen(mode);
}

/* Called by liolib (close, io.close, the finalizer) with the file at 1. */
static int counted_close (lua_State *L) {
  luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
  int result = fclose(p->f);
  luart_file_closed(L);
  return luaL_fileresult(L, (result == 0), NULL);
}

/* A closed file (closef NULL), made before the slot is taken: a memory
** error raised here then leaves nothing counted. */
static luaL_Stream *new_stream (lua_State *L) {
  luaL_Stream *p = (luaL_Stream *)lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
  p->f = NULL;
  p->closef = NULL;
  luaL_setmetatable(L, LUA_FILEHANDLE);
  return p;
}

static int too_many (lua_State *L, const char *what) {
  luaL_pushfail(L);
  lua_pushfstring(L, "%s: too many files open by this extension", what);
  return 2;
}

static int luart_io_open (lua_State *L) {
  const char *filename = luaL_checkstring(L, 1);
  const char *mode = luaL_optstring(L, 2, "r");
  char mode_cloexec[8];
  luaL_argcheck(L, valid_mode(mode) && strlen(mode) + 2 <= sizeof(mode_cloexec),
                2, "invalid mode");
  luaL_Stream *p = new_stream(L);
  if (!luart_file_opened(L)) return too_many(L, filename);
  /* 'e': O_CLOEXEC (glibc). */
  snprintf(mode_cloexec, sizeof(mode_cloexec), "%se", mode);
  p->f = fopen(filename, mode_cloexec);
  if (p->f == NULL) {
    luart_file_closed(L);
    return luaL_fileresult(L, 0, filename);
  }
  p->closef = &counted_close;
  return 1;
}

static int luart_io_tmpfile (lua_State *L) {
  luaL_Stream *p = new_stream(L);
  if (!luart_file_opened(L)) return too_many(L, "tmpfile");
  p->f = tmpfile();
  if (p->f == NULL) {
    luart_file_closed(L);
    return luaL_fileresult(L, 0, NULL);
  }
  fcntl(fileno(p->f), F_SETFD, FD_CLOEXEC);
  p->closef = &counted_close;
  return 1;
}

/* Replaces io.open and io.tmpfile with these. */
int luart_open_files (lua_State *L) {
  static const luaL_Reg files[] = {
    {"open", luart_io_open},
    {"tmpfile", luart_io_tmpfile},
    {NULL, NULL}
  };
  lua_getglobal(L, "io");
  luaL_setfuncs(L, files, 0);
  lua_pop(L, 1);
  return 0;
}
