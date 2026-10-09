/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Spawn rongta-ble so TCC treats it as its own responsible process. */
#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

static void copy_fd(int fd, char *dst, size_t dst_len) {
    if (dst_len == 0) {
        return;
    }
    size_t used = 0;
    while (used + 1 < dst_len) {
        ssize_t n = read(fd, dst + used, dst_len - 1 - used);
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        used += (size_t)n;
    }
    dst[used] = '\0';
}

int rongta_spawn_disclaimed_scan(const char *path, int all, char *out, size_t out_len, char *err, size_t err_len) {
    if (out_len > 0) {
        out[0] = '\0';
    }
    if (err_len > 0) {
        err[0] = '\0';
    }
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
    if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
        return errno ? errno : 1;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    pid_t pid = 0;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) {
        goto done;
    }
    rc = posix_spawnattr_init(&attr);
    if (rc != 0) {
        posix_spawn_file_actions_destroy(&actions);
        goto done;
    }
    rc = responsibility_spawnattrs_setdisclaim(&attr, 1);
    if (rc != 0) {
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        goto done;
    }
    posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, out_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, err_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, out_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, err_pipe[1]);
    char *argv[] = {(char *)path, all ? "--scan-all" : "--scan", NULL};
    rc = posix_spawn(&pid, path, &actions, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    close(out_pipe[1]);
    close(err_pipe[1]);
    out_pipe[1] = -1;
    err_pipe[1] = -1;
    if (rc != 0) {
        goto done;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        rc = errno ? errno : 1;
        goto done;
    }
    copy_fd(out_pipe[0], out, out_len);
    copy_fd(err_pipe[0], err, err_len);
    if (WIFEXITED(status)) {
        rc = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        rc = 128 + WTERMSIG(status);
    } else {
        rc = 1;
    }
done:
    if (out_pipe[0] >= 0) {
        close(out_pipe[0]);
    }
    if (out_pipe[1] >= 0) {
        close(out_pipe[1]);
    }
    if (err_pipe[0] >= 0) {
        close(err_pipe[0]);
    }
    if (err_pipe[1] >= 0) {
        close(err_pipe[1]);
    }
    return rc;
}
