// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Sooth Protocol (SOOTH)
/// @notice A fixed supply of one billion tokens, with 18 decimals.
/// @dev The immediate deployer receives the entire supply. At launch this is the factory.
/// There are no external mint, burn, administrative, or upgrade functions.
contract SoothToken is ERC20 {
    /// @notice The complete supply, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Sooth Protocol", "SOOTH") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
