# w.pl CMD...: run CMD in this process group, ignoring SIGINT here, and print how it ended.
use POSIX;
my $pid = fork();
if ($pid == 0) { exec @ARGV or die; }
$SIG{INT} = 'IGNORE'; $SIG{QUIT} = 'IGNORE';
waitpid($pid, 0);
my $s = $?;
printf "ended: %s\n", ($s & 127) ? "signal ".($s & 127) : "status ".($s >> 8);
