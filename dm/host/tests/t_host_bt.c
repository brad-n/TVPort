// The stall dump (DM_STALL_DUMP, svc_thread_dump) must name the host function a guest thread is stuck in. A guest thread blocked inside a host call (here a pthread condition wait,
// standing in for a Metal / OS wait) has its pc in system code: the dump has to print a "host backtrace:" line for it, symbolized, with the frames of the engine code that called the wait.
// A thread that waits in an SVC (wkind != 0) with its pc in host code gets the line too. Expected: one line per such thread, naming dm_test_blocked_in_host and a system wait function.
#include "../hle_thread.c"
#include <assert.h>
#include <unistd.h>
#include <fcntl.h>

static pthread_mutex_t bm = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t bc = PTHREAD_COND_INITIALIZER;
static _Atomic int in_wait, release;
__attribute__((noinline)) void dm_test_blocked_in_host(void) {
    pthread_mutex_lock(&bm); atomic_store(&in_wait, 1);
    while (!atomic_load(&release)) pthread_cond_wait(&bc, &bm);
    pthread_mutex_unlock(&bm);
    __asm__ volatile("");
}
static thr_t blocked;
static void *blocked_main(void *arg) {
    thr_t *t = arg; pthread_setspecific(g_keythr, t);
    t->pt = pthread_self(); t->mport = pthread_mach_thread_np(t->pt);
    dm_test_blocked_in_host();
    return NULL;
}
int main(void) {
    memset(&blocked, 0, sizeof blocked);
    pthread_cond_init(&blocked.cv, NULL); pthread_cond_init(&blocked.pcv, NULL);
    blocked.started = 1; blocked.prio = 44; blocked.core = 0; blocked.mask = 1;
    pthread_mutex_lock(&G); blocked.handle = h_new(O_THREAD, &blocked); blocked.all = g_all; g_all = &blocked; pthread_mutex_unlock(&G);
    pthread_t th; assert(!pthread_create(&th, NULL, blocked_main, &blocked));
    while (!atomic_load(&in_wait)) usleep(1000);
    usleep(50000);   // inside pthread_cond_wait by now
    char path[] = "/tmp/t_host_bt.XXXXXX"; int fd = mkstemp(path); assert(fd >= 0);
    fflush(stderr); int save = dup(2); dup2(fd, 2);
    svc_thread_dump();
    fflush(stderr); dup2(save, 2);
    atomic_store(&release, 1); pthread_mutex_lock(&bm); pthread_cond_broadcast(&bc); pthread_mutex_unlock(&bm); pthread_join(th, NULL);
    FILE *f = fopen(path, "r"); char ln[4096], want[64], hit[4096] = ""; snprintf(want, sizeof want, "[dm]   %#x host backtrace:", blocked.handle);
    while (fgets(ln, sizeof ln, f)) if (strstr(ln, want)) strcpy(hit, ln);
    fclose(f); unlink(path);
    printf("%s", hit[0] ? hit : "(no host backtrace line)\n");
    int fails = 0;
    #define CHECK(c, m) do { int ok_ = !!(c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", m); fails += !ok_; } while (0)
    CHECK(hit[0], "host backtrace line printed for the blocked guest thread");
    CHECK(strstr(hit, "dm_test_blocked_in_host"), "names the engine function that made the host call");
    CHECK(strstr(hit, "cond_wait") || strstr(hit, "psynch") || strstr(hit, "pthread"), "names the system wait function");
    printf("t_host_bt: %d failed\n", fails); return fails != 0;
}
