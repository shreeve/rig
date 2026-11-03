| # | bench | command | input | env | check | note |
|---|---|---|---|---|---|---|
| 1 | b64_encode_synthetic | `base64 {in}` | in=by_size_100m_80 |  | exact | Rust: 5000 MB input, but its tempdir is dropped before timing, so uumain gets a missing file; here 100 MB, the intent. |
| 2 | b64_decode_synthetic | `base64 -d {in}` | in=b64_of_by_size_100m |  | exact | Rust decodes an empty file (its setup call fails); here the base64 of the 100 MB input, the intent. |
| 3 | b64_decode_ignore_garbage_synthetic | `base64 -d -i {in}` | in=b64_of_by_size_100m |  | exact | as b64_decode_synthetic |
| 4 | base16_encode_to_dev_null | `basenc --base16 {in} > /dev/null` | in=a5_16m |  | exact |  |
| 5 | base16_encode_to_file | `basenc --base16 {in}` | in=a5_16m |  | exact |  |
| 6 | cat_default/10000 | `cat {in}` | in=a_10000 |  | exact |  |
| 7 | cat_default/10000000 | `cat {in}` | in=a_10000000 |  | exact |  |
| 8 | cksum_sysv | `cksum --algorithm sysv {in}` | in=by_size_100m_80 |  | exact |  |
| 9 | cksum_bsd | `cksum --algorithm bsd {in}` | in=by_size_100m_80 |  | exact |  |
| 10 | cksum_crc | `cksum --algorithm crc {in}` | in=by_size_100m_80 |  | exact |  |
| 11 | cksum_crc32b | `cksum --algorithm crc32b {in}` | in=by_size_100m_80 |  | exact |  |
| 12 | cksum_md5 | `cksum --algorithm md5 {in}` | in=by_size_100m_80 |  | exact |  |
| 13 | cksum_sha1 | `cksum --algorithm sha1 {in}` | in=by_size_100m_80 |  | exact |  |
| 14 | cksum_sha2 | `cksum --algorithm sha2 --length 256 {in}` | in=by_size_100m_80 |  | exact |  |
| 15 | cksum_sha3 | `cksum --algorithm sha3 --length 256 {in}` | in=by_size_100m_80 |  | exact |  |
| 16 | cksum_blake2b | `cksum --algorithm blake2b {in}` | in=by_size_100m_80 |  | exact |  |
| 17 | cksum_sm3 | `cksum --algorithm sm3 {in}` | in=by_size_100m_80 |  | exact |  |
| 18 | cksum_sha224 | `cksum --algorithm sha224 {in}` | in=by_size_100m_80 |  | exact |  |
| 19 | cksum_sha256 | `cksum --algorithm sha256 {in}` | in=by_size_100m_80 |  | exact |  |
| 20 | cksum_sha384 | `cksum --algorithm sha384 {in}` | in=by_size_100m_80 |  | exact |  |
| 21 | cksum_sha512 | `cksum --algorithm sha512 {in}` | in=by_size_100m_80 |  | exact |  |
| 22 | cksum_blake3 | `cksum --algorithm blake3 {in}` | in=by_size_100m_80 |  | exact |  |
| 23 | cksum_shake128 | `cksum --algorithm shake128 --length 256 {in}` | in=by_size_100m_80 |  | exact | Rust hashes in memory through uucore::sum, not uumain; here the CLI. |
| 24 | cksum_shake256 | `cksum --algorithm shake256 --length 512 {in}` | in=by_size_100m_80 |  | exact | as cksum_shake128 |
| 25 | cksum_default | `cksum {in}` | in=by_size_100m_80 |  | exact |  |
| 26 | cksum_raw_output | `cksum --raw {in}` | in=by_size_100m_80 |  | exact |  |
| 27 | cksum_multiple_files | `cksum {in} {in2} {in3}` | in=by_size_50m_80_a, in2=by_size_50m_80_b, in3=by_size_50m_80_c |  | exact |  |
| 28 | cp_recursive_balanced_tree/(5,4,10) | `cp -R {tree} {dest}` | tree=balanced_5_4_10 |  | exact |  |
| 29 | cp_archive_balanced_tree/(5,4,10) | `cp -a {tree} {dest}` | tree=balanced_5_4_10 |  | exact |  |
| 30 | cp_recursive_wide_tree/(6000,800) | `cp -R {tree} {dest}` | tree=wide_6000_800 |  | exact |  |
| 31 | cp_recursive_deep_tree/(120,4) | `cp -R {tree} {dest}` | tree=deep_120_4 |  | exact |  |
| 32 | cp_preserve_metadata/(5,4,10) | `cp -R --preserve...(26 chars) {tree} {dest}` | tree=balanced_5_4_10 |  | exact |  |
| 33 | cp_large_file/16 | `cp {in} {dest}` | in=bin_16m_78 |  | exact |  |
| 34 | csplit_line_number | `csplit -f {outdir}/xx {in} 10000 50000 90000` | in=by_lines_100000_80 |  | exact |  |
| 35 | csplit_regex_pattern | `csplit -f {outdir}/xx {in} /^SECTION/ {*}` | in=csplit_sections |  | exact |  |
| 36 | cut_bytes | `cut -b 1-20 {in}` | in=by_lines_100000_80 |  | exact |  |
| 37 | cut_characters | `cut -c 5-30 {in}` | in=mixed_100000 |  | exact |  |
| 38 | cut_characters_long_lines | `cut -c 20-70 {in}` | in=cut_long |  | exact |  |
| 39 | cut_fields_tab | `cut -f 2,4 {in}` | in=cut_tab |  | exact |  |
| 40 | cut_fields_custom_delim | `cut -d , -f 1,3,5 {in}` | in=cut_comma |  | exact |  |
| 41 | cut_fields_newline_delim | `cut -d \n -f 1,3,5 {in}` | in=cut_nl |  | exact |  |
| 42 | file_iso_dates | `date -f {in}` | in=dates_iso_1000 |  | exact |  |
| 43 | file_tz_abbreviations | `date -f {in}` | in=dates_est_1000 |  | exact |  |
| 44 | file_custom_format | `date -f {in} +%A %d %B %Y` | in=dates_iso_1000 |  | exact |  |
| 45 | single_date_now | `date ` |  |  | exit |  |
| 46 | complex_relative_date | `date --date=las...(33 chars)` |  |  | exit | output depends on today; exit code only |
| 47 | file_localized_names | `date -f {in} +%A %a %B %b` | in=dates_iso_1000 | LC_ALL=fr_FR.UTF-8 | exact |  |
| 48 | dd_copy_default | `dd if={in} of={dest} status=none` | in=bin_32m_78 |  | exact |  |
| 49 | dd_copy_4k_blocks | `dd if={in} of={dest} bs=4K status=none` | in=bin_24m_78 |  | exact |  |
| 50 | dd_copy_64k_blocks | `dd if={in} of={dest} bs=64K status=none` | in=bin_64m_78 |  | exact |  |
| 51 | dd_copy_1m_blocks | `dd if={in} of={dest} bs=1M status=none` | in=bin_128m_78 |  | exact |  |
| 52 | dd_copy_separate_blocks | `dd if={in} of={dest} ibs=8K obs=16K status=none` | in=bin_48m_78 |  | exact |  |
| 53 | dd_copy_partial | `dd if={in} of={dest} bs=4K count=1024 status=none` | in=bin_32m_78 |  | exact |  |
| 54 | dd_copy_with_skip | `dd if={in} of={dest} bs=4K skip=256 status=none` | in=bin_48m_78 |  | exact |  |
| 55 | dd_copy_with_seek | `dd if={in} of={dest} bs=4K seek=256 status=none` | in=bin_48m_78 |  | exact |  |
| 56 | dd_copy_8k_blocks | `dd if={in} of={dest} bs=8K status=none` | in=bin_32m_78 |  | exact |  |
| 57 | df_deep_directory | `df ` | tree=deep_cwd_2000 |  | exit | run from a directory 20000 deep (Rust); on macOS 2000 deep, since APFS makes each level slower than the last (8000 levels take 170 s). Exit code only: free space changes between runs. |
| 58 | du_wide_tree/(5000,500) | `du {tree}` | tree=wide_5000_500 |  | exact |  |
| 59 | du_all_wide_tree/(5000,500) | `du -a {tree}` | tree=wide_5000_500 |  | exact |  |
| 60 | du_deep_tree/(100,3) | `du {tree}` | tree=deep_100_3 |  | exact |  |
| 61 | du_summarize_balanced_tree/(5,4,10) | `du -s {tree}` | tree=balanced_5_4_10 |  | exact |  |
| 62 | echo_consecutive_calls | `echo Hello World (x100)` |  |  | exact |  |
| 63 | true_consecutive_calls | `true  (x100)` |  |  | exact |  |
| 64 | false_consecutive_calls | `false  (x100)` |  |  | exact |  |
| 65 | expand_many_lines/100000 | `expand {in}` | in=expand_100000 |  | exact |  |
| 66 | expand_custom_tabstops/50000 | `expand --tabs=4,8,12 {in}` | in=expand_tabs_50000 |  | exact |  |
| 67 | unexpand_many_lines/100000 | `unexpand {in}` | in=unexpand_100000 |  | exact |  |
| 68 | unexpand_large_file/10 | `unexpand {in}` | in=unexpand_10m |  | exact |  |
| 69 | expr_index_no_match | `expr index AAAAAAAAAA...(100000 chars) BBBBBBBBBB...(100000 chars)` |  |  | exact |  |
| 70 | expr_index_match_at_end | `expr index AAAAAAAAAA...(100001 chars) ZZZZZZZZZZ...(100000 chars)` |  |  | exact |  |
| 71 | factor_multiple_u64s/2 | `factor 2 3 4 ... 2501 args` |  |  | exact | Rust calls uumain 2501 times, one number each; here one process with 2501 numbers (the per-call cost is what true/false/echo measure). |
| 72 | factor_large_u64_prime | `factor 18446744073709551557` |  |  | exact |  |
| 73 | factor_64bit_semiprime | `factor 18446743979220271189` |  |  | exact |  |
| 74 | hard::factor_three_39_bit_primes | `factor 1483227267...(36 chars)` |  |  | exact |  |
| 75 | hard::factor_five_38_bit_primes | `factor 1569275491...(58 chars)` |  |  | exact |  |
| 76 | hard::factor_thirteen_39_bit_primes | `factor 2561926720...(153 chars)` |  |  | exact |  |
| 77 | hard::factor_a_prime_to_the_seventh | `factor 5653910668...(74 chars)` |  |  | exact |  |
| 78 | hard::factor_small_factors_and_a_large_prime | `factor 4881074309...(63 chars)` |  |  | exact |  |
| 79 | hard::factor_a_1279_bit_prime | `factor 1040793219...(386 chars)` |  |  | exact |  |
| 80 | fold_many_lines/100000 | `fold {in}` | in=fold_100000 |  | exact |  |
| 81 | fold_custom_width/50000 | `fold -w 40 {in}` | in=fold_50000 |  | exact |  |
| 82 | hostname_ip_lookup/100000 | `hostname -i` |  |  | exit | Rust uses a 100k-line hosts file only under LD_PRELOAD nss_wrapper (Linux); on macOS -i fails to resolve and exits 1. |
| 83 | hostname_basic | `hostname ` |  |  | exact |  |
| 84 | join_full_match | `join {in} {in2}` | in=join_full_1, in2=join_full_2 |  | exact |  |
| 85 | join_partial_overlap | `join {in} {in2}` | in=join_part_1, in2=join_part_2 |  | exact |  |
| 86 | join_custom_separator | `join -t \t {in} {in2}` | in=join_tab_1, in2=join_tab_2 |  | exact |  |
| 87 | join_french_locale | `join {in} {in2}` | in=join_full_1, in2=join_full_2 | LC_ALL=fr_FR.UTF-8 | exact |  |
| 88 | join_unicode_locale | `join {in} {in2}` | in=join_uni_1, in2=join_uni_2 | LC_ALL=fr_FR.UTF-8 | exact |  |
| 89 | ls_recursive_balanced_tree/(6,4,15) | `ls -R {tree}` | tree=balanced_6_4_15 |  | exact |  |
| 90 | ls_recursive_long_all_balanced_tree/(6,4,15) | `ls -R -a -l {tree}` | tree=balanced_6_4_15 |  | exact |  |
| 91 | ls_recursive_wide_tree/(10000,1000) | `ls -R {tree}` | tree=wide_10000_1000 |  | exact |  |
| 92 | ls_recursive_long_all_wide_tree/(15000,1500) | `ls -R -a -l {tree}` | tree=wide_15000_1500 |  | exact |  |
| 93 | ls_recursive_deep_tree/(200,2) | `ls -R {tree}` | tree=deep_200_2 |  | exact |  |
| 94 | ls_recursive_long_all_deep_tree/(100,4) | `ls -R -a -l {tree}` | tree=deep_100_4 |  | exact |  |
| 95 | ls_recursive_mixed_tree | `ls -R {tree}` | tree=ls_mixed |  | exact |  |
| 96 | ls_recursive_long_all_mixed_tree | `ls -R -a -l {tree}` | tree=ls_mixed |  | exact |  |
| 97 | mv_single_file | `mv (per-sample calls)` |  |  | exact |  |
| 98 | mv_multiple_to_dir | `mv (per-sample calls)` |  |  | exact |  |
| 99 | mv_directory | `mv {scratch}/src_tree {scratch}/dest_tree` |  |  | exact |  |
| 100 | mv_force_overwrite | `mv (per-sample calls)` |  |  | exact |  |
| 101 | rm_single_file | `rm (per-sample calls)` |  |  | exact |  |
| 102 | rm_multiple_files | `rm (per-sample calls)` |  |  | exact |  |
| 103 | rm_recursive_tree | `rm -r {scratch}/test_tree` |  |  | exact |  |
| 104 | rm_force_files | `rm (per-sample calls)` |  |  | exact |  |
| 105 | nl_many_lines/100000 | `nl {in}` | in=by_lines_100000_80 |  | exact |  |
| 106 | nl_large_file/10 | `nl -ba {in}` | in=by_size_10m_80 |  | exact |  |
| 107 | numfmt_to_si/10000 | `numfmt --to=si 1 2 ... 10001 args` |  |  | exact |  |
| 108 | numfmt_to_si_precision/10000 | `numfmt --to=si --format=%.6f 1 ... 10002 args` |  |  | exact |  |
| 109 | numfmt_to_iec/10000 | `numfmt --to=iec 1 2 ... 10001 args` |  |  | exact |  |
| 110 | numfmt_from_si/10000 | `numfmt --from=si 1K 2K ... 10001 args` |  |  | exact |  |
| 111 | numfmt_large_numbers_si/10000 | `numfmt --to=si 2000000 3000000 ... 10001 args` |  |  | exact |  |
| 112 | numfmt_padding/(10000,50) | `numfmt --to=si --padding=50 1 ... 10002 args` |  |  | exact |  |
| 113 | numfmt_round_modes/(up,10000) | `numfmt --to=si --round=up 1 ... 10002 args` |  |  | exact |  |
| 114 | numfmt_round_modes/(down,10000) | `numfmt --to=si --round=down 1 ... 10002 args` |  |  | exact |  |
| 115 | numfmt_round_modes/(towards-zero,10000) | `numfmt --to=si --round=towards-zero 1 ... 10002 args` |  |  | exact |  |
| 116 | numfmt_stream_to_si | `numfmt --to=si < {in} > /dev/null` | in=numfmt_stream |  | exact |  |
| 117 | numfmt_stream_to_si_precision | `numfmt --to=si --format=%.2f < {in} > /dev/null` | in=numfmt_stream |  | exact |  |
| 118 | od_default | `od {in}` | in=od_1m |  | exact |  |
| 119 | od_hex_bytes | `od -t x1 {in}` | in=od_1m |  | exact |  |
| 120 | od_chars | `od -c {in}` | in=od_1m |  | exact |  |
| 121 | ptx_short_lines/100000 | `ptx {in}` | in=by_lines_100000_80 |  | exact |  |
| 122 | ptx_long_lines/100 | `ptx {in}` | in=ptx_fixed_100 |  | exact |  |
| 123 | ptx_input_references_short_lines/100000 | `ptx -r {in}` | in=by_lines_100000_80 |  | exact |  |
| 124 | ptx_input_references_long_lines/1000 | `ptx -r {in}` | in=ptx_fixed_1000 |  | exact |  |
| 125 | ptx_tex/10000 | `ptx -T {in}` | in=ptx_tex_10000 |  | exact |  |
| 126 | seq_integers | `seq 1 1000000` |  |  | exact |  |
| 127 | seq_large_integers | `seq 4e10003 4e10003` |  |  | exact |  |
| 128 | seq_custom_separator | `seq -s , 1 1000000` |  |  | exact |  |
| 129 | seq_with_step | `seq 1 2 1000000` |  |  | exact |  |
| 130 | seq_formatted | `seq -f %.3f 1 0.1 10000` |  |  | exact |  |
| 131 | shuf_lines/(100000,80) | `shuf {in}` | in=by_lines_100000_80 |  | sorted |  |
| 132 | shuf_lines/(100000,10) | `shuf {in}` | in=by_lines_100000_10 |  | sorted |  |
| 133 | shuf_input_range/1000000 | `shuf -i 1-1000000` |  |  | sorted |  |
| 134 | shuf_repeat_sampling/(50000,80) | `shuf -r -n 50000 {in}` | in=by_lines_10000_80 |  | lines |  |
| 135 | shuf_repeat_sampling/(50000,10) | `shuf -r -n 50000 {in}` | in=by_lines_10000_10 |  | lines |  |
| 136 | sort_ascii_only/500000 | `sort -o {out} {in}` | in=ascii_500000 |  | exact |  |
| 137 | sort_accented_data/500000 | `sort -o {out} {in}` | in=accented_500000 |  | exact |  |
| 138 | sort_mixed_data/500000 | `sort -o {out} {in}` | in=mixed_500000 |  | exact |  |
| 139 | sort_case_sensitive/500000 | `sort -o {out} {in}` | in=case_500000 |  | exact |  |
| 140 | sort_case_insensitive/500000 | `sort -f -o {out} {in}` | in=case_500000 |  | exact |  |
| 141 | sort_dictionary_order/500000 | `sort -d -o {out} {in}` | in=mixed_500000 |  | exact |  |
| 142 | sort_numeric/500000 | `sort -n -o {out} {in}` | in=sort_numeric_500000 |  | exact |  |
| 143 | sort_general_numeric/200000 | `sort -g -o {out} {in}` | in=sort_g_200000 |  | exact |  |
| 144 | sort_reverse_locale/500000 | `sort -r -o {out} {in}` | in=accented_500000 |  | exact |  |
| 145 | sort_key_field/500000 | `sort -k 2 -o {out} {in}` | in=sort_key_500000 |  | exact |  |
| 146 | sort_unique_locale/500000 | `sort -u -o {out} {in}` | in=accented_500000 |  | exact |  |
| 147 | sort_long_line/10000 | `sort {in} {in2} -o {out}` | in=b_10000_nl, in2=a_10000_nl |  | exact |  |
| 148 | merge_pre_sorted_files | `sort -m -o {out} ... 11 args` | m0=merge8_ascii_500000_0, m1=merge8_ascii_500000_1, m2=merge8_ascii_500000_2, m3=merge8_ascii_500000_3, m4=merge8_ascii_500000_4, m5=merge8_ascii_500000_5, m6=merge8_ascii_500000_6, m7=merge8_ascii_500000_7 |  | exact |  |
| 149 | sort_ascii_c_locale | `sort -o {out} {in}` | in=ascii_simple_2000000 | LC_ALL=C | exact |  |
| 150 | sort_mixed_c_locale | `sort -o {out} {in}` | in=mixed_locale_50000 | LC_ALL=C | exact |  |
| 151 | sort_german_c_locale | `sort -o {out} {in}` | in=german_50000 | LC_ALL=C | exact |  |
| 152 | sort_shared_prefix_c_locale | `sort --parallel=1 -o {out} {in}` | in=shared_prefix_500000 | LC_ALL=C | exact |  |
| 153 | sort_german_de_locale | `sort -o {out} {in}` | in=german_50000 | LC_ALL=de_DE.UTF-8 | exact |  |
| 154 | sort_ascii_utf8_locale | `sort -o {out} {in}` | in=ascii_simple_1500000 | LC_ALL=en_US.UTF-8 | exact |  |
| 155 | sort_mixed_utf8_locale | `sort -o {out} {in}` | in=mixed_locale_50000 | LC_ALL=en_US.UTF-8 | exact |  |
| 156 | sort_numeric_utf8_locale | `sort -n -o {out} {in}` | in=desc_50000 | LC_ALL=en_US.UTF-8 | exact |  |
| 157 | sort_reverse_utf8_locale | `sort -r -o {out} {in}` | in=mixed_locale_50000 | LC_ALL=en_US.UTF-8 | exact |  |
| 158 | sort_unique_utf8_locale | `sort -u -o {out} {in}` | in=mixed_locale_50000 | LC_ALL=en_US.UTF-8 | exact |  |
| 159 | sort_very_long_lines_utf8_locale | `sort --parallel 1 -o {out} {in}` | in=letters_1m_lines | LC_ALL=en_US.UTF-8 | exact |  |
| 160 | sort_long_common_prefix_utf8_locale | `sort --parallel 1 -o {out} {in}` | in=prefix16k | LC_ALL=en_US.UTF-8 | exact |  |
| 161 | merge_single_file_utf8_locale | `sort -m -o {out} {in}` | in=ascii_simple_500000_sorted | LC_ALL=en_US.UTF-8 | exact |  |
| 162 | merge_pre_sorted_files_utf8_locale | `sort -m -o {out} ... 11 args` | m0=merge8_ascii_500000_0, m1=merge8_ascii_500000_1, m2=merge8_ascii_500000_2, m3=merge8_ascii_500000_3, m4=merge8_ascii_500000_4, m5=merge8_ascii_500000_5, m6=merge8_ascii_500000_6, m7=merge8_ascii_500000_7 | LC_ALL=en_US.UTF-8 | exact |  |
| 163 | sort_spill_to_tmp_files_utf8_locale | `sort --parallel 1 -S 1M -o {out} {in}` | in=mixed_200000 | LC_ALL=en_US.UTF-8 | exact |  |
| 164 | check_sorted_utf8_locale | `sort -c {in}` | in=mixed_2500000_sorted_en_US | LC_ALL=en_US.UTF-8 | exact | input: mixed_data(2.5M) sorted bytewise, then sorted by the first binary under en_US.UTF-8, as the Rust bench does with uumain |
| 165 | split_lines | `split -l 1000 {in} {outdir}/x` | in=by_lines_100000_80 |  | exact |  |
| 166 | split_bytes | `split -b 100K {in} {outdir}/x` | in=by_size_10m_80 |  | exact |  |
| 167 | split_number_chunks | `split -n 10 {in} {outdir}/x` | in=by_lines_100000_80 |  | exact |  |
| 168 | split_number_chunks_round_robin | `split -n r/10 {in} {outdir}/x` | in=by_lines_100000_80 |  | exact |  |
| 169 | split_numeric_suffix | `split -d -l 500 {in} {outdir}/x` | in=by_lines_100000_80 |  | exact |  |
| 170 | tee_stdin_file/10000000 | `tee  < {in}` | in=a_10000000 |  | exact |  |
| 171 | timeout_quick_exit | `timeout 0.02 true` |  |  | exit |  |
| 172 | timeout_enforced | `timeout 0.02 sleep 0.2` |  |  | exit | the system sleep; exits 124 |
| 173 | timer_expiry_latency/0.001 | `timeout 0.001 sleep 5` |  |  | exit | Rust's child is the bench executable sleeping 5 s; here the system sleep |
| 174 | timer_expiry_latency/0.005 | `timeout 0.005 sleep 5` |  |  | exit | Rust's child is the bench executable sleeping 5 s; here the system sleep |
| 175 | timer_expiry_latency/0.02 | `timeout 0.02 sleep 5` |  |  | exit | Rust's child is the bench executable sleeping 5 s; here the system sleep |
| 176 | tr_ascii_range_lower_to_upper | `tr a-z A-Z < {in} > /dev/null` | in=by_size_16m_80 |  | exact |  |
| 177 | tr_single_char_replace | `tr a b < {in} > /dev/null` | in=by_size_16m_80 |  | exact |  |
| 178 | tr_multi_char_translate | `tr aeiou AEIOU < {in} > /dev/null` | in=by_size_16m_80 |  | exact |  |
| 179 | tr_delete_ascii_range | `tr -d a-z < {in} > /dev/null` | in=by_size_16m_80 |  | exact |  |
| 180 | tr_delete_single_char | `tr -d \n < {in} > /dev/null` | in=by_size_16m_80 |  | exact |  |
| 181 | tsort_linear_chain/1000000 | `tsort {in}` | in=tsort_linear_1000000 |  | exact |  |
| 182 | tsort_tree_dag/(10,3) | `tsort {in}` | in=tsort_tree_10_3 |  | exact |  |
| 183 | tsort_complex_dag/50000 | `tsort {in}` | in=tsort_complex_50000 |  | exact |  |
| 184 | tsort_wide_dag/100000 | `tsort {in}` | in=tsort_wide_100000 |  | exact |  |
| 185 | uniq_heavy_duplicates/10000 | `uniq {in}` | in=uniq_1000x10 |  | exact |  |
| 186 | uniq_with_count/10000 | `uniq -c {in}` | in=uniq_100x100 |  | exact |  |
| 187 | uniq_case_insensitive/10000 | `uniq -i {in}` | in=uniq_case_10000 |  | exact |  |
| 188 | uniq_check_chars/(10000,1) | `uniq -w 1 {in}` | in=uniq_1000x10 |  | exact |  |
| 189 | uniq_check_chars/(10000,512) | `uniq -w 512 {in}` | in=uniq_1000x10 |  | exact |  |
| 190 | wc_bytes_synthetic/1 | `wc -c {in}` | in=by_size_1m_80 | LC_ALL=C.UTF-8 | exact |  |
| 191 | wc_bytes_synthetic/500 | `wc -c {in}` | in=by_size_500m_80 | LC_ALL=C.UTF-8 | exact |  |
| 192 | wc_words_synthetic/2000 | `wc -w {in}` | in=by_size_2000m_80 | LC_ALL=C.UTF-8 | exact |  |
| 193 | wc_bytes_lines_synthetic/2000 | `wc -cl {in}` | in=by_size_2000m_80 | LC_ALL=C.UTF-8 | exact |  |
| 194 | wc_lines_variable_length/(50,500) | `wc -l {in}` | in=by_size_50m_500 | LC_ALL=C.UTF-8 | exact |  |
| 195 | wc_lines_large_line_count/500000 | `wc -l {in}` | in=by_lines_500000_80 | LC_ALL=C.UTF-8 | exact |  |
| 196 | wc_chars_large_line_count/100000 | `wc -m {in}` | in=by_lines_100000_80 | LC_ALL=C.UTF-8 | exact |  |
| 197 | wc_chars_utf8/100000 | `wc -m {in}` | in=wc_utf8_100000 | LC_ALL=C.UTF-8 | exact |  |
| 198 | wc_words_large_line_count/100000 | `wc -w {in}` | in=by_lines_100000_80 | LC_ALL=C.UTF-8 | exact |  |
| 199 | wc_default_large_line_count/100000 | `wc -lwc {in}` | in=by_lines_100000_80 | LC_ALL=C.UTF-8 | exact |  |
| 200 | wc_lines_extreme_line_lengths/(100000,200) | `wc -l {in}` | in=by_lines_100000_200 | LC_ALL=C.UTF-8 | exact |  |

