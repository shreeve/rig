| Utility | Rust lines | Std it waits on | Also, for some tests | Wave | Notes |
|---|---:|---|---|---:|---|
| arch | 39 | os info |  | 3 | uname machine (arm64 on macOS, not target.arch's aarch64) |
| b2sum | 39 | io streams, digest | error reasons | 2 | BLAKE2b with -l length chosen at run time |
| base32 | 1001 | io streams |  | 1 | decodes to raw bytes; -w 0 ends without a newline |
| base64 | 26 | io streams |  | 1 | thin wrapper over base32's code |
| basename | 163 | io streams |  | 1 | -z ends records with NUL and no newline |
| basenc | 95 | io streams |  | 1 | base16/32/64/64url/z85/base2 |
| cat | 961 | io streams | file stat, error reasons | 1 | "input file is output file" compares dev+ino; SIGPIPE death via raw now |
| chcon | 1001 | SELinux |  | blocked | Linux-only, not built on macOS |
| checksum_common | 437 | io streams, digest | error reasons | 2 | shared library of the *sum tools and cksum |
| chgrp | 187 | user, file stat, file ops | dir handles, error reasons | 5 | -R walks; lchown for -h |
| chmod | 974 | file stat, file ops | dir handles, error reasons | 4 | symbolic modes are port-local (uucore mode) |
| chown | 286 | user, file stat, file ops | dir handles, error reasons | 5 | user:group parsing, --from, --reference |
| chroot | 528 | process, user |  | 9 | chroot+setgroups+setgid+setuid then exec; tests are mostly error paths |
| cksum | 154 | io streams, digest | error reasons | 2 | CRC-32/CKSUM, crc32b, sysv, bsd, md5, sha1, sha2, sha3, blake2b, sm3 |
| comm | 464 | io streams | collation | 1 | C locale is byte order; 1 locale test |
| cp | 5111 | io streams, file stat, file ops, file handle, user | dir handles, xattr/ACL, error reasons | 5 | -a, links, sparse, reflink, backups, -i prompts |
| csplit | 1924 | io streams, regex | error reasons | 7 | creates and on error removes output files |
| cut | 1782 | io streams | collation | 1 | -c by locale charmap in 6 tests |
| date | 4197 | date | collation | 6 | TZif zones, strftime, GNU -d parsing; 62 tests use other locales |
| dd | 5021 | io streams, file handle, signal | error reasons | 9 | seek/skip, conv=, iflag/oflag, SIGUSR1/SIGINFO progress |
| df | 3267 | disk, file stat |  | 10 | statfs and the mount table |
| dir | 44 | io streams, file stat, user, date, tty | xattr/ACL, collation, dir handles | 8 | ls -C -b |
| dircolors | 554 | — (ready now) | io streams | 0 | reads a file; stdin '-' needs IO |
| dirname | 221 | io streams |  | 1 | -z |
| du | 1644 | io streams, file stat, date | dir handles, disk | 6 | dev+ino dedup, blocks, --time, --exclude glob |
| echo | 266 | io streams |  | 1 | -n and \c |
| env | 2550 | process, signal, os info |  | 9 | -i -u -C -S, signal dispositions, then exec |
| expand | 534 | io streams |  | 1 |  |
| expr | 2101 | regex, bigint div | collation | 7 | BRE with back-references; arbitrary-precision / and % |
| factor | 271 | io streams, bigint div |  | 2 | tests go past 2^128: mod_pow, gcd, div |
| false | 69 | — (ready now) |  | 0 | exit 1 |
| fmt | 1904 | io streams |  | 1 |  |
| fold | 802 | io streams |  | 1 |  |
| groups | 98 | user |  | 5 | getgroups, getgrouplist |
| head | 1760 | io streams, file handle | error reasons | 4 | leaves stdin's offset after the bytes it read (seek back) |
| hostid | 87 | — (ready now) |  | 0 | raw gethostid() works now |
| hostname | 145 | os info |  | 3 |  |
| id | 792 | user, os info |  | 5 | uid/gid/euid/egid, groups, names |
| install | 1784 | file stat, file ops, file handle, user, process | error reasons | 9 | -s runs strip; -m, -o, -g, -D, -p |
| join | 1246 | io streams | collation | 1 |  |
| kill | 401 | signal |  | 9 | send, list, names and numbers |
| link | 57 | file ops |  | 4 | link(2) |
| ln | 590 | file stat, file ops |  | 4 | symlink, link, backups, -r relative |
| logname | 49 | user |  | 5 | getlogin |
| ls | 5869 | io streams, file stat, user, date, tty | xattr/ACL, collation, dir handles | 8 | the largest utility: colors, grid, quoting, times, owners, inodes |
| md5sum | 12 | io streams, digest |  | 2 |  |
| mkdir | 355 | file ops | error reasons | 4 | -m mode, -p, "File exists" |
| mkfifo | 190 | file ops |  | 4 | mkfifo with mode |
| mknod | 312 | file ops |  | 4 | fifo unprivileged; devices need root |
| mktemp | 670 | file ops |  | 4 | O_EXCL create with mode 0600, mkdir 0700 |
| more | 1201 | io streams, tty |  | 8 | raw mode and keys; tests run without a tty |
| mv | 2030 | io streams, file stat, file ops, file handle | xattr/ACL, error reasons | 4 | rename now; across devices it copies as cp |
| nice | 225 | process, os info |  | 9 | get/setpriority (raw now) then exec |
| nl | 624 | io streams, regex |  | 7 | -b pBRE |
| nohup | 249 | process, signal, tty, file handle |  | 9 | ignore SIGHUP, redirect to nohup.out, exec |
| nproc | 140 | os info |  | 3 | online/configured cores, affinity, OMP_* vars |
| numfmt | 3281 | io streams | collation | 1 |  |
| od | 4344 | io streams, file handle |  | 4 | -j skips by seeking; f16/f32/f64 printing |
| paste | 419 | io streams |  | 1 |  |
| pathchk | 258 | os info |  | 3 | PATH_MAX/NAME_MAX per system |
| pinky | 605 | user sessions, user, file stat, date |  | 6 |  |
| pr | 1701 | io streams, date |  | 6 | header dates in local time |
| printenv | 80 | os info | io streams | 3 | whole environment list; -0 |
| printf | 226 | io streams |  | 1 | format engine is port-local, on bigint |
| ptx | 1234 | io streams, regex |  | 7 |  |
| pwd | 191 | file stat |  | 4 | -L checks $PWD is . by dev+ino |
| readlink | 197 | file ops, file stat |  | 4 | readlink, -f -e -m canonicalize |
| realpath | 348 | file ops, file stat |  | 4 | -m -s --relative-to need readlink and lstat |
| rm | 1834 | io streams, file stat, file ops | dir handles, tty, error reasons | 4 | -i prompts on stderr without newline; deep trees |
| rmdir | 224 | — (ready now) | error reasons | 0 | stat + file.remove; -p |
| runcon | 565 | SELinux |  | blocked | Linux-only, not built on macOS |
| seq | 973 | — (ready now) | io streams | 0 | raw SIGPIPE now; -s SEP streaming needs IO |
| sha1sum | 12 | io streams, digest |  | 2 |  |
| sha224sum | 12 | io streams, digest |  | 2 |  |
| sha256sum | 12 | io streams, digest |  | 2 |  |
| sha384sum | 12 | io streams, digest |  | 2 |  |
| sha512sum | 12 | io streams, digest |  | 2 |  |
| shred | 964 | file handle, file ops |  | 4 | write passes at offsets, fsync, truncate, rename-remove |
| shuf | 918 | io streams |  | 1 | --random-source needs uutils' exact draw (port-local) |
| sleep | 78 | — (ready now) |  | 0 |  |
| sort | 5937 | io streams | collation, process | 1 | 47 locale tests; --compress-program spawns |
| split | 3600 | io streams | process | 1 | --filter runs sh -c |
| stat | 1805 | file stat, disk, user, date, file ops |  | 10 | %-formats over every stat field, -f |
| stdbuf | 685 | process, preload lib |  | blocked | LD_PRELOAD/DYLD_INSERT_LIBRARIES library |
| stty | 1862 | tty |  | 8 | termios get/set, winsize |
| sum | 215 | io streams |  | 1 | BSD and SysV sums, port-local |
| sync | 307 | — (ready now) | file handle | 0 | bare sync() is raw now; -f/-d need fsync/syncfs |
| tac | 573 | io streams, regex |  | 7 | -r -s |
| tail | 3577 | io streams, file handle, file stat | signal | 4 | -f by polling; -F rotation by ino; --pid |
| tee | 447 | io streams, file handle |  | 4 | -a append, -p, output error modes |
| test | 1662 | file stat, file ops, os info |  | 4 | -r/-w/-x by access(2), -O -G, -ef, -nt |
| timeout | 624 | process, signal |  | 9 | spawn, wait, kill, timer, exit 124-137 |
| touch | 1201 | file ops, file stat, date |  | 6 | utimensat with ns, -h, -d/-t parsing |
| tr | 1542 | io streams |  | 1 |  |
| true | 73 | — (ready now) |  | 0 |  |
| truncate | 586 | file ops, file handle, file stat |  | 4 |  |
| tsort | 675 | io streams |  | 1 |  |
| tty | 142 | tty |  | 8 | ttyname |
| uname | 270 | os info |  | 3 |  |
| unexpand | 814 | io streams |  | 1 |  |
| uniq | 892 | io streams |  | 1 |  |
| unlink | 50 | — (ready now) | error reasons | 0 | stat first: a directory is refused |
| uptime | 356 | user sessions, os info, date |  | 6 | boot time, load average |
| users | 116 | user sessions |  | 5 |  |
| vdir | 43 | io streams, file stat, user, date, tty | xattr/ACL, collation, dir handles | 8 | ls -l -b |
| wc | 1597 | io streams |  | 1 | widths via std.text |
| who | 666 | user sessions, file stat, date |  | 6 |  |
| whoami | 73 | user |  | 5 |  |
| yes | 201 | — (ready now) |  | 0 | raw signal(SIGPIPE, SIG_DFL) gives death by SIGPIPE now |
