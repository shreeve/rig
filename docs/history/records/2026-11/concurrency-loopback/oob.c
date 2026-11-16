#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
int main(int argc, char **argv) {
  int addflags = argc > 1 ? EV_OOBAND : 0;
  int l = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(0x7f000001);
  socklen_t len = sizeof a; bind(l, (void*)&a, len); listen(l, 1); getsockname(l, (void*)&a, &len);
  int c = socket(AF_INET, SOCK_STREAM, 0); connect(c, (void*)&a, len); int s = accept(l, 0, 0);
  fcntl(s, F_SETFL, O_NONBLOCK);
  int q = kqueue(); struct kevent ev[4];
  EV_SET(&ev[0], s, EVFILT_READ, EV_ADD | EV_CLEAR | addflags, argc > 2 ? NOTE_OOB : 0, 0, 0);
  printf("add rc %d\n", kevent(q, ev, 1, 0, 0, 0));
  struct timespec z = {0, 0}, t = {0, 50000000};
  write(c, "hello", 5); usleep(20000);
  int n = kevent(q, 0, 0, ev, 4, &t); for (int i = 0; i < n; i++) printf("1: filter %d flags 0x%x fflags 0x%x data %ld\n", ev[i].filter, ev[i].flags, ev[i].fflags, (long)ev[i].data);
  send(c, "X", 1, MSG_OOB); write(c, "world", 5); usleep(20000);
  n = kevent(q, 0, 0, ev, 4, &t); for (int i = 0; i < n; i++) printf("2: filter %d flags 0x%x fflags 0x%x data %ld\n", ev[i].filter, ev[i].flags, ev[i].fflags, (long)ev[i].data);
  char b[64]; ssize_t r = read(s, b, 64); printf("read %zd\n", r);
  n = kevent(q, 0, 0, ev, 4, &z); printf("after read: %d events\n", n);
  r = read(s, b, 64); printf("read %zd\n", r);
  return 0;
}
