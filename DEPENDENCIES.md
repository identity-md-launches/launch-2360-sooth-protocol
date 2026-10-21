# Vendored dependencies

All required source files are stored in this repository. No dependency
uses a Git submodule, package install, or network import.

| Dependency | Pinned release | Included files | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `v5.0.2` | `ERC20`, `IERC20`, `IERC20Metadata`, `Context`, `draft-IERC6093` | MIT, `lib/openzeppelin-contracts/LICENSE` |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | Solidity files under upstream `src/` | Apache-2.0 or MIT, both licenses in `lib/forge-std/` |

OpenZeppelin files were downloaded from the corresponding release paths
under `https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/`.
Forge Standard Library source was extracted from
`https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`.
Both are unmodified upstream sources. Only OpenZeppelin's ERC-20 dependency
closure is needed in production; Forge Standard Library is used by tests.

`DEPENDENCIES.sha256` records the hashes of the included source and license
files. Verify their local integrity with:

```sh
sha256sum --check DEPENDENCIES.sha256
```
