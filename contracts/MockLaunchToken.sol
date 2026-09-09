// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Local-demo launch token. Do not use this unrestricted test mint on a live deployment.
contract MockLaunchToken is ERC20 {
    constructor() ERC20("Vesta Demo Launch Token", "VESTA") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
