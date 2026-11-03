#!/usr/bin/env python3
"""Counts, over tests/by-util, how many test functions use each kind of check."""
import re, glob, sys, collections
root = sys.argv[1]
K = collections.OrderedDict([
 ("exact stdout", r"\.stdout_is\(|\.stdout_only\(|\.stdout_is_bytes\(|\.stdout_only_bytes\(|stdout_is_fixture|stdout_only_fixture|stdout_is_templated|stdout_str\(\)\s*,|assert_eq!\([^;]*stdout_str"),
 ("partial stdout (contains/matches)", r"stdout_contains|stdout_matches|stdout_does_not_contain|stdout_does_not_match"),
 ("empty stdout", r"no_stdout\(|no_output\("),
 ("exact stderr", r"\.stderr_is\(|\.stderr_only\(|stderr_is_bytes|stderr_only_bytes|usage_error\("),
 ("partial stderr", r"stderr_contains|stderr_matches|stderr_does_not_contain"),
 ("empty stderr", r"no_stderr\(|no_output\(|\.succeeds\(\)\s*\.stdout_only|stdout_only"),
 ("exit code (exact)", r"code_is\(|fails_with_code\(|usage_error\("),
 ("asserts success or failure", r"\.succeeds\(\)|\.fails\(\)|\.success\(\)|\.failure\(\)"),
 ("--help / --version text", r'"--help"|"-h"\)|"--version"|"-V"\)'),
 ("fixture files (tests/fixtures)", r"_fixture\(|at\.read\(|fixtures\.read|\.pipe_in_fixture|\"[\w./-]+\.(txt|expected|csv|in|out|log|ans)\""),
 ("writes/reads files in a temp dir", r"at\.(touch|write|mkdir|append|symlink|make_file|read|file_exists|dir_exists)"),
 ("stdin piped", r"pipe_in"),
 ("LC_ALL / LANG set", r'"LC_ALL"|"LANG"|"LC_[A-Z]+"'),
 ("TZ set", r'"TZ"'),
 ("needs root (sudo)", r"run_ucmd_as_root|is_root\(\)|geteuid\(\)\s*==\s*0"),
 ("terminal / pty", r"terminal_simulation|TerminalSimulation|\bpty\b|openpty|isatty|is_terminal|/dev/tty"),
 ("signals / timing / child process", r"\.run_no_wait\(|kill\(|Signal::|sleep\(|delay\("),
 ("compares with GNU (expected_result)", r"expected_result\(|run_with_gnu|gnu_"),
])
tests = 0
use = collections.Counter()
for f in glob.glob(f"{root}/tests/by-util/test_*.rs"):
    s = open(f, errors="replace").read()
    marks = [m.start() for m in re.finditer(r"^\s*#\[(?:test|rstest)\]", s, re.M)]
    for i, a in enumerate(marks):
        b = marks[i + 1] if i + 1 < len(marks) else len(s)
        pre = s.rfind("\n}", 0, a)  # attributes since the previous item
        p = s[max(pre, 0):b]
        tests += 1
        for k, rx in K.items():
            if re.search(rx, p):
                use[k] += 1
        if re.search(r'#\[cfg\([^\n]*("linux"|"android"|selinux)', p) and not re.search(r'#\[cfg\([^\n]*("macos"|apple|not\()', p):
            use["cfg Linux/Android/SELinux only"] += 1
        if re.search(r"#\[ignore", p):
            use["#[ignore] in source"] += 1
print(f"test functions: {tests}")
for k in list(K) + ["cfg Linux/Android/SELinux only", "#[ignore] in source"]:
    print(f"| {k} | {use[k]} | {100 * use[k] / tests:.0f}% |")
