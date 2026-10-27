# Archive integration fixtures

Small, unchanged binary reference archives decoded from the `.uu` files in
[libarchive v3.7.7](https://github.com/libarchive/libarchive/tree/v3.7.7/libarchive/test).
The upstream BSD notices are retained in `COPYING.txt`. They are test data only,
not application resources or executable dependencies. Test execution is offline.

| Fixture | SHA-256 of decoded archive |
| --- | --- |
| `test_read_format_7zip_lzma1.7z` | `cd4595cf136ed9857088103e0f16f41b0028ac8a93a6070450c45d55f0d04d74` |
| `test_read_format_7zip_lzma2.7z` | `12b78dbba994d4e2c604b973c233d31e6fbec23c94352dd2f0480ff619c18f5d` |
| `test_read_format_rar5_stored.rar` | `35d75e315d164d2e329afc28f7d844f013271b4fcffd4ddd78efcdd114a383a7` |
| `test_read_format_rar_subblock.rar` | `e871277670529329cc2c06f178ced453c560d03fd26c76614f42ef9c06b50af0` |

RAR subblock contains `test.txt` (`test text document` plus CRLF). RAR5 stored
contains `helloworld.txt`. The LZMA1 and LZMA2 7Z files contain the same 2,844-byte
`file1`, beginning `The libarchive distribution `. Expectations follow the
upstream C tests. These examples do not establish every RAR/7Z compression,
encryption, multi-volume, or platform variant. Never extract reference data into
a user directory; tests use unique temporary output directories and cleanup.