| bench | rust min | rust median | rust RSS | gnu min | gnu median | gnu RSS | gnu vs rust | rounds | load | output |
|---|---|---|---|---|---|---|---|---|---|---|
| b64_encode_synthetic | 102.00 ms | 109.43 ms | 7.5 MB | 163.51 ms | 172.01 ms | 1.9 MB | 60% slower | 10 | 4.0 | same |
| b64_decode_synthetic | 283.06 ms | 296.99 ms | 7.5 MB | 246.21 ms | 266.96 ms | 1.8 MB | 15% faster | 10 | 4.0 | same |
| b64_decode_ignore_garbage_synthetic | 257.35 ms | 261.60 ms | 7.5 MB | 281.63 ms | 285.66 ms | 1.8 MB | 9% slower | 10 | 4.2 | same |
| base16_encode_to_dev_null | 13.81 ms | 14.34 ms | 7.7 MB | 24.66 ms | 25.15 ms | 2.0 MB | 79% slower | 10 | 4.1 | same |
| base16_encode_to_file | 19.59 ms | 20.46 ms | 7.7 MB | 51.95 ms | 53.05 ms | 2.0 MB | 165% slower | 10 | 4.1 | same |
| cat_default/10000 | 3.55 ms | 4.08 ms | 7.4 MB | 1.43 ms | 1.61 ms | 1.8 MB | 148% faster | 10 | 4.1 | same |
| cat_default/10000000 | 5.85 ms | 6.46 ms | 7.4 MB | 2.99 ms | 3.25 ms | 2.0 MB | 95% faster | 10 | 4.1 | same |
| cksum_sysv | 12.09 ms | 12.28 ms | 7.7 MB | 12.50 ms | 12.87 ms | 1.9 MB | 3% slower | 10 | 4.1 | same |
| cksum_bsd | 89.32 ms | 91.40 ms | 7.7 MB | 112.41 ms | 114.17 ms | 1.9 MB | 26% slower | 10 | 4.1 | same |
| cksum_crc | 13.21 ms | 14.01 ms | 7.8 MB | 50.93 ms | 54.73 ms | 1.9 MB | 285% slower | 10 | 4.1 | same |
| cksum_crc32b | 12.64 ms | 13.42 ms | 7.7 MB | 53.08 ms | 54.18 ms | 1.9 MB | 320% slower | 10 | 4.1 | same |
| cksum_md5 | 141.29 ms | 143.62 ms | 7.8 MB | 136.22 ms | 138.44 ms | 1.9 MB | 4% faster | 10 | 4.1 | same |
| cksum_sha1 | 48.98 ms | 50.19 ms | 7.8 MB | 106.11 ms | 107.37 ms | 1.9 MB | 117% slower | 10 | 4.3 | same |
| cksum_sha2 | 45.16 ms | 49.61 ms | 7.8 MB | 206.97 ms | 217.55 ms | 1.9 MB | 358% slower | 10 | 4.3 | same |
| cksum_sha3 | 111.18 ms | 113.32 ms | 7.8 MB | 232.14 ms | 234.73 ms | 1.9 MB | 109% slower | 10 | 4.3 | same |
| cksum_blake2b | 78.47 ms | 79.34 ms | 7.8 MB | 85.56 ms | 86.32 ms | 1.9 MB | 9% slower | 10 | 4.3 | same |
| cksum_sm3 | 203.59 ms | 206.33 ms | 7.8 MB | 207.51 ms | 210.61 ms | 1.9 MB | 2% slower | 10 | 4.2 | same |
| cksum_sha224 | 43.91 ms | 44.58 ms | 7.8 MB | 202.54 ms | 208.87 ms | 1.9 MB | 361% slower | 10 | 4.2 | same |
| cksum_sha256 | 46.39 ms | 47.12 ms | 7.8 MB | 214.37 ms | 215.77 ms | 1.9 MB | 362% slower | 10 | 4.2 | same |
| cksum_sha384 | 71.09 ms | 73.61 ms | 7.8 MB | 138.94 ms | 140.37 ms | 1.9 MB | 95% slower | 10 | 4.1 | same |
| cksum_sha512 | 71.33 ms | 76.84 ms | 7.7 MB | 142.83 ms | 154.63 ms | 1.9 MB | 100% slower | 10 | 4.1 | same |
| cksum_blake3 | 63.07 ms | 64.34 ms | 7.8 MB | 1.83 ms | 2.12 ms | 1.8 MB | n/a (exit differs) | 10 | 4.0 | gnu differs: exit, stdout |
| cksum_shake128 | 103.19 ms | 106.76 ms | 7.8 MB | 1.81 ms | 2.32 ms | 1.9 MB | n/a (exit differs) | 10 | 4.0 | gnu differs: exit, stdout |
| cksum_shake256 | 124.37 ms | 126.83 ms | 7.8 MB | 1.81 ms | 2.25 ms | 1.8 MB | n/a (exit differs) | 10 | 4.0 | gnu differs: exit, stdout |
| cksum_default | 14.33 ms | 15.28 ms | 7.7 MB | 56.29 ms | 57.27 ms | 1.9 MB | 293% slower | 10 | 4.1 | same |
| cksum_raw_output | 14.09 ms | 14.72 ms | 7.7 MB | 53.99 ms | 55.82 ms | 1.9 MB | 283% slower | 10 | 4.1 | same |
| cksum_multiple_files | 18.56 ms | 19.11 ms | 7.7 MB | 81.47 ms | 82.24 ms | 1.9 MB | 339% slower | 10 | 4.1 | same |
| cp_recursive_balanced_tree/(5,4,10) | 718.70 ms | 833.86 ms | 11.0 MB | 533.74 ms | 593.15 ms | 2.1 MB | 35% faster | 10 | 4.1 | same |
| cp_archive_balanced_tree/(5,4,10) | 1.383 s | 1.602 s | 11.0 MB | 612.91 ms | 661.49 ms | 2.1 MB | 126% faster | 8 | 4.1 | same |
| cp_recursive_wide_tree/(6000,800) | 1.696 s | 1.842 s | 15.8 MB | 1.337 s | 1.482 s | 2.5 MB | 27% faster | 8 | 4.7 | same |
| cp_recursive_deep_tree/(120,4) | 137.76 ms | 141.66 ms | 9.4 MB | 111.60 ms | 113.67 ms | 2.2 MB | 23% faster | 10 | 5.2 | same |
| cp_preserve_metadata/(5,4,10) | 1.036 s | 1.112 s | 11.0 MB | 569.78 ms | 586.00 ms | 2.1 MB | 82% faster | 10 | 5.2 | same |
| cp_large_file/16 | 4.58 ms | 5.34 ms | 8.0 MB | 1.76 ms | 2.21 ms | 1.8 MB | 159% faster | 10 | 5.7 | same |
| csplit_line_number | 14.64 ms | 15.30 ms | 9.2 MB | 14.07 ms | 15.01 ms | 2.0 MB | 4% faster | 10 | 5.7 | same |
| csplit_regex_pattern | 12.20 ms | 12.88 ms | 9.2 MB | 13.80 ms | 14.39 ms | 2.0 MB | 13% slower | 10 | 5.7 | same |
| cut_bytes | 7.82 ms | 8.72 ms | 7.7 MB | 6.56 ms | 7.02 ms | 2.1 MB | 19% faster | 10 | 5.7 | same |
| cut_characters | 7.00 ms | 7.27 ms | 7.8 MB | 7.17 ms | 7.64 ms | 2.1 MB | 2% slower | 10 | 5.7 | same |
| cut_characters_long_lines | 13.63 ms | 14.16 ms | 7.8 MB | 29.64 ms | 30.94 ms | 2.1 MB | 118% slower | 10 | 5.7 | same |
| cut_fields_tab | 9.27 ms | 9.72 ms | 7.8 MB | 11.97 ms | 12.76 ms | 2.1 MB | 29% slower | 10 | 5.8 | same |
| cut_fields_custom_delim | 10.12 ms | 10.91 ms | 7.8 MB | 14.42 ms | 14.80 ms | 2.1 MB | 43% slower | 10 | 5.8 | same |
| cut_fields_newline_delim | 4.73 ms | 5.63 ms | 7.7 MB | 1.73 ms | 2.02 ms | 2.1 MB | 174% faster | 10 | 5.8 | same |
| file_iso_dates | 7.69 ms | 8.59 ms | 8.9 MB | 3.49 ms | 3.80 ms | 2.0 MB | 120% faster | 10 | 5.8 | same |
| file_tz_abbreviations | 7.12 ms | 8.03 ms | 8.8 MB | 3.54 ms | 3.86 ms | 2.0 MB | 101% faster | 10 | 5.8 | same |
| file_custom_format | 7.64 ms | 7.97 ms | 8.8 MB | 3.11 ms | 3.53 ms | 2.0 MB | 145% faster | 10 | 5.8 | same |
| single_date_now | 5.05 ms | 5.83 ms | 8.5 MB | 2.06 ms | 2.28 ms | 2.0 MB | 145% faster | 10 | 5.8 | same |
| complex_relative_date | 5.30 ms | 6.13 ms | 8.7 MB | 1.76 ms | 2.03 ms | 2.0 MB | 201% faster | 10 | 5.8 | same |
| file_localized_names | 7.97 ms | 8.38 ms | 8.9 MB | 3.23 ms | 4.10 ms | 2.0 MB | 147% faster | 10 | 5.8 | same |
| dd_copy_default | 146.32 ms | 148.33 ms | 7.7 MB | 143.39 ms | 146.55 ms | 1.8 MB | 2% faster | 10 | 5.8 | same |
| dd_copy_4k_blocks | 31.93 ms | 32.98 ms | 7.8 MB | 28.38 ms | 29.02 ms | 1.8 MB | 12% faster | 10 | 5.8 | same |
| dd_copy_64k_blocks | 17.93 ms | 18.80 ms | 7.9 MB | 13.28 ms | 15.71 ms | 1.9 MB | 35% faster | 10 | 5.8 | same |
| dd_copy_1m_blocks | 23.71 ms | 25.84 ms | 8.8 MB | 19.11 ms | 19.86 ms | 2.8 MB | 24% faster | 10 | 5.8 | same |
| dd_copy_separate_blocks | 24.53 ms | 25.73 ms | 7.9 MB | 20.35 ms | 21.74 ms | 1.8 MB | 21% faster | 10 | 5.8 | same |
| dd_copy_partial | 9.59 ms | 9.96 ms | 7.8 MB | 5.98 ms | 6.85 ms | 1.8 MB | 60% faster | 10 | 5.8 | same |
| dd_copy_with_skip | 54.14 ms | 55.67 ms | 7.8 MB | 50.91 ms | 52.71 ms | 1.8 MB | 6% faster | 10 | 5.8 | same |
| dd_copy_with_seek | 57.59 ms | 59.95 ms | 7.8 MB | 54.31 ms | 55.71 ms | 1.8 MB | 6% faster | 10 | 5.8 | same |
| dd_copy_8k_blocks | 24.50 ms | 25.93 ms | 7.8 MB | 21.66 ms | 22.26 ms | 1.8 MB | 13% faster | 10 | 6.0 | same |
| df_deep_directory | 4.11 ms | 5.03 ms | 7.8 MB | 1.57 ms | 1.94 ms | 1.9 MB | 162% faster | 10 | 6.0 | same |
| du_wide_tree/(5000,500) | 45.37 ms | 48.06 ms | 9.7 MB | 40.72 ms | 44.91 ms | 3.6 MB | 11% faster | 10 | 6.0 | same |
| du_all_wide_tree/(5000,500) | 43.96 ms | 45.37 ms | 12.0 MB | 56.12 ms | 58.80 ms | 3.6 MB | 28% slower | 10 | 6.0 | same |
| du_deep_tree/(100,3) | 9.41 ms | 10.02 ms | 8.6 MB | 6.10 ms | 6.88 ms | 2.0 MB | 54% faster | 10 | 6.0 | same |
| du_summarize_balanced_tree/(5,4,10) | 52.18 ms | 53.17 ms | 8.8 MB | 47.07 ms | 48.03 ms | 1.9 MB | 11% faster | 10 | 6.0 | same |
| echo_consecutive_calls | 464.06 ms | 479.19 ms | 7.0 MB | 155.76 ms | 160.87 ms | 1.8 MB | 198% faster | 10 | 5.7 | same |
| true_consecutive_calls | 458.73 ms | 477.34 ms | 7.0 MB | 132.15 ms | 135.43 ms | 1.6 MB | 247% faster | 10 | 5.6 | same |
| false_consecutive_calls | 430.26 ms | 513.87 ms | 7.0 MB | 121.47 ms | 142.63 ms | 1.6 MB | 254% faster | 10 | 5.3 | same |
| expand_many_lines/100000 | 15.47 ms | 16.47 ms | 7.5 MB | 65.38 ms | 66.94 ms | 2.0 MB | 323% slower | 10 | 5.2 | same |
| expand_custom_tabstops/50000 | 7.61 ms | 8.30 ms | 7.5 MB | 14.72 ms | 15.40 ms | 2.0 MB | 93% slower | 10 | 5.2 | same |
| unexpand_many_lines/100000 | 11.24 ms | 12.48 ms | 7.4 MB | 86.11 ms | 87.06 ms | 2.0 MB | 666% slower | 10 | 5.2 | same |
| unexpand_large_file/10 | 17.72 ms | 19.73 ms | 7.4 MB | 179.29 ms | 185.14 ms | 2.0 MB | 912% slower | 10 | 5.1 | same |
| expr_index_no_match | 6.07 ms | 7.24 ms | 8.7 MB | 3.891 s | 4.061 s | 2.3 MB | 64011% slower | 3 | 5.1 | same |
| expr_index_match_at_end | 6.50 ms | 6.68 ms | 8.6 MB | 3.480 s | 3.512 s | 2.3 MB | 53424% slower | 3 | 6.3 | same |
| factor_multiple_u64s/2 | 9.20 ms | 9.61 ms | 9.0 MB | 2.06 ms | 2.49 ms | 2.0 MB | 346% faster | 10 | 5.7 | same |
| factor_large_u64_prime | 4.01 ms | 4.77 ms | 7.5 MB | 1.67 ms | 2.07 ms | 2.1 MB | 140% faster | 10 | 5.7 | same |
| factor_64bit_semiprime | 3.91 ms | 4.60 ms | 7.5 MB | 2.20 ms | 2.58 ms | 2.1 MB | 78% faster | 10 | 5.7 | same |
| hard::factor_three_39_bit_primes | 11.37 ms | 11.85 ms | 7.5 MB | 21.82 ms | 22.41 ms | 2.1 MB | 92% slower | 10 | 5.7 | same |
| hard::factor_five_38_bit_primes | 109.62 ms | 114.96 ms | 7.9 MB | 42.00 ms | 44.08 ms | 2.1 MB | 161% faster | 10 | 5.7 | same |
| hard::factor_thirteen_39_bit_primes | 527.19 ms | 555.18 ms | 8.1 MB | 277.31 ms | 290.67 ms | 2.2 MB | 90% faster | 10 | 5.7 | same |
| hard::factor_a_prime_to_the_seventh | 4.81 ms | 5.64 ms | 7.7 MB | 65.08 ms | 66.04 ms | 2.1 MB | 1252% slower | 10 | 5.8 | same |
| hard::factor_small_factors_and_a_large_prime | 4.10 ms | 5.16 ms | 7.6 MB | 1.73 ms | 2.11 ms | 2.1 MB | 137% faster | 10 | 5.8 | same |
| hard::factor_a_1279_bit_prime | 8.45 ms | 9.19 ms | 7.6 MB | 2.53 ms | 3.13 ms | 2.1 MB | 233% faster | 10 | 5.8 | same |
| fold_many_lines/100000 | 17.65 ms | 18.14 ms | 7.5 MB | 68.14 ms | 70.11 ms | 2.0 MB | 286% slower | 10 | 5.8 | same |
| fold_custom_width/50000 | 9.79 ms | 10.28 ms | 7.5 MB | 25.95 ms | 27.61 ms | 2.0 MB | 165% slower | 10 | 5.6 | same |
| hostname_ip_lookup/100000 | 6.07 ms | 7.00 ms | 7.5 MB | absent | absent | absent | n/a | 10 | 5.6 | same |
| hostname_basic | 3.89 ms | 4.71 ms | 7.2 MB | absent | absent | absent | n/a | 10 | 5.6 | same |
| join_full_match | 7.65 ms | 8.17 ms | 8.2 MB | 8.43 ms | 8.78 ms | 1.8 MB | 10% slower | 10 | 5.6 | same |
| join_partial_overlap | 7.99 ms | 8.92 ms | 8.1 MB | 8.04 ms | 8.30 ms | 1.8 MB | 1% slower | 10 | 5.6 | same |
| join_custom_separator | 7.82 ms | 8.73 ms | 8.1 MB | 7.66 ms | 8.30 ms | 1.9 MB | 2% faster | 10 | 5.6 | same |
| join_french_locale | 7.60 ms | 8.52 ms | 8.1 MB | 8.52 ms | 8.94 ms | 1.8 MB | 12% slower | 10 | 5.6 | same |
| join_unicode_locale | 5.53 ms | 5.93 ms | 8.1 MB | 2.17 ms | 2.38 ms | 1.8 MB | 154% faster | 10 | 5.6 | same |
| ls_recursive_balanced_tree/(6,4,15) | 210.26 ms | 211.63 ms | 8.7 MB | 137.76 ms | 140.01 ms | 2.1 MB | 53% faster | 10 | 5.6 | same |
| ls_recursive_long_all_balanced_tree/(6,4,15) | 389.44 ms | 392.25 ms | 9.2 MB | 244.53 ms | 250.04 ms | 2.3 MB | 59% faster | 10 | 5.5 | same |
| ls_recursive_wide_tree/(10000,1000) | 56.26 ms | 59.13 ms | 17.4 MB | 38.58 ms | 40.10 ms | 6.5 MB | 46% faster | 10 | 5.4 | same |
| ls_recursive_long_all_wide_tree/(15000,1500) | 236.70 ms | 240.86 ms | 21.8 MB | 145.79 ms | 151.08 ms | 8.0 MB | 62% faster | 10 | 5.2 | same |
| ls_recursive_deep_tree/(200,2) | 19.70 ms | 22.70 ms | 9.1 MB | 9.64 ms | 11.29 ms | 2.3 MB | 104% faster | 10 | 5.2 | same |
| ls_recursive_long_all_deep_tree/(100,4) | 15.74 ms | 16.85 ms | 9.3 MB | 9.16 ms | 9.52 ms | 2.4 MB | 72% faster | 10 | 5.2 | same |
| ls_recursive_mixed_tree | 7.26 ms | 7.94 ms | 8.8 MB | 3.26 ms | 3.67 ms | 2.1 MB | 123% faster | 10 | 5.2 | same |
| ls_recursive_long_all_mixed_tree | 11.18 ms | 12.47 ms | 9.2 MB | 6.80 ms | 7.30 ms | 2.3 MB | 64% faster | 10 | 5.2 | same |
| mv_single_file | 4.905 s | 4.943 s | 7.7 MB | 1.863 s | 1.866 s | 1.9 MB | 163% faster | 3 | 5.2 | same |
| mv_multiple_to_dir | 165.97 ms | 174.65 ms | 10.0 MB | 77.44 ms | 79.62 ms | 2.1 MB | 114% faster | 10 | 5.0 | same |
| mv_directory | 4.77 ms | 5.52 ms | 7.7 MB | 2.23 ms | 2.52 ms | 1.8 MB | 114% faster | 10 | 5.1 | same |
| mv_force_overwrite | 4.120 s | 4.279 s | 7.7 MB | 1.773 s | 1.801 s | 1.9 MB | 132% faster | 3 | 5.5 | same |
| rm_single_file | 4.187 s | 4.334 s | 7.6 MB | 1.363 s | 1.377 s | 1.8 MB | 207% faster | 3 | 5.4 | same |
| rm_multiple_files | 41.11 ms | 42.50 ms | 9.2 MB | 27.29 ms | 28.76 ms | 2.5 MB | 51% faster | 10 | 5.2 | same |
| rm_recursive_tree | 410.51 ms | 432.42 ms | 7.8 MB | 402.23 ms | 414.22 ms | 1.9 MB | 2% faster | 10 | 5.2 | same |
| rm_force_files | 38.33 ms | 39.02 ms | 9.2 MB | 26.61 ms | 27.04 ms | 2.5 MB | 44% faster | 10 | 5.1 | same |
| nl_many_lines/100000 | 13.55 ms | 14.60 ms | 7.6 MB | 26.53 ms | 27.26 ms | 1.9 MB | 96% slower | 10 | 5.1 | same |
| nl_large_file/10 | 15.55 ms | 17.55 ms | 7.6 MB | 31.80 ms | 34.06 ms | 1.8 MB | 105% slower | 10 | 5.0 | same |
| numfmt_to_si/10000 | 8.66 ms | 8.94 ms | 13.4 MB | 4.03 ms | 4.58 ms | 2.1 MB | 115% faster | 10 | 5.0 | same |
| numfmt_to_si_precision/10000 | 8.83 ms | 9.40 ms | 13.5 MB | 4.42 ms | 4.94 ms | 2.0 MB | 99% faster | 10 | 5.0 | gnu differs: stdout |
| numfmt_to_iec/10000 | 8.43 ms | 8.83 ms | 13.4 MB | 4.14 ms | 4.47 ms | 2.0 MB | 103% faster | 10 | 5.0 | same |
| numfmt_from_si/10000 | 7.98 ms | 8.37 ms | 13.4 MB | 3.86 ms | 4.12 ms | 2.0 MB | 107% faster | 10 | 5.0 | same |
| numfmt_large_numbers_si/10000 | 8.98 ms | 9.64 ms | 13.4 MB | 4.41 ms | 4.70 ms | 2.1 MB | 103% faster | 10 | 5.0 | same |
| numfmt_padding/(10000,50) | 9.17 ms | 9.76 ms | 13.4 MB | 5.10 ms | 5.39 ms | 2.0 MB | 80% faster | 10 | 5.0 | same |
| numfmt_round_modes/(up,10000) | 8.61 ms | 9.06 ms | 13.4 MB | 4.17 ms | 4.43 ms | 2.0 MB | 107% faster | 10 | 5.0 | same |
| numfmt_round_modes/(down,10000) | 8.61 ms | 8.96 ms | 13.4 MB | 4.17 ms | 4.50 ms | 2.0 MB | 106% faster | 10 | 5.0 | same |
| numfmt_round_modes/(towards-zero,10000) | 8.40 ms | 8.95 ms | 13.4 MB | 4.22 ms | 4.53 ms | 2.0 MB | 99% faster | 10 | 5.0 | same |
| numfmt_stream_to_si | 16.71 ms | 17.21 ms | 8.0 MB | 23.34 ms | 24.32 ms | 2.0 MB | 40% slower | 10 | 5.0 | same |
| numfmt_stream_to_si_precision | 20.41 ms | 20.95 ms | 8.0 MB | 24.52 ms | 25.36 ms | 2.1 MB | 20% slower | 10 | 5.0 | same |
| od_default | 123.16 ms | 129.07 ms | 7.9 MB | 44.49 ms | 48.03 ms | 1.8 MB | 177% faster | 10 | 5.0 | same |
| od_hex_bytes | 133.79 ms | 140.58 ms | 7.9 MB | 74.08 ms | 76.47 ms | 1.8 MB | 81% faster | 10 | 4.8 | same |
| od_chars | 129.71 ms | 135.17 ms | 7.9 MB | 84.61 ms | 86.92 ms | 1.8 MB | 53% faster | 10 | 4.8 | gnu differs: stdout |
| ptx_short_lines/100000 | 661.13 ms | 677.37 ms | 224.0 MB | 364.09 ms | 372.33 ms | 61.3 MB | 82% faster | 10 | 4.7 | gnu differs: stdout |
| ptx_long_lines/100 | 71.18 ms | 73.77 ms | 34.4 MB | 40.93 ms | 45.15 ms | 10.9 MB | 74% faster | 10 | 4.7 | gnu differs: stdout |
| ptx_input_references_short_lines/100000 | 750.35 ms | 758.63 ms | 209.5 MB | 329.83 ms | 336.26 ms | 56.7 MB | 127% faster | 10 | 4.7 | gnu differs: stdout |
| ptx_input_references_long_lines/1000 | 92.73 ms | 95.05 ms | 35.3 MB | 41.61 ms | 44.59 ms | 10.9 MB | 123% faster | 10 | 4.6 | gnu differs: stdout |
| ptx_tex/10000 | 68.22 ms | 75.07 ms | 26.7 MB | 44.86 ms | 49.82 ms | 9.0 MB | 52% faster | 10 | 4.6 | gnu differs: stdout |
| seq_integers | 11.38 ms | 12.18 ms | 7.6 MB | 17.54 ms | 18.42 ms | 1.8 MB | 54% slower | 10 | 4.6 | same |
| seq_large_integers | 4.46 ms | 5.16 ms | 8.2 MB | 1.53 ms | 1.86 ms | 1.8 MB | n/a (exit differs) | 10 | 4.6 | gnu differs: exit, stdout |
| seq_custom_separator | 12.24 ms | 13.10 ms | 7.6 MB | 18.11 ms | 18.45 ms | 1.8 MB | 48% slower | 10 | 4.6 | same |
| seq_with_step | 8.44 ms | 8.98 ms | 7.6 MB | 10.03 ms | 10.38 ms | 1.8 MB | 19% slower | 10 | 4.6 | same |
| seq_formatted | 12.44 ms | 12.57 ms | 7.7 MB | 16.46 ms | 17.01 ms | 2.0 MB | 32% slower | 10 | 4.4 | same |
| shuf_lines/(100000,80) | 12.54 ms | 12.84 ms | 17.2 MB | 19.73 ms | 20.12 ms | 11.6 MB | 57% slower | 10 | 4.4 | same |
| shuf_lines/(100000,10) | 7.08 ms | 7.89 ms | 12.1 MB | 8.08 ms | 8.43 ms | 4.9 MB | 14% slower | 10 | 4.4 | same |
| shuf_input_range/1000000 | 17.37 ms | 18.40 ms | 15.1 MB | 35.36 ms | 38.00 ms | 9.5 MB | 104% slower | 10 | 4.4 | same |
| shuf_repeat_sampling/(50000,80) | 6.38 ms | 6.86 ms | 8.5 MB | 7.65 ms | 7.84 ms | 2.7 MB | 20% slower | 10 | 4.4 | same |
| shuf_repeat_sampling/(50000,10) | 5.22 ms | 5.74 ms | 7.9 MB | 4.08 ms | 4.21 ms | 2.0 MB | 28% faster | 10 | 4.4 | same |
| sort_ascii_only/500000 | 125.64 ms | 129.09 ms | 44.3 MB | 240.20 ms | 250.35 ms | 53.6 MB | 91% slower | 10 | 4.4 | same |
| sort_accented_data/500000 | 120.09 ms | 127.14 ms | 45.1 MB | 297.85 ms | 307.97 ms | 53.6 MB | 148% slower | 10 | 4.3 | same |
| sort_mixed_data/500000 | 117.96 ms | 122.54 ms | 44.0 MB | 259.17 ms | 269.22 ms | 53.2 MB | 120% slower | 10 | 4.6 | same |
| sort_case_sensitive/500000 | 75.80 ms | 77.90 ms | 39.3 MB | 208.42 ms | 218.42 ms | 50.8 MB | 175% slower | 10 | 4.6 | same |
| sort_case_insensitive/500000 | 25.27 ms | 25.99 ms | 24.6 MB | 243.45 ms | 254.29 ms | 50.9 MB | 864% slower | 10 | 4.6 | gnu differs: out |
| sort_dictionary_order/500000 | 42.09 ms | 43.41 ms | 26.8 MB | 7.20 ms | 7.54 ms | 22.4 MB | n/a (exit differs) | 10 | 4.5 | gnu differs: exit, out |
| sort_numeric/500000 | 39.67 ms | 42.39 ms | 49.8 MB | 286.28 ms | 290.29 ms | 53.1 MB | 622% slower | 10 | 4.5 | same |
| sort_general_numeric/200000 | 40.61 ms | 43.48 ms | 25.0 MB | 273.72 ms | 288.84 ms | 16.7 MB | 574% slower | 10 | 4.6 | same |
| sort_reverse_locale/500000 | 124.07 ms | 129.71 ms | 45.2 MB | 311.01 ms | 322.51 ms | 53.6 MB | 151% slower | 10 | 4.4 | same |
| sort_key_field/500000 | 118.03 ms | 139.17 ms | 35.1 MB | 322.15 ms | 354.33 ms | 53.8 MB | 173% slower | 10 | 4.5 | same |
| sort_unique_locale/500000 | 147.27 ms | 164.36 ms | 57.6 MB | 323.77 ms | 333.35 ms | 53.6 MB | 120% slower | 10 | 4.9 | same |
| sort_long_line/10000 | 5.08 ms | 5.76 ms | 9.3 MB | 1.82 ms | 2.20 ms | 2.0 MB | 180% faster | 10 | 5.0 | same |
| merge_pre_sorted_files | 29.44 ms | 30.08 ms | 10.1 MB | 32.39 ms | 33.35 ms | 4.1 MB | 10% slower | 10 | 5.0 | same |
| sort_ascii_c_locale | 71.02 ms | 74.27 ms | 79.8 MB | 103.60 ms | 110.58 ms | 269.9 MB | 46% slower | 10 | 5.0 | same |
| sort_mixed_c_locale | 7.42 ms | 7.89 ms | 10.6 MB | 7.66 ms | 7.77 ms | 4.6 MB | 3% slower | 10 | 6.2 | same |
| sort_german_c_locale | 7.83 ms | 8.07 ms | 10.5 MB | 7.35 ms | 7.59 ms | 4.5 MB | 7% faster | 10 | 6.2 | same |
| sort_shared_prefix_c_locale | 138.23 ms | 140.49 ms | 52.7 MB | 170.35 ms | 189.81 ms | 56.1 MB | 23% slower | 10 | 6.2 | same |
| sort_german_de_locale | 16.39 ms | 17.10 ms | 12.8 MB | 70.06 ms | 71.94 ms | 4.8 MB | 327% slower | 10 | 6.2 | same |
| sort_ascii_utf8_locale | 330.72 ms | 337.96 ms | 109.5 MB | 561.78 ms | 588.68 ms | 203.2 MB | 70% slower | 10 | 6.1 | same |
| sort_mixed_utf8_locale | 16.23 ms | 17.14 ms | 13.0 MB | 69.38 ms | 73.88 ms | 4.8 MB | 327% slower | 10 | 5.7 | same |
| sort_numeric_utf8_locale | 6.10 ms | 6.86 ms | 12.8 MB | 7.48 ms | 7.76 ms | 4.5 MB | 23% slower | 10 | 5.7 | same |
| sort_reverse_utf8_locale | 15.36 ms | 16.49 ms | 13.0 MB | 70.01 ms | 71.63 ms | 4.8 MB | 356% slower | 10 | 5.7 | same |
| sort_unique_utf8_locale | 16.10 ms | 17.49 ms | 14.2 MB | 75.35 ms | 79.80 ms | 4.8 MB | 368% slower | 10 | 5.7 | same |
| sort_very_long_lines_utf8_locale | 252.93 ms | 268.02 ms | 61.9 MB | 96.63 ms | 105.64 ms | 34.4 MB | 162% faster | 10 | 5.7 | same |
| sort_long_common_prefix_utf8_locale | 9.15 ms | 9.67 ms | 9.8 MB | 9.71 ms | 10.36 ms | 2.6 MB | 6% slower | 10 | 5.6 | same |
| merge_single_file_utf8_locale | 17.68 ms | 18.04 ms | 9.0 MB | 18.63 ms | 18.97 ms | 2.1 MB | 5% slower | 10 | 5.6 | same |
| merge_pre_sorted_files_utf8_locale | 28.52 ms | 29.01 ms | 10.1 MB | 31.81 ms | 32.67 ms | 4.1 MB | 12% slower | 10 | 5.6 | same |
| sort_spill_to_tmp_files_utf8_locale | 53.13 ms | 55.05 ms | 17.4 MB | 233.62 ms | 237.68 ms | 5.2 MB | 340% slower | 10 | 5.6 | same |
| check_sorted_utf8_locale | 353.83 ms | 361.29 ms | 10.7 MB | 34.55 ms | 35.13 ms | 2.2 MB | 924% faster | 10 | 5.3 | same |
| split_lines | 149.88 ms | 153.25 ms | 7.7 MB | 8.17 ms | 9.13 ms | 2.1 MB | 1734% faster | 10 | 5.1 | same |
| split_bytes | 15.16 ms | 16.45 ms | 7.7 MB | 8.52 ms | 9.15 ms | 2.1 MB | 78% faster | 10 | 5.1 | same |
| split_number_chunks | 5.61 ms | 6.59 ms | 8.5 MB | 3.15 ms | 3.83 ms | 2.0 MB | 78% faster | 10 | 5.1 | same |
| split_number_chunks_round_robin | 144.37 ms | 148.29 ms | 7.8 MB | 12.51 ms | 13.13 ms | 2.1 MB | 1054% faster | 10 | 5.1 | same |
| split_numeric_suffix | 160.09 ms | 161.45 ms | 7.7 MB | 12.94 ms | 13.60 ms | 2.1 MB | 1137% faster | 10 | 4.9 | same |
| tee_stdin_file/10000000 | 6.40 ms | 7.42 ms | 7.3 MB | 23.13 ms | 24.38 ms | 1.8 MB | 262% slower | 10 | 4.9 | same |
| timeout_quick_exit | 5.01 ms | 5.78 ms | 7.6 MB | 2.55 ms | 2.71 ms | 1.8 MB | 97% faster | 10 | 4.9 | same |
| timeout_enforced | 26.40 ms | 29.89 ms | 7.6 MB | 24.76 ms | 26.16 ms | 1.8 MB | 7% faster | 10 | 4.9 | same |
| timer_expiry_latency/0.001 | 5.84 ms | 6.40 ms | 7.5 MB | 3.02 ms | 3.23 ms | 1.8 MB | 93% faster | 10 | 4.9 | same |
| timer_expiry_latency/0.005 | 10.01 ms | 11.48 ms | 7.6 MB | 7.20 ms | 8.09 ms | 1.8 MB | 39% faster | 10 | 4.9 | same |
| timer_expiry_latency/0.02 | 27.36 ms | 29.46 ms | 7.5 MB | 23.35 ms | 25.39 ms | 1.8 MB | 17% faster | 10 | 4.9 | same |
| tr_ascii_range_lower_to_upper | 8.58 ms | 9.13 ms | 7.6 MB | 12.09 ms | 12.25 ms | 1.8 MB | 41% slower | 10 | 4.9 | same |
| tr_single_char_replace | 5.35 ms | 6.21 ms | 7.6 MB | 12.10 ms | 12.22 ms | 1.8 MB | 126% slower | 10 | 4.9 | same |
| tr_multi_char_translate | 8.51 ms | 8.99 ms | 7.6 MB | 12.10 ms | 12.26 ms | 1.8 MB | 42% slower | 10 | 4.9 | same |
| tr_delete_ascii_range | 11.59 ms | 12.09 ms | 7.6 MB | 16.97 ms | 17.23 ms | 1.8 MB | 46% slower | 10 | 4.9 | same |
| tr_delete_single_char | 9.79 ms | 10.35 ms | 7.6 MB | 12.24 ms | 12.47 ms | 1.8 MB | 25% slower | 10 | 4.9 | same |
| tsort_linear_chain/1000000 | 197.74 ms | 202.58 ms | 221.4 MB | 485.26 ms | 494.34 ms | 93.8 MB | 145% slower | 10 | 4.9 | same |
| tsort_tree_dag/(10,3) | 6.12 ms | 7.01 ms | 13.4 MB | 11.68 ms | 11.85 ms | 4.6 MB | 91% slower | 10 | 4.7 | same |
| tsort_complex_dag/50000 | 9.30 ms | 9.70 ms | 14.5 MB | 34.69 ms | 35.31 ms | 7.2 MB | 273% slower | 10 | 4.7 | same |
| tsort_wide_dag/100000 | 13.21 ms | 14.10 ms | 24.6 MB | 43.09 ms | 43.50 ms | 11.0 MB | 226% slower | 10 | 4.7 | same |
| uniq_heavy_duplicates/10000 | 3.86 ms | 4.29 ms | 7.8 MB | 2.43 ms | 2.64 ms | 1.8 MB | 59% faster | 10 | 4.7 | same |
| uniq_with_count/10000 | 3.83 ms | 4.28 ms | 7.7 MB | 2.35 ms | 2.56 ms | 1.8 MB | 63% faster | 10 | 4.7 | same |
| uniq_case_insensitive/10000 | 3.69 ms | 4.08 ms | 7.7 MB | 1.53 ms | 1.67 ms | 1.8 MB | 141% faster | 10 | 4.7 | same |
| uniq_check_chars/(10000,1) | 3.78 ms | 4.23 ms | 7.7 MB | 2.34 ms | 2.44 ms | 1.8 MB | 62% faster | 10 | 4.7 | same |
| uniq_check_chars/(10000,512) | 4.26 ms | 4.64 ms | 7.8 MB | 2.38 ms | 2.58 ms | 1.8 MB | 79% faster | 10 | 4.7 | same |
| wc_bytes_synthetic/1 | 3.42 ms | 3.66 ms | 7.5 MB | 1.23 ms | 1.31 ms | 1.8 MB | 179% faster | 10 | 4.7 | same |
| wc_bytes_synthetic/500 | 3.62 ms | 3.83 ms | 7.5 MB | 1.22 ms | 1.32 ms | 1.8 MB | 196% faster | 10 | 4.7 | same |
| wc_words_synthetic/2000 | 1.570 s | 1.579 s | 7.4 MB | 2.275 s | 2.300 s | 2.0 MB | 45% slower | 6 | 4.7 | same |
| wc_bytes_lines_synthetic/2000 | 132.28 ms | 133.72 ms | 7.5 MB | 269.87 ms | 271.06 ms | 2.0 MB | 104% slower | 10 | 4.6 | same |
| wc_lines_variable_length/(50,500) | 6.86 ms | 7.82 ms | 7.5 MB | 5.86 ms | 6.36 ms | 2.0 MB | 17% faster | 10 | 4.6 | same |
| wc_lines_large_line_count/500000 | 6.62 ms | 7.33 ms | 7.5 MB | 6.74 ms | 7.21 ms | 2.0 MB | 2% slower | 10 | 4.6 | same |
| wc_chars_large_line_count/100000 | 4.73 ms | 5.37 ms | 7.5 MB | 11.30 ms | 12.12 ms | 2.0 MB | 139% slower | 10 | 4.6 | same |
| wc_chars_utf8/100000 | 3.77 ms | 4.53 ms | 7.5 MB | 6.91 ms | 7.23 ms | 2.0 MB | 83% slower | 10 | 4.6 | same |
| wc_words_large_line_count/100000 | 10.54 ms | 11.09 ms | 7.5 MB | 11.45 ms | 13.25 ms | 2.0 MB | 9% slower | 10 | 4.6 | same |
| wc_default_large_line_count/100000 | 13.99 ms | 14.72 ms | 7.5 MB | 11.39 ms | 13.07 ms | 2.0 MB | 23% faster | 10 | 4.6 | same |
| wc_lines_extreme_line_lengths/(100000,200) | 5.31 ms | 6.00 ms | 7.5 MB | 3.42 ms | 3.74 ms | 2.0 MB | 55% faster | 10 | 4.6 | same |
