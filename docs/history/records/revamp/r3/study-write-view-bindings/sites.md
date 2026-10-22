| Site | main acc | main rej | left 12 (acc/rej) | left 123 (acc/rej) | left 124 (acc/rej) | left 1234 (acc/rej) | left 123p4 (acc/rej) |
|---|---|---|---|---|---|---|---|
| BA_as_copied_write | 23 | 94 | 12/47 | 7/9 | 2/8 | 2/4 | 2/4 |
| BA_as_read_read | 358 | 447 | 131/249 | 125/242 | 114/130 | 110/129 | 114/129 |
| BA_as_written_write | 251 | 247 | 199/222 | 179/217 | 199/220 | 179/217 | 198/218 |
| BA_loop_write_write | 138 | 194 | 127/157 | 127/143 | 127/157 | 127/143 | 127/152 |
| BA_match_owned_write | 1 | 2 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| BA_match_written_field_write | 489 | 710 | 439/633 | 388/502 | 438/605 | 387/502 | 436/535 |
| BA_match_wvfield_read | 89 | 840 | 3/13 | 3/13 | 3/13 | 3/13 | 3/13 |
| BA_match_wvfield_readown_write | 31 | 42 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| BA_match_wvfield_written_write | 120 | 172 | 7/15 | 6/15 | 7/15 | 6/15 | 7/15 |
| FA_payload_rtw | 45 | 0 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| FA_rtw_pointer | 145 | 0 | 13/0 | 11/0 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| FA_rtw_value | 99 | 0 | 8/0 | 8/0 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| HC1_hcw_name_leaf | 0 | 182 | 0/160 | 0/0 **DEAD** | 0/97 | 0/0 **DEAD** | 0/0 **DEAD** |
| HC2_hcw_part_leaf | 0 | 139 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| OW01_pass_held_wv_part | 2 | 0 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| OW02_pass_held_wv_name | 54 | 24 | 33/12 | 33/12 | 33/12 | 33/12 | 33/12 |
| OW_bare_wv_name_rejects | 0 | 82 | 0/33 | 0/25 | 0/33 | 0/25 | 0/25 |
| OW_bare_wv_part_rejects | 0 | 14 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| OW_lt_read_as | 116 | 35 | 15/11 | 15/11 | 13/7 | 13/7 | 13/7 |
| OW_lt_read_declared | 1095 | 782 | 895/646 | 881/634 | 894/646 | 881/634 | 894/646 |
| OW_lt_read_loop | 57 | 6 | 19/2 | 19/2 | 19/2 | 19/2 | 19/2 |
| OW_lt_read_payload | 556 | 91 | 498/77 | 498/77 | 498/77 | 498/77 | 498/77 |
| OW_lt_write_as | 171 | 184 | 143/135 | 134/133 | 141/131 | 132/131 | 141/131 |
| OW_lt_write_declared | 1345 | 1069 | 1036/809 | 961/796 | 1032/809 | 959/796 | 1030/804 |
| OW_lt_write_loop | 72 | 65 | 72/64 | 72/64 | 72/64 | 72/64 | 72/64 |
| OW_lt_write_payload | 498 | 567 | 368/444 | 344/418 | 368/444 | 344/418 | 368/444 |
| OW_pass_wv_branch_unlent | 1 | 6 | 1/0 | 0/0 **DEAD** | 1/0 | 0/0 **DEAD** | 1/0 |
| OW_pv_move | 0 | 9 | 0/7 | 0/5 | 0/7 | 0/5 | 0/7 |
| OW_pv_noroot | 148 | 49 | 146/49 | 146/49 | 146/49 | 146/49 | 146/49 |
| OW_pv_ref_write | 449 | 507 | 353/422 | 350/408 | 352/422 | 349/408 | 351/416 |
| OW_pv_root | 720 | 203 | 515/143 | 509/141 | 514/143 | 508/141 | 514/141 |
| OW_pv_root_holds_wv | 449 | 507 | 353/422 | 350/408 | 352/422 | 349/408 | 351/416 |
| OW_reads_through_wv | 68 | 13 | 45/6 | 44/5 | 45/6 | 44/5 | 45/5 |
| SM01a_mwv_direct_lend | 233 | 243 | 182/218 | 172/213 | 182/216 | 172/213 | 181/214 |
| SM01b_mwv_branch_made | 64 | 34 | 53/28 | 0/0 **DEAD** | 53/28 | 0/0 **DEAD** | 53/28 |
| SM01c_mwv_call_or_move | 62 | 73 | 22/29 | 19/29 | 22/29 | 19/29 | 22/29 |
| TC09_as_hcw_rejects | 0 | 23 | 0/8 | 0/0 **DEAD** | 0/2 | 0/0 **DEAD** | 0/0 **DEAD** |
| TC10_match_hcw_rejects | 0 | 298 | 0/152 | 0/0 **DEAD** | 0/95 | 0/0 **DEAD** | 0/0 **DEAD** |
| TC13_as_mwv_written | 251 | 247 | 199/222 | 179/217 | 199/220 | 179/217 | 198/218 |
| TC16_loop_holds_wv_rejects | 0 | 5 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| TC18_mreach_mwv_written | 98 | 101 | 55/51 | 12/23 | 55/51 | 12/23 | 55/51 |
| TC24_coerce_pass_write | 2402 | 4092 | 1640/2065 | 1422/1865 | 1616/1880 | 1405/1745 | 1599/1841 |
| TC27_clone_holds_wv | 0 | 5 | 0/1 | 0/1 | 0/0 **DEAD** | 0/0 **DEAD** | 0/0 **DEAD** |
| TC28_moves_because_wv | 0 | 20 | 0/3 | 0/3 | 0/3 | 0/3 | 0/3 |
| TC30_read_view_slot_wv | 2435 | 4175 | 1671/2135 | 1453/1935 | 1647/1950 | 1436/1815 | 1630/1911 |
| TC31_plain_slot_lends_wv | 2035 | 3416 | 1374/1503 | 1242/1420 | 1369/1492 | 1240/1420 | 1353/1455 |
| TC_as_wv_lendon_rejects | 0 | 8 | 0/5 | 0/5 | 0/5 | 0/5 | 0/5 |
| TC_lendtemp_wv_branch_leaf_rejects | 0 | 19 | 0/14 | 0/6 | 0/14 | 0/6 | 0/9 |
| TC_lendw_branch_leaf_rejects | 0 | 127 | 0/110 | 0/110 | 0/110 | 0/110 | 0/110 |
