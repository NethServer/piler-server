/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * LD_PRELOAD shim: piler logs only through syslog(3), and a rootless container
 * has no /dev/log (uid 1000 can't create one in the runtime's /dev). This turns
 * those calls into stderr writes, so supervisord ships them to the container
 * log like nginx's and php-fpm's.
 *
 * The piler binaries are built fortified, so they call __syslog_chk, not
 * syslog. Both are overridden here.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

static char log_ident[64] = "piler";

static void emit(const char *fmt, va_list ap) {
   char expanded[2048];
   char msg[8192];
   int saved_errno = errno;

   /* glibc expands %m to strerror(errno); callers rely on it. */
   const char *pos = strstr(fmt, "%m");
   if (pos) {
      snprintf(expanded, sizeof(expanded), "%.*s%s%s",
               (int)(pos - fmt), fmt, strerror(saved_errno), pos + 2);
      fmt = expanded;
   }

   vsnprintf(msg, sizeof(msg), fmt, ap);
   fprintf(stderr, "%s[%d]: %s\n", log_ident, (int)getpid(), msg);

   errno = saved_errno;
}

void openlog(const char *ident, int option, int facility) {
   (void)option;
   (void)facility;

   if (ident) {
      snprintf(log_ident, sizeof(log_ident), "%s", ident);
   }
}

void closelog(void) {}

int setlogmask(int mask) {
   return mask;
}

void vsyslog(int priority, const char *fmt, va_list ap) {
   (void)priority;
   emit(fmt, ap);
}

void syslog(int priority, const char *fmt, ...) {
   va_list ap;

   (void)priority;
   va_start(ap, fmt);
   emit(fmt, ap);
   va_end(ap);
}

void __vsyslog_chk(int priority, int flag, const char *fmt, va_list ap) {
   (void)priority;
   (void)flag;
   emit(fmt, ap);
}

void __syslog_chk(int priority, int flag, const char *fmt, ...) {
   va_list ap;

   (void)priority;
   (void)flag;
   va_start(ap, fmt);
   emit(fmt, ap);
   va_end(ap);
}
