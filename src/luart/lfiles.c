/*
** io.open and io.tmpfile for extensions (Lumen), through the public Lua
** API: files are opened close-on-exec, so programs that lumen.exec starts
** do not inherit them, and counted per state (luart_file_opened, in
** src/luart/lua.zig), so an extension cannot use up the daemon's
** descriptors. The handles are ordinary Lua files (LUA_FILEHANDLE): every
** method works on them, and closing or collecting one gives its slot back.
*/

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* In src/luart/lua.zig: take a slot (0 when none is left), give it back,
** and verify the opened descriptor is not a FIFO, device or procfs mem. */
int luart_file_opened (lua_State *L);
void luart_file_closed (lua_State *L);
int luart_fd_allowed (int fd);

/* What liolib's 'l_checkmode' accepts: [rwa]%+?b* */
static int valid_mode (const char *mode) {
  if (*mode == '\0' || strchr("rwa", *mode) == NULL) return 0;
  mode++;
  if (*mode == '+') mode++;
  return strspn(mode, "b") == strlen(mode);
}

static int open_flags (const char *mode) {
  int rw = (mode[1] == '+');
  int flags = O_CLOEXEC | O_NONBLOCK | O_NOCTTY;
  switch (mode[0]) {
    case 'r':
      flags |= rw ? O_RDWR : O_RDONLY;
      break;
    case 'w':
      flags |= (rw ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
      break;
    case 'a':
      flags |= (rw ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
      break;
  }
  return flags;
}

static int refuse_file (lua_State *L, const char *filename) {
  luaL_pushfail(L);
  lua_pushfstring(
      L,
      "%s: not a regular file (Lumen does not open FIFOs, sockets, devices or a process's memory)",
      filename);
  return 2;
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
  luaL_argcheck(L, valid_mode(mode), 2, "invalid mode");
  luaL_Stream *p = new_stream(L);
  if (!luart_file_opened(L)) return too_many(L, filename);
  int fd = open(filename, open_flags(mode), 0666);
  if (fd < 0) {
    int saved_errno = errno;
    luart_file_closed(L);
    if (saved_errno == ENXIO) return refuse_file(L, filename);
    errno = saved_errno;
    return luaL_fileresult(L, 0, filename);
  }
  if (!luart_fd_allowed(fd)) {
    close(fd);
    luart_file_closed(L);
    return refuse_file(L, filename);
  }
  int fl = fcntl(fd, F_GETFL);
  if (fl != -1) fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);
  p->f = fdopen(fd, mode);
  if (p->f == NULL) {
    int saved_errno = errno;
    close(fd);
    luart_file_closed(L);
    errno = saved_errno;
    return luaL_fileresult(L, 0, filename);
  }
  p->closef = &counted_close;
  return 1;
}

/* Opens an unlinked temporary descriptor atomically with O_CLOEXEC. Prefers
** O_TMPFILE so no directory entry ever exists; falls back to mkostemp on
** file systems without O_TMPFILE support. */
static int open_tmp_fd (void) {
  const char *dir = getenv("TMPDIR");
  if (dir == NULL || *dir == '\0') dir = "/tmp";
#ifdef O_TMPFILE
  int fd = open(dir, O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
  if (fd >= 0) return fd;
#endif
  char path[4096];
  int len = snprintf(path, sizeof(path), "%s/lumen-tmp-XXXXXX", dir);
  if (len < 0 || (size_t)len >= sizeof(path)) {
    snprintf(path, sizeof(path), "/tmp/lumen-tmp-XXXXXX");
  }
  int mkfd = mkostemp(path, O_CLOEXEC);
  if (mkfd >= 0) unlink(path);
  return mkfd;
}

static int luart_io_tmpfile (lua_State *L) {
  luaL_Stream *p = new_stream(L);
  if (!luart_file_opened(L)) return too_many(L, "tmpfile");
  int fd = open_tmp_fd();
  if (fd < 0) {
    int saved_errno = errno;
    luart_file_closed(L);
    errno = saved_errno;
    return luaL_fileresult(L, 0, NULL);
  }
  p->f = fdopen(fd, "w+b");
  if (p->f == NULL) {
    int saved_errno = errno;
    close(fd);
    luart_file_closed(L);
    errno = saved_errno;
    return luaL_fileresult(L, 0, NULL);
  }
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
